from __future__ import annotations

import importlib.util
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("silverbullet-calendar-proxy.py")
SPEC = importlib.util.spec_from_file_location("silverbullet_calendar_proxy", SCRIPT)
assert SPEC and SPEC.loader
proxy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proxy)


class CalendarProxyTest(unittest.TestCase):
    def test_normalizes_webcal_and_rejects_unsafe_urls(self) -> None:
        self.assertEqual(proxy.normalize_url(b"webcal://example.com/private.ics\n"), "https://example.com/private.ics")
        for value in [
            b"http://example.com/calendar.ics",
            b"https://user:password@example.com/calendar.ics",
            b"not-a-url",
            b"",
        ]:
            with self.assertRaises(proxy.CalendarProxyError):
                proxy.normalize_url(value)

    def test_loads_only_fixed_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "personal-icloud-url").write_text("https://icloud.example/private.ics\n")
            (root / "ksp-outlook-url").write_text("https://outlook.example/private.ics\n")
            self.assertEqual(
                proxy.load_feeds(root),
                {
                    "/personal.ics": "https://icloud.example/private.ics",
                    "/ksp.ics": "https://outlook.example/private.ics",
                },
            )

    def test_serves_only_named_routes_and_redacts_upstream_errors(self) -> None:
        feeds = {
            "/personal.ics": "https://secret.example/personal.ics",
            "/ksp.ics": "https://secret.example/ksp.ics",
        }
        server = proxy.CalendarServer(("127.0.0.1", 0), feeds)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            calendar = b"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n"
            with patch.object(proxy, "fetch_calendar", return_value=calendar):
                with urllib.request.urlopen(f"{base}/personal.ics") as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.read(), calendar)
                    self.assertEqual(response.headers["Cache-Control"], "no-store")

            with self.assertRaises(urllib.error.HTTPError) as missing:
                urllib.request.urlopen(f"{base}/other.ics")
            self.assertEqual(missing.exception.code, 404)
            missing.exception.close()

            secret = feeds["/personal.ics"]
            with patch.object(proxy, "fetch_calendar", side_effect=proxy.CalendarProxyError(secret)):
                try:
                    urllib.request.urlopen(f"{base}/personal.ics")
                except urllib.error.HTTPError as error:
                    body = error.read().decode()
                    error.close()
                self.assertNotIn(secret, body)
                self.assertEqual(body, "Calendar fetch failed\n")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
