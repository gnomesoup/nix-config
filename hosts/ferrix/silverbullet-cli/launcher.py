"""Launch upstream sb using a private, short-lived native connection configuration.

This adapter handles credentials only. All HTTP, file operations, revisions, and
text edits are implemented by the unmodified upstream sb binary.
"""

import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile


CREDENTIAL_DIRECTORIES = (
    Path("/run/credentials/hermes-backend.service"),
    Path("/run/credentials/hermes-agent.service"),
)


def run(argv, *, binary, spaces):
    if len(argv) < 2 or argv[0] not in spaces:
        print("Usage: inigo-sb <personal|ksp> fs <command> [options]", file=sys.stderr)
        return 2
    space, *arguments = argv
    if arguments[0] != "fs":
        print("inigo-sb supports upstream filesystem commands only.", file=sys.stderr)
        return 2
    if any(
        argument in {"--url", "--token", "--space", "-s"}
        or argument.startswith(("--url=", "--token=", "--space=", "-s="))
        for argument in arguments
    ):
        print("Connection overrides are not allowed; select a configured space.", file=sys.stderr)
        return 2
    if "--help" in arguments or "-h" in arguments:
        return subprocess.run([binary, *arguments], check=False).returncode

    try:
        configured = os.environ.get("CREDENTIALS_DIRECTORY")
        credentials = Path(configured) if configured else next(
            directory for directory in CREDENTIAL_DIRECTORIES
            if os.access(directory / "silverbullet-api-token", os.R_OK)
        )
        source = credentials / "silverbullet-api-token"
        descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as handle:
            info = os.fstat(handle.fileno())
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid not in {0, os.getuid()}
                or info.st_mode & 0o037
                # systemd may grant the unit user read access through an ACL.
                or (info.st_mode & stat.S_IRGRP and credentials not in CREDENTIAL_DIRECTORIES)
            ):
                raise ValueError("unsafe credential")
            token = handle.read(16385).strip()
        if not token or len(token) > 16384 or any(c in token for c in (b"\n", b"\r", b"\0")):
            raise ValueError("invalid credential")
        token.decode("ascii")
    except (KeyError, OSError, ValueError, StopIteration):
        print("A private systemd SilverBullet credential is required.", file=sys.stderr)
        return 4

    with tempfile.TemporaryDirectory(prefix="inigo-sb-") as temporary:
        environment = os.environ.copy()
        environment["XDG_CONFIG_HOME"] = temporary
        try:
            setup = subprocess.run(
                [binary, "space", "add", "--no-browser"],
                input=(space + "\n" + spaces[space] + "\ntoken\n").encode() + token + b"\n",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                timeout=90,
                check=False,
            )
            if setup.returncode:
                raise ValueError("setup failed")
            config_path = Path(temporary) / "silverbullet" / "config.json"
            connection = json.loads(config_path.read_bytes())["spaces"]
            if (
                len(connection) != 1
                or connection[0]["name"] != space
                or connection[0]["url"] != spaces[space].rstrip("/")
                or connection[0]["auth"]["method"] != "token"
                or not connection[0]["auth"].get("encryptedToken")
                or config_path.stat().st_mode & 0o077
            ):
                raise ValueError("unexpected connection")
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
            # Do not forward login output: a future upstream error might echo input.
            print("SilverBullet connection setup failed; no file command was run.", file=sys.stderr)
            return 4
        return subprocess.run(
            [binary, "--space", space, *arguments], env=environment, check=False
        ).returncode


if __name__ == "__main__":
    try:
        binary, config, *arguments = sys.argv[1:]
        connections = json.loads(Path(config).read_text())
        raise SystemExit(run(arguments, binary=binary, spaces=connections))
    except (OSError, ValueError):
        print("SilverBullet CLI launcher configuration is unavailable.", file=sys.stderr)
        raise SystemExit(8)
