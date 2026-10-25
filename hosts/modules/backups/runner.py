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
import selectors
import shutil
import signal
import stat
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


DIAGNOSTIC_LIMIT = 1024 * 1024


class DiagnosticError(RuntimeError):
    """A private diagnostic could not be secured or persisted."""

    def __init__(self):
        super().__init__("Backup diagnostic I/O failed")


@contextmanager
def private_directory(path):
    """Walk without following symlinks; secure new directories and the leaf."""
    directory = None
    try:
        try:
            directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
            parts = Path(path).absolute().parts[1:]
            for index, part in enumerate(parts):
                if part in (".", ".."):
                    raise DiagnosticError()
                created = False
                try:
                    os.mkdir(part, 0o700, dir_fd=directory)
                    created = True
                except FileExistsError:
                    pass
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=directory)
                os.close(directory)
                directory = child
                if created or index == len(parts) - 1:
                    if os.fstat(directory).st_uid != os.geteuid():
                        raise DiagnosticError()
                    os.fchmod(directory, 0o700)
        except OSError:
            raise DiagnosticError() from None
        # Do not catch exceptions from the caller: TimeoutError is an OSError.
        yield directory
    finally:
        if directory is not None:
            os.close(directory)


@contextmanager
def diagnostic_file(path):
    """Keep only this stage's current bounded tail, never historical runs.

    Open nonblocking before checking the inode so a FIFO cannot hang. Tighten
    existing permissions before truncation or writing any potentially private
    output. Directory-relative opens prevent symlink substitution during use.
    """
    path = Path(path)
    with private_directory(path.parent) as directory:
        try:
            fd = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                         0o600, dir_fd=directory)
        except OSError:
            raise DiagnosticError() from None
        try:
            try:
                info = os.fstat(fd)
                if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                        or info.st_uid != os.geteuid()):
                    raise DiagnosticError()
                os.fchmod(fd, 0o600)
                os.ftruncate(fd, 0)
                output = os.fdopen(fd, "wb", closefd=False)
            except OSError:
                raise DiagnosticError() from None
            try:
                yield output
            finally:
                try:
                    output.flush()
                    os.fsync(fd)
                except OSError:
                    raise DiagnosticError() from None
                finally:
                    try:
                        output.close()
                    except OSError:
                        raise DiagnosticError() from None
        finally:
            os.close(fd)


def collect_tail(process, deadline, tail):
    """Drain a nonblocking combined pipe with constant bounded storage."""
    with selectors.DefaultSelector() as selector:
        os.set_blocking(process.stdout.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ)
        while selector.get_map():
            remaining = None if deadline is None else deadline - time.monotonic()
            if remaining is not None and remaining <= 0:
                raise subprocess.TimeoutExpired("backup stage", 0)
            for key, _ in selector.select(remaining):
                data = os.read(key.fd, 65536)
                if not data:
                    selector.unregister(key.fileobj)
                else:
                    tail.extend(data)
                    del tail[:-DIAGNOSTIC_LIMIT]
        process.wait(timeout=None if deadline is None else max(0.001, deadline - time.monotonic()))


def run_logged_command(command, deadline, env, diagnostic_path):
    tail = bytearray()
    # Opening the private destination before launching fails closed on bad paths.
    with diagnostic_file(diagnostic_path) as output:
        if deadline is not None and time.monotonic() >= deadline:
            raise TimeoutError("Backup deadline exceeded")
        try:
            with subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  start_new_session=True) as process:
                try:
                    collect_tail(process, deadline, tail)
                except BaseException as error:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    # Drain queued timeout output after killing the entire group.
                    # A detached descendant holding the pipe must not hang cleanup.
                    try:
                        collect_tail(process, time.monotonic() + 1, tail)
                    except subprocess.TimeoutExpired:
                        pass
                    process.wait()
                    if isinstance(error, subprocess.TimeoutExpired):
                        raise TimeoutError("Backup subprocess deadline exceeded") from None
                    raise
                if process.returncode != 0:
                    raise CommandError(process.returncode)
        finally:
            try:
                output.write(tail)
            except OSError:
                raise DiagnosticError() from None
    return ""


def run_command(command, deadline, env=None, *, diagnostic_path=None):
    """Return stdout for preflight, or privately retain a bounded stage tail.

    Logged stages return an empty string; output never appears in exceptions or
    the journal. The root service owns diagnostics (0700 parents, 0600 files).
    """
    if deadline is not None and time.monotonic() >= deadline:
        raise TimeoutError("Backup deadline exceeded")
    if diagnostic_path is not None:
        return run_logged_command(command, deadline, env, diagnostic_path)
    with subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, start_new_session=True) as process:
        try:
            stdout, _ = process.communicate(
                timeout=None if deadline is None else max(0.001, deadline - time.monotonic()))
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
        run_command(config["preparation_command"], deadline, env=env,
                    diagnostic_path=Path(config["state_directory"]) / "jobs" /
                    config["job_id"] / "logs" / "preparation.log")


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
    timeout = config["timeout_seconds"]
    deadline = None if timeout is None else time.monotonic() + timeout
    locks = state / "locks"
    # Unlimited uploads must not mean unlimited waits behind another run.
    job_lock_deadline = (time.monotonic() + config["preparation_lock_wait_seconds"]
                         if deadline is None else deadline)
    with locked(locks / (config["job_id"] + ".lock"), job_lock_deadline):
        logs = state / "jobs" / config["job_id"] / "logs"
        for directory in (state, state / "jobs", logs.parent, logs):
            with private_directory(directory):
                pass
        # Current attempt only: reset every static stage, including stages this
        # attempt might never reach. No rotated/unbounded history is retained.
        for stage in ("preparation", "create", "promotion"):
            with diagnostic_file(logs / (stage + ".log")):
                pass
        print("Managed backup stage: preflight", flush=True)
        preflight(config, deadline)
        preparation_deadline = time.monotonic() + config["preparation_lock_wait_seconds"]
        if deadline is not None:
            preparation_deadline = min(deadline, preparation_deadline)
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
                    "--archive-name-format", pending,
                    "--borg-exit-codes", strict_exit_codes, "create"], deadline,
                    diagnostic_path=state / "jobs" / config["job_id"] / "logs" / "create.log")
        print("Managed backup stage: promotion", flush=True)
        run_command(config["borg_command"] + ["rename", "::" + pending, complete], deadline,
                    diagnostic_path=state / "jobs" / config["job_id"] / "logs" / "promotion.log")
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
