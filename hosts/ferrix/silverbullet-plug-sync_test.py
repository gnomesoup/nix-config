from __future__ import annotations

import contextlib
import importlib.util
import io
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT = Path(__file__).with_name("silverbullet-plug-sync.py")
SPEC = importlib.util.spec_from_file_location("silverbullet_plug_sync", SCRIPT)
assert SPEC and SPEC.loader
sync_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync_module)

EXPECTED_PATHS = {
    "/.fs/_plug/silverbullet-vim-layout.plug.js": "Personal",
    "/ksp/.fs/_plug/silverbullet-vim-layout.plug.js": "KSP",
}


class State:
    def __init__(self, token: str):
        self.token = token
        self.files: dict[str, tuple[bytes, str, str]] = {}
        self.requests: list[tuple[str, str, dict[str, str], bytes]] = []
        self.ping_failures = 0
        self.fail_path: str | None = None
        self.corrupt_path: str | None = None
        self.redirect_path: str | None = None


class Handler(BaseHTTPRequestHandler):
    server: "MockServer"

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def record(self, body: bytes = b"") -> None:
        self.server.state.requests.append((self.command, self.path, dict(self.headers), body))

    def do_GET(self) -> None:
        self.record()
        state = self.server.state
        if self.path == "/.ping":
            if state.ping_failures:
                state.ping_failures -= 1
                self.send_response(503)
                self.end_headers()
                return
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK")
            return

        if self.path == state.redirect_path:
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/leak")
            self.end_headers()
            return
        if self.path not in EXPECTED_PATHS:
            self.send_response(418)
            self.end_headers()
            return
        if self.headers.get("Authorization") != f"Bearer {state.token}":
            self.send_response(401)
            self.end_headers()
            return
        existing = state.files.get(self.path)
        if existing is None:
            self.send_response(404)
            self.end_headers()
            return
        content, created, permission = existing
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("X-Created", created)
        self.send_header("X-Permission", permission)
        self.end_headers()
        self.wfile.write(content)

    def do_PUT(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        self.record(body)
        state = self.server.state
        if self.path not in EXPECTED_PATHS:
            self.send_response(418)
            self.end_headers()
            return
        if self.headers.get("Authorization") != f"Bearer {state.token}":
            self.send_response(401)
            self.end_headers()
            return
        if self.path == state.fail_path:
            self.send_response(500, state.token)
            self.end_headers()
            self.wfile.write(state.token.encode())
            return
        stored = b"corrupt" if self.path == state.corrupt_path else body
        state.files[self.path] = (
            stored,
            self.headers.get("X-Created", ""),
            self.headers.get("X-Permission", ""),
        )
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")


class MockServer(ThreadingHTTPServer):
    def __init__(self, state: State):
        super().__init__(("127.0.0.1", 0), Handler)
        self.state = state


class SyncTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.token = "test-secret-token"
        self.token_file = root / "token"
        self.token_file.write_text(f"{self.token}\n")
        self.token_file.chmod(0o600)
        self.plug_file = root / "silverbullet-vim-layout.plug.js"
        self.content = b"const exactCompiledPlugBytes = true;\n"
        self.plug_file.write_bytes(self.content)
        self.state = State(self.token)
        self.server = MockServer(self.state)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def run_sync(self) -> list[str]:
        messages: list[str] = []
        sync_module.sync(
            self.token_file,
            self.plug_file,
            self.base_url,
            "_plug/silverbullet-vim-layout.plug.js",
            timeout_seconds=1,
            retry_seconds=0.01,
            log=messages.append,
        )
        return messages

    def test_writes_both_exact_routes_with_auth_and_rw_metadata(self) -> None:
        self.state.ping_failures = 2
        messages = self.run_sync()
        self.assertEqual(set(self.state.files), set(EXPECTED_PATHS))
        self.assertTrue(all(value[0] == self.content for value in self.state.files.values()))
        self.assertTrue(all(value[2] == "rw" for value in self.state.files.values()))
        self.assertEqual(len(messages), 2)

        api_requests = [request for request in self.state.requests if request[1] != "/.ping"]
        self.assertTrue(api_requests)
        for method, path, headers, body in api_requests:
            self.assertIn(path, EXPECTED_PATHS)
            self.assertEqual(headers.get("Authorization"), f"Bearer {self.token}")
            self.assertEqual(headers.get("X-Sync-Mode"), "true")
            if method == "PUT":
                self.assertEqual(body, self.content)
                self.assertEqual(headers.get("X-Permission"), "rw")
                self.assertTrue(headers.get("X-Created", "").isdigit())
                self.assertTrue(headers.get("X-Last-Modified", "").isdigit())
                self.assertEqual(headers.get("X-Content-Length"), str(len(self.content)))
                self.assertEqual(headers.get("Content-Type"), "application/javascript")
        ping_requests = [request for request in self.state.requests if request[1] == "/.ping"]
        self.assertTrue(all("Authorization" not in headers for _, _, headers, _ in ping_requests))
        self.assertFalse(any("CONFIG" in path for _, path, _, _ in self.state.requests))

    def test_second_run_is_idempotent_and_repairs_ro_metadata(self) -> None:
        self.run_sync()
        put_count = sum(method == "PUT" for method, _, _, _ in self.state.requests)
        messages = self.run_sync()
        self.assertEqual(sum(method == "PUT" for method, _, _, _ in self.state.requests), put_count)
        self.assertTrue(all("already synchronized" in message for message in messages))

        personal = "/.fs/_plug/silverbullet-vim-layout.plug.js"
        content, created, _ = self.state.files[personal]
        self.state.files[personal] = (content, created, "ro")
        self.run_sync()
        self.assertEqual(self.state.files[personal][2], "rw")
        self.assertEqual(self.state.files[personal][1], created)

    def test_http_failure_is_redacted_and_stops_with_failure(self) -> None:
        self.state.fail_path = "/ksp/.fs/_plug/silverbullet-vim-layout.plug.js"
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaises(sync_module.SyncError) as raised:
                self.run_sync()
        combined = output.getvalue() + str(raised.exception)
        self.assertNotIn(self.token, combined)
        self.assertIn("KSP write failed with HTTP 500", combined)

    def test_redirect_is_not_followed_with_authorization(self) -> None:
        self.state.redirect_path = "/.fs/_plug/silverbullet-vim-layout.plug.js"
        with self.assertRaisesRegex(sync_module.SyncError, "Personal read failed with HTTP 302") as raised:
            self.run_sync()
        self.assertNotIn(self.token, str(raised.exception))
        self.assertFalse(any(path == "/leak" for _, path, _, _ in self.state.requests))

    def test_byte_mismatch_fails_closed_and_token_permissions_are_checked(self) -> None:
        self.state.corrupt_path = "/.fs/_plug/silverbullet-vim-layout.plug.js"
        with self.assertRaisesRegex(sync_module.SyncError, "Personal verification failed"):
            self.run_sync()

        self.token_file.chmod(0o640)
        with self.assertRaisesRegex(sync_module.SyncError, "accessible by group") as raised:
            self.run_sync()
        self.assertNotIn(self.token, str(raised.exception))


if __name__ == "__main__":
    unittest.main()
