#!/usr/bin/env python3
"""Synchronize the Nix-built SilverBullet Vim layout plug into both spaces."""

from __future__ import annotations

import http.client
import os
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable

TOKEN_FILE = Path("@tokenFile@")
PLUG_FILE = Path("@plugFile@")
BASE_URL = "@baseUrl@"
PLUG_PATH = "_plug/silverbullet-vim-layout.plug.js"
SPACE_PREFIXES = (("Personal", ""), ("KSP", "/ksp"))
MAX_TOKEN_BYTES = 4096
MAX_PLUG_BYTES = 5 * 1024 * 1024


class SyncError(RuntimeError):
    """A deliberately redacted synchronization failure."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


def read_token(path: Path) -> str:
    try:
        metadata = path.stat()
        if not stat.S_ISREG(metadata.st_mode):
            raise SyncError("token path is not a regular file")
        if metadata.st_uid != os.geteuid():
            raise SyncError("token file is not owned by the service user")
        if stat.S_IMODE(metadata.st_mode) & 0o077:
            raise SyncError("token file is accessible by group or other users")
        raw = path.read_bytes()
    except SyncError:
        raise
    except OSError as error:
        raise SyncError("could not read the runtime token file") from error

    if not raw or len(raw) > MAX_TOKEN_BYTES:
        raise SyncError("runtime token has an invalid size")
    try:
        token = raw.decode("utf-8").strip()
    except UnicodeDecodeError as error:
        raise SyncError("runtime token is not valid UTF-8") from error
    if not token or any(ord(character) < 0x20 or ord(character) == 0x7F for character in token):
        raise SyncError("runtime token contains invalid characters")
    return token


def read_plug(path: Path) -> bytes:
    try:
        content = path.read_bytes()
    except OSError as error:
        raise SyncError("could not read the compiled plug") from error
    if not content or len(content) > MAX_PLUG_BYTES:
        raise SyncError("compiled plug has an invalid size")
    return content


def request(
    opener: urllib.request.OpenerDirector,
    url: str,
    token: str | None,
    method: str = "GET",
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[bytes, int, http.client.HTTPMessage]:
    request_headers = dict(headers or {})
    if token is not None:
        request_headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=body, headers=request_headers, method=method)
    try:
        with opener.open(req, timeout=5) as response:
            return response.read(MAX_PLUG_BYTES + 1), response.status, response.headers
    except urllib.error.HTTPError:
        raise
    except (OSError, urllib.error.URLError) as error:
        raise SyncError("local SilverBullet request failed") from error


def wait_until_ready(
    opener: urllib.request.OpenerDirector,
    base_url: str,
    timeout_seconds: float,
    retry_seconds: float,
) -> None:
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            body, status, _ = request(opener, f"{base_url}/.ping", None)
            if status == 200 and body == b"OK":
                return
        except urllib.error.HTTPError as error:
            error.close()
        except SyncError:
            pass
        if time.monotonic() >= deadline:
            raise SyncError("SilverBullet did not become ready before the deadline")
        time.sleep(retry_seconds)


def plug_url(base_url: str, prefix: str) -> str:
    encoded = "/".join(urllib.parse.quote(segment, safe="") for segment in PLUG_PATH.split("/"))
    return f"{base_url}{prefix}/.fs/{encoded}"


def get_current(
    opener: urllib.request.OpenerDirector,
    url: str,
    token: str,
    label: str,
) -> tuple[bytes | None, str | None, str | None]:
    try:
        body, _, response_headers = request(
            opener,
            url,
            token,
            headers={"Accept": "application/octet-stream", "X-Sync-Mode": "true"},
        )
    except urllib.error.HTTPError as error:
        status = error.code
        error.close()
        if status == 404:
            return None, None, None
        raise SyncError(f"{label} read failed with HTTP {status}") from None
    if len(body) > MAX_PLUG_BYTES:
        raise SyncError(f"{label} returned an oversized plug")
    return body, response_headers.get("X-Created"), response_headers.get("X-Permission")


def put_plug(
    opener: urllib.request.OpenerDirector,
    url: str,
    token: str,
    label: str,
    content: bytes,
    created: str,
) -> None:
    now = str(int(time.time() * 1000))
    headers = {
        "Accept": "application/octet-stream",
        "Content-Type": "application/javascript",
        "X-Created": created,
        "X-Last-Modified": now,
        "X-Content-Length": str(len(content)),
        "X-Permission": "rw",
        "X-Sync-Mode": "true",
    }
    try:
        _, status, _ = request(opener, url, token, method="PUT", body=content, headers=headers)
    except urllib.error.HTTPError as error:
        status = error.code
        error.close()
        raise SyncError(f"{label} write failed with HTTP {status}") from None
    if status != 200:
        raise SyncError(f"{label} write returned an unexpected status")


def sync(
    token_file: Path = TOKEN_FILE,
    plug_file: Path = PLUG_FILE,
    base_url: str = BASE_URL,
    *,
    timeout_seconds: float = 90,
    retry_seconds: float = 1,
    log: Callable[[str], None] = print,
) -> None:
    token = read_token(token_file)
    content = read_plug(plug_file)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect)
    wait_until_ready(opener, base_url, timeout_seconds, retry_seconds)

    for label, prefix in SPACE_PREFIXES:
        url = plug_url(base_url, prefix)
        current, created, permission = get_current(opener, url, token, label)
        if current == content and permission == "rw":
            log(f"{label}: {PLUG_PATH} already synchronized")
            continue

        if created is None or not created.isdigit():
            created = str(int(time.time() * 1000))
        put_plug(opener, url, token, label, content, created)
        verified, _, verified_permission = get_current(opener, url, token, label)
        if verified != content or verified_permission != "rw":
            raise SyncError(f"{label} verification failed")
        log(f"{label}: synchronized {PLUG_PATH}")


def main() -> int:
    try:
        sync()
    except SyncError as error:
        print(f"SilverBullet plug sync failed: {error}", file=sys.stderr)
        return 1
    except Exception:
        print("SilverBullet plug sync failed: unexpected local error", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
