#!/usr/bin/env python3
"""Enable Git-only SilverBullet shell access and initialize space repositories."""

from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
import tempfile
from pathlib import Path

MAX_CONFIG_BYTES = 1024 * 1024
EXPECTED_SPACES = {
    "Personal": "/",
    "KSP": "/ksp",
}


class SetupError(RuntimeError):
    """A configuration or repository setup failure safe to print."""


def load_config(path: Path) -> dict[str, object]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise SetupError("could not inspect spaces.json") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise SetupError("spaces.json is not a regular file")
    if metadata.st_size <= 0 or metadata.st_size > MAX_CONFIG_BYTES:
        raise SetupError("spaces.json has an invalid size")
    try:
        parsed = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SetupError("could not parse spaces.json") from error
    if not isinstance(parsed, dict):
        raise SetupError("spaces.json must contain an object")
    return parsed


def resolve_space_folder(root: Path, space_id: str, config: dict[str, object]) -> Path:
    folder = config.get("folder", "")
    if not isinstance(folder, str):
        raise SetupError("space folder must be a string")
    if not folder:
        candidate = root / "spaces" / space_id
    elif folder == ".":
        candidate = root
    else:
        configured = Path(folder)
        candidate = configured if configured.is_absolute() else root / configured

    try:
        resolved_root = root.resolve(strict=True)
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(resolved_root)
    except (OSError, ValueError) as error:
        raise SetupError("space folder must be an existing child of the SilverBullet state directory") from error
    if resolved == resolved_root:
        raise SetupError("a Git repository may not use the SilverBullet state root")
    return resolved


def run_git(git: Path, folder: Path, arguments: list[str], *, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            [str(git), "-C", str(folder), *arguments],
            check=check,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise SetupError(f"Git {arguments[0]} failed") from error


def initialize_repository(git: Path, folder: Path) -> None:
    if not (folder / ".git").is_dir():
        run_git(git, folder, ["init", "--initial-branch=main"])

    head = run_git(git, folder, ["rev-parse", "--verify", "HEAD"], check=False)
    if head.returncode == 0:
        return

    run_git(git, folder, ["config", "user.name", "SilverBullet"])
    run_git(git, folder, ["config", "user.email", "silverbullet@localhost"])
    run_git(git, folder, ["add", "--all"])
    staged = run_git(git, folder, ["diff", "--cached", "--quiet"], check=False)
    if staged.returncode == 1:
        run_git(git, folder, ["commit", "-m", "Initial SilverBullet snapshot"])
    elif staged.returncode != 0:
        raise SetupError("Git diff failed")


def write_config(path: Path, config: dict[str, object]) -> None:
    content = f"{json.dumps(config, indent=2, ensure_ascii=False)}\n"
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix="spaces.json.",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            os.chmod(temporary.fileno(), 0o600)
            temporary.write(content)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except OSError as error:
        try:
            temporary_path.unlink(missing_ok=True)
        except (OSError, UnboundLocalError):
            pass
        raise SetupError("could not update spaces.json") from error


def configure(root: Path, git: Path) -> None:
    config_path = root / "spaces.json"
    original = load_config(config_path)
    updated = json.loads(json.dumps(original))
    found: dict[str, tuple[str, dict[str, object]]] = {}

    for space_id, raw_space in updated.items():
        if not isinstance(space_id, str) or not isinstance(raw_space, dict):
            raise SetupError("spaces.json contains an invalid space entry")
        name = raw_space.get("name")
        binding = raw_space.get("binding")
        prefix = binding.get("prefix") if isinstance(binding, dict) else None
        if name in EXPECTED_SPACES:
            if name in found:
                raise SetupError(f"spaces.json contains duplicate {name} spaces")
            if prefix != EXPECTED_SPACES[name]:
                raise SetupError(f"{name} has an unexpected binding")
            found[name] = (space_id, raw_space)
            raw_space["shell"] = {"enabled": True, "whitelist": ["git"]}
        else:
            raw_space["shell"] = {"enabled": False, "whitelist": []}

    missing = sorted(set(EXPECTED_SPACES) - set(found))
    if missing:
        raise SetupError(f"spaces.json is missing expected spaces: {', '.join(missing)}")

    if not git.is_file():
        raise SetupError("configured Git executable does not exist")
    for name in EXPECTED_SPACES:
        space_id, space = found[name]
        initialize_repository(git, resolve_space_folder(root, space_id, space))

    if updated != original:
        write_config(config_path, updated)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--git", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        configure(arguments.root, arguments.git)
    except SetupError as error:
        print(f"SilverBullet Git setup failed: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
