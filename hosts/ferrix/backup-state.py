"""Create restorable SQLite copies without losing committed WAL transactions."""

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import time
from contextlib import closing
from pathlib import Path


def snapshot_databases(roots, destination, reserve_bytes=2 * 1024**3, excluded_directories=()):
    destination = Path(destination)
    temporary = destination.with_name(destination.name + ".partial")
    if temporary.exists():
        shutil.rmtree(temporary)
    temporary.mkdir(parents=True, mode=0o700)
    manifest = []
    excluded = {Path(path) for path in excluded_directories}

    def walk_error(error):
        raise error

    try:
        for root in roots:
            root = Path(root)
            if not root.is_dir():
                raise FileNotFoundError(f"Required database root is missing: {root}")
            for directory, directories, files in os.walk(root, onerror=walk_error):
                directories[:] = [name for name in directories if Path(directory) / name not in excluded]
                for name in files:
                    database = Path(directory) / name
                    if database.suffix not in {".db", ".sqlite", ".sqlite3"}:
                        continue
                    if database.is_symlink():
                        raise ValueError("Refusing a symlinked SQLite database")
                    target = temporary / database.relative_to(database.anchor)
                    metadata = database.stat()
                    wal = database.with_name(database.name + "-wal")
                    required = (metadata.st_size + (wal.stat().st_size if wal.exists() else 0)) * 2
                    required += reserve_bytes
                    if shutil.disk_usage(temporary).free < required:
                        raise RuntimeError("Insufficient space for a consistent SQLite snapshot")
                    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    deadline = time.monotonic() + 120

                    def progress(status, remaining, total):
                        if time.monotonic() > deadline:
                            raise TimeoutError("SQLite snapshot exceeded two minutes")

                    with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as source:
                        with closing(sqlite3.connect(target)) as snapshot:
                            source.backup(snapshot, pages=256, progress=progress)
                            if snapshot.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
                                raise RuntimeError("SQLite snapshot failed its integrity check")
                    target.chmod(0o600)
                    manifest.append({
                        "path": str(database),
                        "uid": metadata.st_uid,
                        "gid": metadata.st_gid,
                        "mode": metadata.st_mode & 0o777,
                    })
        (temporary / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        if destination.exists():
            shutil.rmtree(destination)
        temporary.rename(destination)
    except BaseException:
        shutil.rmtree(temporary)
        raise


# Verified against the published 11.6-1 entrypoint. A changed image must be
# reviewed rather than quietly accepting a different backup implementation.
ZULIP_ENTRYPOINT_SHA256 = "6bf6659bb0fe54e32f3f109e36e42341e2fe9be16f4527906359479ce9aa5bfe"


def prepare_zulip(compose, data_root, destination, reserve_bytes=2 * 1024**3):
    data_root = Path(data_root)
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)

    def output(command):
        return subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE, timeout=120).stdout.strip()

    actual = output([compose[0], "volume", "inspect", "--format", "{{.Mountpoint}}", "zulip_zulip"])
    if Path(actual) != data_root or not data_root.is_dir():
        raise RuntimeError("Zulip's application volume does not match the configured backup source")
    entrypoint = output(compose + ["exec", "-T", "zulip", "sha256sum", "/sbin/entrypoint.sh"])
    if entrypoint.split()[0] != ZULIP_ENTRYPOINT_SHA256:
        raise RuntimeError("Zulip's entrypoint changed; review its backup behavior before continuing")
    size = int(output(compose + [
        "exec", "-T", "database", "sh", "-ec",
        'export PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")"; '
        'exec psql --no-password -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" '
        "-Atc 'SELECT pg_database_size(current_database())'",
    ]))
    required = size * 2 + reserve_bytes
    if min(shutil.disk_usage(data_root).free, shutil.disk_usage(destination).free) < required:
        raise RuntimeError("Insufficient space for a validated Zulip database export")
    backups = data_root / "backups"
    before = set(backups.glob("backup-*.sql"))
    subprocess.run(compose + ["exec", "-T", "zulip", "/sbin/entrypoint.sh", "app:backup"], check=True, timeout=1800)
    created = set(backups.glob("backup-*.sql")) - before
    if len(created) != 1:
        raise RuntimeError("Zulip did not produce exactly one new database dump")
    dump = created.pop()
    if dump.is_symlink() or not dump.is_file() or dump.stat().st_size == 0:
        raise RuntimeError("Zulip produced an invalid database dump")
    subprocess.run(compose + [
        "exec", "-T", "zulip", "pg_restore", "--list", "/data/backups/" + dump.name,
    ], check=True, stdout=subprocess.DEVNULL, timeout=120)
    temporary = destination / "database.dump.partial"
    try:
        shutil.copyfile(dump, temporary)
        temporary.chmod(0o600)
        temporary.replace(destination / "database.dump")
    finally:
        temporary.unlink(missing_ok=True)
    # Only remove the dump created by this successful invocation. Never touch
    # administrator-created exports or reuse a previous dump after failure.
    dump.unlink()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--exclude", type=Path, action="append", default=[])
    parser.add_argument("--zulip-compose", type=Path)
    parser.add_argument("--zulip-data-root", type=Path, default=Path("/var/lib/docker/volumes/zulip_zulip/_data"))
    parser.add_argument("--zulip-destination", type=Path, default=Path("/var/lib/ferrix-backup/zulip"))
    parser.add_argument("roots", type=Path, nargs="+")
    arguments = parser.parse_args()
    os.umask(0o077)
    snapshot_databases(arguments.roots, arguments.destination, excluded_directories=arguments.exclude)
    if arguments.zulip_compose is not None:
        prepare_zulip(
            ["docker", "compose", "--project-name", "zulip", "--file", str(arguments.zulip_compose)],
            arguments.zulip_data_root, arguments.zulip_destination,
        )
