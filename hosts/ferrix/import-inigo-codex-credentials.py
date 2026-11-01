#!/usr/bin/env python3
"""Import Pi's current Codex OAuth tokens into Inigo's Hermes auth store."""

import json
import os
import re
import stat
import subprocess
from pathlib import Path

SOURCE = Path("/home/mpfammatter/.pi/agent/auth.json")
HERMES_WRAPPER = Path("/run/current-system/sw/bin/hermes")
TARGET_USER = "inigo"
TARGET_HOME = "/var/lib/inigo"
HERMES_HOME = "/var/lib/inigo/.hermes"
SERVICES = ("hermes-agent.service", "hermes-backend.service")


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def read_source() -> dict[str, str]:
    try:
        info = SOURCE.lstat()
    except OSError as exc:
        fail(f"cannot inspect Pi's auth file: {exc}")
    if not stat.S_ISREG(info.st_mode) or SOURCE.is_symlink():
        fail("Pi's auth file is not a regular, non-symlink file")
    if info.st_mode & 0o077:
        fail("Pi's auth file is accessible by group or other users")

    try:
        fd = os.open(SOURCE, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        fail(f"cannot read Pi's Codex credentials: {exc}")
    if not isinstance(data, dict):
        fail("Pi's auth file has an unexpected format")

    provider = data.get("openai-codex")
    if not isinstance(provider, dict) or provider.get("type") != "oauth":
        fail("Pi has no OpenAI Codex OAuth credential")
    access, refresh = provider.get("access"), provider.get("refresh")
    if (
        not isinstance(access, str)
        or not access
        or not isinstance(refresh, str)
        or not refresh
    ):
        fail("Pi's OpenAI Codex OAuth credential is incomplete")
    return {"access_token": access, "refresh_token": refresh}


def hermes_python() -> str:
    try:
        wrapper = HERMES_WRAPPER.resolve(strict=True).read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"cannot inspect the Hermes launcher: {exc}")
    match = re.search(r"^export HERMES_PYTHON='([^']+)'$", wrapper, re.MULTILINE)
    if not match or not Path(match.group(1)).is_file():
        fail("cannot locate Hermes's Python interpreter")
    return match.group(1)


def update_hermes(tokens: dict[str, str]) -> None:
    update = r'''import json, sys
from hermes_cli.auth import _load_auth_store, _load_provider_state
from hermes_cli.auth_codex import _save_codex_tokens

tokens = json.load(sys.stdin)
_save_codex_tokens(tokens, set_active=True)
state = _load_provider_state(_load_auth_store(), "openai-codex") or {}
stored = state.get("tokens") or {}
if (
    stored.get("access_token") != tokens["access_token"]
    or stored.get("refresh_token") != tokens["refresh_token"]
):
    raise SystemExit("Hermes credential verification failed")
print("Hermes OpenAI Codex credentials imported and verified.")
'''
    command = [
        "/run/current-system/sw/bin/runuser",
        "--user",
        TARGET_USER,
        "--",
        "/run/current-system/sw/bin/env",
        f"HOME={TARGET_HOME}",
        f"HERMES_HOME={HERMES_HOME}",
        "HERMES_MANAGED=true",
        hermes_python(),
        "-c",
        update,
    ]
    result = subprocess.run(command, input=json.dumps(tokens), text=True, check=False)
    if result.returncode:
        fail("Hermes rejected the update; its previous credentials are intact")


def main() -> None:
    if os.geteuid() != 0:
        fail("run this helper with sudo")

    tokens = read_source()
    update_hermes(tokens)
    subprocess.run(
        ["/run/current-system/sw/bin/systemctl", "restart", *SERVICES],
        check=True,
    )
    print("Hermes gateway and backend restarted.")


if __name__ == "__main__":
    main()
