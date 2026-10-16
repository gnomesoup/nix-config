"""Validate Hoth application coverage and prepare its interim Immich export."""

import json
import os
import shutil
import subprocess
from pathlib import Path


IMMICH_VOLUME = "4e5d855e02e90178383e8ccb1495a04c9276c8660f890bb777824af98fcfd315"
IMMICH_DATA = f"/var/lib/docker/volumes/{IMMICH_VOLUME}/_data"

# Resolve passwords inside the database container, never in host argv or logs.
AUTH = '''
if [ -n "${POSTGRES_PASSWORD_FILE:-}" ]; then
  PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")"
else
  PGPASSWORD="${POSTGRES_PASSWORD:-}"
fi
export PGPASSWORD
'''


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


def export_postgres(container, destination, reserve_bytes=2 * 1024**3):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    size_command = AUTH + '''
exec psql --no-password --username "${POSTGRES_USER:-postgres}" \
  --dbname "${POSTGRES_DB:-${POSTGRES_USER:-postgres}}" \
  -Atc 'SELECT coalesce(sum(pg_database_size(oid)), 0) FROM pg_database'
'''
    result = subprocess.run(
        ["docker", "exec", container, "sh", "-ec", size_command],
        check=True, text=True, stdout=subprocess.PIPE, timeout=120,
    )
    size = int(result.stdout.strip())
    if size <= 0 or shutil.disk_usage(destination).free < size * 2 + reserve_bytes:
        raise RuntimeError("Insufficient staging space for a complete Immich export")
    temporary = destination / "immich.sql.partial"
    try:
        with temporary.open("xb") as output:
            temporary.chmod(0o600)
            subprocess.run(
                ["docker", "exec", container, "sh", "-ec", AUTH +
                 'exec pg_dumpall --no-password --username "${POSTGRES_USER:-postgres}"'],
                check=True, stdout=output, timeout=1800,
            )
        with temporary.open("rb") as output:
            output.seek(max(0, temporary.stat().st_size - 512))
            if b"-- PostgreSQL database cluster dump complete" not in output.read():
                raise RuntimeError("Immich database export is not complete")
        temporary.replace(destination / "immich.sql")
    finally:
        temporary.unlink(missing_ok=True)


def main():
    os.umask(0o077)
    stage = Path(os.environ["BACKUP_STAGING_DIRECTORY"])
    verify_mounts("immich_server", {
        "/data": IMMICH_DATA,
        "/usr/src/app/upload": "/mnt/backup1/immich",
    })
    verify_mounts("immich_postgres", {
        "/var/lib/postgresql/data": "/home/mpfammatter/docker/immich-db",
    })
    verify_mounts("frigate", {
        "/config": "/home/mpfammatter/docker/frigate",
        "/media/frigate": "/home/mpfammatter/docker/frigate/media",
    })
    verify_frigate_database()
    export_postgres("immich_postgres", stage / "exports")


if __name__ == "__main__":
    main()
