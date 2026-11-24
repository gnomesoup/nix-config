"""Administrator-only Inigo Zulip provisioning entry point."""
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys

from policy import BOT_EMAIL, OWNER_EMAIL, REALM_ID, REALM_URL


def fetch_bot(*, runner=subprocess.run):
    """The only Docker boundary; secret response never reaches caller output."""
    here = Path(__file__).resolve().parent
    program = (here / "policy.py").read_text() + "\n" + (here / "container.py").read_text()
    shell = ('/home/zulip/deployments/current/manage.py shell --interface python '
             '--verbosity 0 -c "import sys; exec(sys.stdin.read())"')
    try:
        result = runner(
            ["@docker@", "compose", "--project-name", "zulip", "-f", "/etc/zulip/compose.yaml",
             "exec", "-T", "--user", "root", "zulip", "su", "zulip", "-c", shell],
            input=program, text=True, capture_output=True, check=False, timeout=180,
        )
    except (OSError, subprocess.SubprocessError):
        raise ValueError("Zulip command unavailable or timed out") from None
    if result.returncode != 0:
        raise ValueError("Zulip command failed; output suppressed")
    try:
        if len(result.stdout) > 65536:
            raise ValueError()
        data = json.loads(result.stdout)
        fields = {"status", "realm", "site", "bot_email", "user_id", "owner_email", "api_key"}
        if (not isinstance(data, dict) or set(data) != fields
                or data["status"] not in ("created", "existing")
                or data["realm"] != REALM_ID or data["site"] != REALM_URL
                or data["bot_email"] != BOT_EMAIL or data["owner_email"] != OWNER_EMAIL
                or type(data["user_id"]) is not int or data["user_id"] <= 0
                or not isinstance(data["api_key"], str)
                or not re.fullmatch(r"[A-Za-z0-9]{32}", data["api_key"])):
            raise ValueError()
    except (ValueError, TypeError):
        raise ValueError("invalid Zulip response; output suppressed") from None
    key = data.pop("api_key")
    return data, key


def read_existing_key(dfd, expected_uid):
    """Inspect metadata before reading only the designated credential."""
    try:
        fd = os.open("api-key", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "rb") as existing:
        info = os.fstat(existing.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != expected_uid
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o400):
            raise ValueError("unsafe credential file")
        key = existing.read(34)
        if not re.fullmatch(rb"[A-Za-z0-9]{32}\n?", key):
            raise ValueError("invalid existing credential")
        return key.rstrip(b"\n").decode("ascii")


def persist_key(directory, key, *, expected_uid=0):
    """Publish a complete credential without replacing any existing file."""
    if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z0-9]{32}", key):
        raise ValueError("invalid key")
    directory = Path(directory)
    directory.mkdir(mode=0o700, parents=False, exist_ok=True)
    dfd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(dfd)
        if info.st_uid != expected_uid or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError("unsafe credential directory")
        existing = read_existing_key(dfd, expected_uid)
        if existing is not None:
            if existing != key:
                raise ValueError("credential mismatch; refusing to overwrite")
            return
        temporary = ".api-key-" + secrets.token_hex(16)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=dfd)
        try:
            with os.fdopen(fd, "wb") as output:
                output.write((key + "\n").encode("ascii"))
                output.flush()
                os.fchmod(output.fileno(), 0o400)
                os.fsync(output.fileno())
            # link(2) atomically publishes the complete file and cannot clobber a target.
            os.link(temporary, "api-key", src_dir_fd=dfd, dst_dir_fd=dfd,
                    follow_symlinks=False)
        finally:
            os.unlink(temporary, dir_fd=dfd)
        os.fsync(dfd)
    finally:
        os.close(dfd)


def run_provision(directory=Path("/var/lib/inigo-zulip"), *, expected_uid=0, runner=subprocess.run):
    """Provision under a private-directory lock, then publish the credential."""
    directory = Path(directory)
    try:
        directory.mkdir(mode=0o700)
    except FileExistsError:
        pass
    else:
        # Clear inherited setgid on a directory we just created, not an existing path.
        directory.chmod(0o700)
    dfd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(dfd)
        if info.st_uid != expected_uid or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError("unsafe credential directory")
        lock = os.open(".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                       0o600, dir_fd=dfd)
        try:
            info = os.fstat(lock)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != expected_uid
                    or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600):
                raise ValueError("unsafe provisioning lock")
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            read_existing_key(dfd, expected_uid)
            metadata, key = fetch_bot(runner=runner)
            persist_key(directory, key, expected_uid=expected_uid)
            return metadata
        finally:
            os.close(lock)
    finally:
        os.close(dfd)


def main():
    import argparse
    parser = argparse.ArgumentParser(
        prog="inigo-zulip-provision",
        description="Provision the fixed mmjo Inigo bot as root. Existing keys are never rotated.",
    )
    parser.parse_args()
    if os.geteuid() != 0:
        print("inigo-zulip-provision: must run as root", file=sys.stderr)
        return 1
    try:
        metadata = run_provision()
    except Exception:
        print("inigo-zulip-provision: provisioning failed; check deployment, identity and credential permissions (output suppressed)", file=sys.stderr)
        return 1
    print(json.dumps(metadata, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
