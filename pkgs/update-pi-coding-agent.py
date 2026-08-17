#!/usr/bin/env python3
"""Update the pi-ai model-data tarball used by the Pi Nix package."""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import tarfile
from urllib.parse import quote
from urllib.request import Request, urlopen

NPM_PACKAGE = "@earendil-works/pi-ai"
MAP_END = "  };\n  aiModelDataTarball = aiModelDataTarballs.${version} or null;"


def fetch_release(version: str) -> tuple[str, str]:
    metadata_url = f"https://registry.npmjs.org/{quote(NPM_PACKAGE, safe='')}/{quote(version, safe='')}"
    request = Request(metadata_url, headers={"Accept": "application/json", "User-Agent": "nix-pi-updater"})
    with urlopen(request, timeout=30) as response:
        metadata = json.load(response)

    dist = metadata.get("dist", {})
    tarball_url = dist.get("tarball")
    published_integrity = dist.get("integrity")
    if not isinstance(tarball_url, str) or not isinstance(published_integrity, str):
        raise RuntimeError(f"npm metadata for {NPM_PACKAGE}@{version} has no tarball integrity")

    tarball_request = Request(tarball_url, headers={"User-Agent": "nix-pi-updater"})
    with urlopen(tarball_request, timeout=60) as response:
        tarball = response.read()

    integrity = "sha512-" + base64.b64encode(hashlib.sha512(tarball).digest()).decode()
    if integrity != published_integrity:
        raise RuntimeError(
            f"integrity mismatch for {NPM_PACKAGE}@{version}: "
            f"metadata has {published_integrity}, downloaded {integrity}"
        )

    with tarfile.open(fileobj=io.BytesIO(tarball), mode="r:gz") as archive:
        model_files = [
            member.name
            for member in archive.getmembers()
            if member.isfile()
            and member.name.startswith("package/dist/providers/data/")
            and member.name.endswith(".json")
        ]
    if not model_files:
        raise RuntimeError(f"{NPM_PACKAGE}@{version} contains no generated provider model data")

    return tarball_url, integrity


def update_package_file(package_file: Path, version: str, tarball_url: str, integrity: str) -> bool:
    text = package_file.read_text()
    entry = (
        f'    "{version}" = fetchurl {{\n'
        f'      url = "{tarball_url}";\n'
        f'      hash = "{integrity}";\n'
        "    };"
    )
    pattern = re.compile(
        rf'^    "{re.escape(version)}" = fetchurl \{{\n'
        r'(?:      .*\n)*?'
        r"    \};",
        re.MULTILINE,
    )

    if pattern.search(text):
        updated = pattern.sub(entry, text, count=1)
    else:
        if MAP_END not in text:
            raise RuntimeError(f"could not find aiModelDataTarballs map in {package_file}")
        updated = text.replace(MAP_END, f"{entry}\n{MAP_END}", 1)

    if updated == text:
        return False

    package_file.write_text(updated)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Update the npm model-data tarball for the current Pi package version."
    )
    parser.add_argument("--version", required=True, help="Pi/pi-ai release version")
    parser.add_argument(
        "--package-file",
        type=Path,
        default=Path("pkgs/pi-coding-agent.nix"),
        help="Pi Nix package file, relative to the repository root",
    )
    args = parser.parse_args()

    if not args.package_file.is_file():
        parser.error(f"package file does not exist: {args.package_file}")

    try:
        tarball_url, integrity = fetch_release(args.version)
        changed = update_package_file(args.package_file, args.version, tarball_url, integrity)
    except Exception as error:
        print(f"update-pi-coding-agent: {error}", file=sys.stderr)
        return 1

    if changed:
        print(f"Updated {args.package_file} for {NPM_PACKAGE}@{args.version}")
    else:
        print(f"{args.package_file} is already current for {NPM_PACKAGE}@{args.version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
