"""Run Ferrix's existing validated Zulip exporter in destination-private staging."""

import os
import runpy
import sys
from pathlib import Path


if __name__ == "__main__":
    os.umask(0o077)
    helper = runpy.run_path(sys.argv[1])
    helper["prepare_zulip"](
        ["docker", "compose", "--project-name", "zulip", "--file", "/etc/zulip/compose.yaml"],
        "/var/lib/docker/volumes/zulip_zulip/_data",
        Path(os.environ["BACKUP_STAGING_DIRECTORY"]) / "exports" / "zulip",
    )
