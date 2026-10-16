"""Fail-closed preparation and two-phase archive promotion for managed backups.

The service supplies BORG_* settings and repository-aware command wrappers.
This runtime never initializes repositories or manages credentials.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid

from sqlite_snapshot import snapshot_databases


class CommandError(RuntimeError):
    """A subprocess status safe to report without argv, output, or credentials."""

    def __init__(self, returncode):
        self.returncode = returncode
        super().__init__("Backup subprocess exited with status " + str(returncode))


def run_command(command, deadline, env=None):
    """Run one stage without logging arguments, environment, or child output."""
    if time.monotonic() >= deadline:
        raise TimeoutError("Backup deadline exceeded")
    with subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, start_new_session=True) as process:
        try:
            stdout, _ = process.communicate(timeout=max(0.001, deadline - time.monotonic()))
        except BaseException as error:
            # A child (docker, ssh, shell, or Borg) may outlive its direct parent.
            # Killing the whole session's process group prevents orphan uploads.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            if isinstance(error, subprocess.TimeoutExpired):
                raise TimeoutError("Backup subprocess deadline exceeded") from None
            raise
        if process.returncode != 0:
            raise CommandError(process.returncode)
        return stdout


@contextmanager
def locked(path, deadline):
    # Never unlink lock files: another waiter may hold the same inode.
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open("a") as lock:
        while True:
            if time.monotonic() >= deadline:
                raise TimeoutError("Backup lock deadline exceeded")
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                time.sleep(min(0.05, max(0, deadline - time.monotonic())))
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def preflight(config, deadline):
    for directory in config["required_directories"]:
        if not Path(directory).is_dir():
            raise FileNotFoundError("Required backup directory is missing")
    for database in config["required_sqlite_files"]:
        if Path(database).is_symlink() or not Path(database).is_file():
            raise FileNotFoundError("Required SQLite database is missing or symlinked")
    for mount in config["required_mounts"]:
        actual = run_command(["findmnt", "--noheadings", "--output", "UUID",
                              "--mountpoint", mount["path"]], deadline).strip()
        if not actual or actual != mount["uuid"]:
            raise RuntimeError("Required mount identity mismatch")
    if config["ssh_hostname"] is not None:
        known_hosts = config["ssh_known_hosts_file"]
        if not known_hosts or not Path(known_hosts).is_file():
            raise FileNotFoundError("Required SSH known-hosts file is missing")
        if not run_command(["ssh-keygen", "-F", config["ssh_hostname"],
                            "-f", known_hosts], deadline).strip():
            raise RuntimeError("Required SSH host key is missing")
    if config["expected_repository_id"] is not None:
        info = json.loads(run_command(config["borg_command"] + ["info", "--json"], deadline))
        if info.get("repository", {}).get("id") != config["expected_repository_id"]:
            raise RuntimeError("Repository identity mismatch")


def prepare(config, staging, deadline):
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True, mode=0o700)
    (staging / "exports").mkdir(mode=0o700)
    manifest = snapshot_databases(config["sqlite_roots"], staging / "sqlite",
                                 excluded_directories=config["sqlite_excluded_directories"],
                                 deadline=deadline)
    exported = {entry["path"] for entry in manifest}
    if not all(path in exported for path in config["required_sqlite_files"]):
        raise RuntimeError("Required SQLite database was not exported")
    if config["preparation_command"]:
        env = os.environ.copy()
        env["BACKUP_STAGING_DIRECTORY"] = str(staging)
        run_command(config["preparation_command"], deadline, env=env)


def run_job(config):
    for key in ("job_id", "source_id", "repository_id"):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", config[key]):
            raise ValueError("Invalid backup identifier")
    state = Path(config["state_directory"])
    staging = Path(config["staging_directory"])
    expected_staging = state / "jobs" / config["job_id"] / "staging"
    if (not state.is_absolute() or not staging.is_absolute() or staging != expected_staging
            or staging.resolve() != expected_staging.absolute()):
        raise ValueError("Staging must be the private non-symlinked per-job directory")
    for source in config["required_directories"] + config["sqlite_roots"]:
        path = Path(source).resolve()
        if path == staging.resolve() or path.is_relative_to(staging.resolve()):
            raise ValueError("Staging must not contain backup sources")
    os.umask(0o077)
    deadline = time.monotonic() + config["timeout_seconds"]
    locks = state / "locks"
    with locked(locks / (config["job_id"] + ".lock"), deadline):
        print("Managed backup stage: preflight", flush=True)
        preflight(config, deadline)
        preparation_deadline = min(deadline, time.monotonic() + config["preparation_lock_wait_seconds"])
        with locked(locks / "preparation.lock", preparation_deadline):
            print("Managed backup stage: preparation", flush=True)
            prepare(config, staging, deadline)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + "-" + uuid.uuid4().hex
        pending = "incomplete-" + config["source_id"] + "-" + stamp
        complete = config["source_id"] + "-complete-" + stamp
        # Borgmatic 2.1 treats several nonzero Borg warnings as overall success.
        # Override every process exit status so only a true zero can promote.
        strict_exit_codes = json.dumps([{"code": code, "treat_as": "error"}
                                        for code in range(1, 256)], separators=(",", ":"))
        print("Managed backup stage: create", flush=True)
        run_command(config["borgmatic_command"] + ["--config", config["borgmatic_config"],
                    "--override", "archive_name_format=" + pending,
                    "--override", "borg_exit_codes=" + strict_exit_codes, "create"], deadline)
        print("Managed backup stage: promotion", flush=True)
        run_command(config["borg_command"] + ["rename", "::" + pending, complete], deadline)
        print("Managed backup stage: record-success", flush=True)
        status = state / "status" / (config["job_id"] + ".json")
        status.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = status.with_name(status.name + "." + uuid.uuid4().hex + ".partial")
        try:
            with temporary.open("x") as output:
                json.dump(dict(source=config["source_id"], job=config["job_id"],
                    repository=config["repository_id"], archive=complete,
                    completed_at=time.time()), output)
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
            temporary.replace(status)
            directory_fd = os.open(status.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        run_job(json.loads(arguments.config.read_text()))
    except Exception as error:
        # In particular, never render CalledProcessError/TimeoutExpired: those
        # contain argv/output and preparation scripts may handle secrets.
        status = f", exit status {error.returncode}" if isinstance(error, CommandError) else ""
        print("Managed backup failed (" + type(error).__name__ + status + ")", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
