"""Consistent SQLite exports, with restore metadata and committed WAL data.

Callers serialize access to the destination. Exported files are private; the
manifest records original permissions/ownership for an explicit restore.
"""
from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import sqlite3
import time


def snapshot_databases(roots, destination, reserve_bytes=2 * 1024**3,
                       excluded_directories=(), *, database_timeout_seconds=120,
                       deadline=None):
    destination = Path(destination)
    temporary = destination.with_name(destination.name + ".partial")
    if temporary.is_symlink() or destination.is_symlink():
        raise ValueError("Refusing a symlinked snapshot destination")
    if temporary.exists():
        shutil.rmtree(temporary)
    temporary.mkdir(parents=True, mode=0o700)
    temporary.chmod(0o700)
    manifest = []
    excluded = {Path(path).absolute() for path in excluded_directories}
    seen = set()

    def check_deadline(limit):
        if time.monotonic() >= limit:
            raise TimeoutError("SQLite snapshot deadline exceeded")

    def walk_error(error):
        raise error

    try:
        for root in roots:
            root = Path(root).absolute()
            if not root.is_dir():
                raise FileNotFoundError("Required SQLite root is missing")
            if root.is_symlink():
                raise ValueError("Refusing a symlinked SQLite root")
            if root in excluded:
                continue
            for directory, directories, files in os.walk(root, onerror=walk_error, followlinks=False):
                if deadline is not None:
                    check_deadline(deadline)
                directories[:] = [name for name in directories
                                  if name not in {"cache", "node_modules"}
                                  and Path(directory, name).absolute() not in excluded
                                  and not Path(directory, name).is_symlink()]
                for name in files:
                    database = Path(directory) / name
                    if database.suffix not in {".db", ".sqlite", ".sqlite3"} or database in seen:
                        continue
                    if database.is_symlink():
                        raise ValueError("Refusing a symlinked SQLite database")
                    seen.add(database)
                    metadata = database.stat()
                    wal = database.with_name(database.name + "-wal")
                    required = (metadata.st_size + (wal.stat().st_size if wal.exists() else 0)) * 2
                    if shutil.disk_usage(temporary).free < required + reserve_bytes:
                        raise RuntimeError("Insufficient space for a consistent SQLite snapshot")
                    target = temporary / database.relative_to(database.anchor)
                    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    limit = time.monotonic() + database_timeout_seconds
                    if deadline is not None:
                        limit = min(limit, deadline)
                    check_deadline(limit)

                    def progress(status, remaining, total):
                        check_deadline(limit)

                    # mode=ro deliberately retains WAL visibility; immutable=1 does not.
                    with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True,
                                                 timeout=max(0.001, min(5, limit - time.monotonic())))) as source:
                        with closing(sqlite3.connect(target)) as snapshot:
                            source.backup(snapshot, pages=256, progress=progress, sleep=0.05)
                            snapshot.set_progress_handler(lambda: int(time.monotonic() >= limit), 1000)
                            if snapshot.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
                                raise RuntimeError("SQLite snapshot failed its integrity check")
                    check_deadline(limit)
                    target.chmod(0o600)
                    manifest.append({"path": str(database), "uid": metadata.st_uid,
                                     "gid": metadata.st_gid, "mode": metadata.st_mode & 0o7777})
        manifest_path = temporary / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        manifest_path.chmod(0o600)
        if destination.exists():
            shutil.rmtree(destination)
        temporary.rename(destination)
        return manifest
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
