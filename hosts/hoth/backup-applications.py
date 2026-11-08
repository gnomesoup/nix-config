"""Verify Hoth application mounts and Frigate's effective database path."""

import json
import os
import subprocess


IMMICH_VOLUME = "4e5d855e02e90178383e8ccb1495a04c9276c8660f890bb777824af98fcfd315"
IMMICH_DATA = f"/var/lib/docker/volumes/{IMMICH_VOLUME}/_data"


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


if __name__ == "__main__":
    main()
