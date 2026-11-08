"""Validate Hoth application coverage and Immich's native compressed dumps."""

import contextlib
import gzip
import json
import os
import re
import stat
import subprocess
import time
import zlib
from datetime import datetime
from pathlib import Path


IMMICH_VOLUME = "4e5d855e02e90178383e8ccb1495a04c9276c8660f890bb777824af98fcfd315"
IMMICH_DATA = f"/var/lib/docker/volumes/{IMMICH_VOLUME}/_data"
DUMP_PATTERN = re.compile(
    r"immich-db-backup-(\d{8}T\d{6})-v\d+\.\d+\.\d+"
    r"(?:-[0-9A-Za-z.-]+)?-pg\d+(?:\.\d+)+\.sql\.gz"
)


def verify_mounts(container, expected):
    result = subprocess.run(
        ["docker", "inspect", "--format", "{{json .Mounts}}", container],
        check=True, text=True, stdout=subprocess.PIPE, timeout=60,
    )
    mounts = {entry["Destination"]: entry for entry in json.loads(result.stdout)}
    for destination, source in expected.items():
        actual = mounts.get(destination, {})
        if actual.get("Type") not in {"bind", "volume"} or actual.get("Source") != source:
            raise RuntimeError(f"{container} mount changed; update its backup declaration")


def verify_frigate_database():
    # v0.17.1 frigate/api/app.py config() serializes the running config, not YAML.
    # nginx.conf caches /api/: X-Cache-Bypass forces a fresh effective config.
    # Extract only the DB path inside the container; never log the full response.
    probe = '''
import json
import sys
import urllib.request

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError("Unexpected redirect")

try:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    request = urllib.request.Request(
        "http://127.0.0.1:5000/api/config", headers={"X-Cache-Bypass": "1"}
    )
    with opener.open(request, timeout=15) as response:
        path = json.load(response)["database"]["path"]
    if not isinstance(path, str) or not path:
        sys.exit(1)
    print(json.dumps(path))
except Exception:
    sys.exit(1)
'''
    try:
        result = subprocess.run(
            ["docker", "exec", "frigate", "python3", "-c", probe],
            check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
        )
        path = json.loads(result.stdout)
    except (subprocess.SubprocessError, OSError, ValueError):
        raise RuntimeError("Cannot verify Frigate effective database path; refusing backup") from None
    if path != "/config/frigate.db":
        raise RuntimeError("Frigate database path changed; update its backup declaration")


@contextlib.contextmanager
def open_directory(path):
    """Pin every directory component without following symlinks, including parents."""
    path = Path(path).absolute()
    if ".." in path.parts:
        raise RuntimeError("Parent traversal is not allowed in backup paths")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open(path.anchor, flags)
    try:
        for component in path.parts[1:]:
            child = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        yield descriptor
    finally:
        os.close(descriptor)


def file_identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def validate_gzip(output, timeout_seconds=1800):
    """Read CRC-checked gzip to EOF with a per-application time/working-set bound."""
    deadline = time.monotonic() + timeout_seconds
    output.seek(0)
    tail = b""
    total = 0
    try:
        with gzip.GzipFile(fileobj=output, mode="rb") as compressed:
            while True:
                if time.monotonic() > deadline:
                    raise RuntimeError("Native Immich dump validation timed out")
                chunk = compressed.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                tail = (tail + chunk)[-4096:]
    except (OSError, EOFError, zlib.error):
        raise RuntimeError("Native Immich gzip is not complete") from None
    lines = tail.splitlines()
    if total > len(tail):
        lines = lines[1:]  # The first retained line may have lost its prefix.
    footers = {b"-- PostgreSQL database dump complete",
               b"-- PostgreSQL database cluster dump complete"}
    # PG17 can put an unrestrict command after its completion marker.
    if not footers.intersection(lines):
        raise RuntimeError("Native Immich SQL dump is not complete")


def validate_immich_dump(source_directory, max_age_seconds=36 * 3600):
    """Validate the newest final native dump read-only; Borg captures its original path."""
    with open_directory(source_directory) as source_fd:
        candidates = []
        for name in os.listdir(source_fd):
            match = DUMP_PATTERN.fullmatch(name)
            if not match:
                continue
            info = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
            if stat.S_ISREG(info.st_mode):
                datetime.strptime(match[1], "%Y%m%dT%H%M%S")
                candidates.append((info.st_mtime_ns, name, info))
        if not candidates:
            raise RuntimeError("No complete native Immich dump found")
        _, name, selected = max(candidates, key=lambda entry: entry[:2])
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
        with os.fdopen(os.open(name, flags, dir_fd=source_fd), "rb") as incoming:
            snapshot = os.fstat(incoming.fileno())
            if not stat.S_ISREG(snapshot.st_mode) or file_identity(snapshot) != file_identity(selected):
                raise RuntimeError("Native Immich source changed before validation")
            # Immich filenames have no timezone: filesystem mtime alone proves age.
            age = time.time() - snapshot.st_mtime
            if not -300 <= age <= max_age_seconds:
                raise RuntimeError("Native Immich dump is stale or has a future mtime")
            if snapshot.st_size <= 0:
                raise RuntimeError("Native Immich dump is empty")
            validate_gzip(incoming)
            after = os.fstat(incoming.fileno())
            current = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
            if (file_identity(snapshot) != file_identity(after) or
                    file_identity(snapshot) != file_identity(current)):
                raise RuntimeError("Native Immich source changed during validation")
            with open_directory(source_directory) as current_source:
                a, b = os.fstat(source_fd), os.fstat(current_source)
                if (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
                    raise RuntimeError("Immich backup directory changed during validation")
            if time.time() - snapshot.st_mtime > max_age_seconds:
                raise RuntimeError("Native Immich dump became stale during validation")
    return Path(source_directory) / name


def main():
    os.umask(0o077)
    verify_mounts("immich_server", {
        "/data": IMMICH_DATA,
        "/usr/src/app/upload": "/mnt/backup1/immich",
    })
    verify_mounts("immich_postgres", {
        "/var/lib/postgresql/data": "/home/mpfammatter/docker/immich-db-pg17",
    })
    verify_mounts("frigate", {
        "/config": "/home/mpfammatter/docker/frigate",
        "/media/frigate": "/home/mpfammatter/docker/frigate/media",
    })
    verify_frigate_database()
    validate_immich_dump("/mnt/backup1/immich/backups")


if __name__ == "__main__":
    main()
