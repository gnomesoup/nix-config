#!/usr/bin/env python3
"""Expose fixed local calendar feeds without revealing their subscription URLs."""

from __future__ import annotations

import os
import ssl
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LISTEN_ADDRESS = "127.0.0.1"
LISTEN_PORT = 3001
MAX_URL_BYTES = 4096
MAX_CALENDAR_BYTES = 10 * 1024 * 1024
FEED_CREDENTIALS = {
    "/personal.ics": "personal-icloud-url",
    "/ksp.ics": "ksp-outlook-url",
}


class CalendarProxyError(RuntimeError):
    """A deliberately redacted proxy failure."""


class HttpsOnlyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        if urllib.parse.urlsplit(newurl).scheme != "https":
            raise CalendarProxyError("calendar endpoint attempted an insecure redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def normalize_url(raw: bytes) -> str:
    if not raw or len(raw) > MAX_URL_BYTES:
        raise CalendarProxyError("calendar URL credential has an invalid size")
    try:
        url = raw.decode("utf-8").strip()
    except UnicodeDecodeError as error:
        raise CalendarProxyError("calendar URL credential is not valid UTF-8") from error
    if url.startswith("webcal://"):
        url = "https://" + url.removeprefix("webcal://")
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise CalendarProxyError("calendar URL credential must be an HTTPS URL without userinfo")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in url):
        raise CalendarProxyError("calendar URL credential contains invalid characters")
    return url


def load_feeds(credentials_directory: Path) -> dict[str, str]:
    feeds: dict[str, str] = {}
    for path, credential in FEED_CREDENTIALS.items():
        try:
            raw = (credentials_directory / credential).read_bytes()
        except OSError as error:
            raise CalendarProxyError("could not read a calendar URL credential") from error
        feeds[path] = normalize_url(raw)
    return feeds


def fetch_calendar(url: str) -> bytes:
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        HttpsOnlyRedirect,
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
    )
    request = urllib.request.Request(url, headers={"Accept": "text/calendar", "User-Agent": "SilverBullet Calendar Proxy"})
    try:
        with opener.open(request, timeout=20) as response:
            if response.status != 200:
                raise CalendarProxyError("calendar endpoint returned an unexpected status")
            content = response.read(MAX_CALENDAR_BYTES + 1)
    except CalendarProxyError:
        raise
    except (OSError, urllib.error.URLError, urllib.error.HTTPError) as error:
        raise CalendarProxyError("calendar endpoint request failed") from error
    if not content or len(content) > MAX_CALENDAR_BYTES:
        raise CalendarProxyError("calendar endpoint returned an invalid response size")
    if b"BEGIN:VCALENDAR" not in content[:4096].upper():
        raise CalendarProxyError("calendar endpoint did not return an iCalendar document")
    return content


class CalendarHandler(BaseHTTPRequestHandler):
    server: "CalendarServer"

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def respond(self, status: int, content_type: str, body: bytes, *, include_body: bool = True) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def handle_feed(self, *, include_body: bool) -> None:
        parsed = urllib.parse.urlsplit(self.path)
        url = self.server.feeds.get(parsed.path) if not parsed.query and not parsed.fragment else None
        if url is None:
            self.respond(404, "text/plain; charset=utf-8", b"Not found\n", include_body=include_body)
            return
        try:
            content = fetch_calendar(url)
        except CalendarProxyError:
            self.respond(502, "text/plain; charset=utf-8", b"Calendar fetch failed\n", include_body=include_body)
            return
        self.respond(200, "text/calendar; charset=utf-8", content, include_body=include_body)

    def do_GET(self) -> None:
        self.handle_feed(include_body=True)

    def do_HEAD(self) -> None:
        self.handle_feed(include_body=False)


class CalendarServer(ThreadingHTTPServer):
    def __init__(self, address: tuple[str, int], feeds: dict[str, str]):
        super().__init__(address, CalendarHandler)
        self.feeds = feeds


def main() -> int:
    credentials = os.environ.get("CREDENTIALS_DIRECTORY")
    if not credentials:
        raise CalendarProxyError("systemd credentials directory is unavailable")
    feeds = load_feeds(Path(credentials))
    server = CalendarServer((LISTEN_ADDRESS, LISTEN_PORT), feeds)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
