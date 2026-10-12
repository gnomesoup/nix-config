from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import ClassVar
from unittest.mock import patch
from urllib.parse import unquote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))

from client import (
    ConflictError,
    SilverBulletClient,
    SilverBulletError,
    normalize_page,
    parse_config,
)


class State:
    token = "test-secret-token"
    spaces: ClassVar = {"personal": {}, "ksp": {}}
    corrupt_upload = False


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def _target(self):
        path = urlsplit(self.path).path
        if path == "/.fs" or path.startswith("/.fs/"):
            space, remainder = "personal", path[len("/.fs") :]
        elif path == "/ksp/.fs" or path.startswith("/ksp/.fs/"):
            space, remainder = "ksp", path[len("/ksp/.fs") :]
        else:
            return None, None
        page = "/".join(unquote(part) for part in remainder.lstrip("/").split("/")) if remainder else None
        return space, page or None

    def _send(self, status, body=b"", headers=None):
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, str(value))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        if self.headers.get("Authorization") != f"Bearer {State.token}":
            self._send(401, f"reflected {self.headers.get('Authorization')}".encode())
            return False
        return True

    def do_GET(self):
        if not self._authorized():
            return
        space, page = self._target()
        if space is None:
            self._send(404)
            return
        files = State.spaces[space]
        if page is None:
            body = json.dumps(
                [
                    {
                        "name": name,
                        "created": item["created"],
                        "lastModified": item["last_modified"],
                        "contentType": item.get("content_type", "text/markdown"),
                        "size": len(item.get("body", item["content"].encode())),
                        "perm": item["permission"],
                    }
                    for name, item in files.items()
                ]
            ).encode()
            self._send(200, body, {"Content-Type": "application/json"})
            return
        item = files.get(page)
        if item is None:
            self._send(404, b"not found")
            return
        body = item.get("body", item["content"].encode())
        self._send(
            200,
            body,
            {
                "Content-Type": "application/octet-stream",
                "X-Content-Type": item.get("content_type", "text/markdown"),
                "X-Created": item["created"],
                "X-Last-Modified": item["last_modified"],
                "X-Content-Length": len(body),
                "X-Permission": item["permission"],
            },
        )

    def do_PUT(self):
        if not self._authorized():
            return
        space, page = self._target()
        if not space or not page:
            self._send(405)
            return
        if self.headers.get("X-Sync-Mode") != "true":
            self._send(400, b"missing sync mode")
            return
        if self.headers.get("If-None-Match") == "*" and page in State.spaces[space]:
            self._send(412)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if State.corrupt_upload:
            body += b"corrupted"
        State.spaces[space][page] = {
            "content": body.decode(errors="replace"),
            "body": body,
            "content_type": self.headers["Content-Type"],
            "created": int(self.headers["X-Created"]),
            "last_modified": int(self.headers["X-Last-Modified"]),
            "permission": self.headers["X-Permission"],
        }
        self._send(200, b"OK")

    def do_DELETE(self):
        if not self._authorized():
            return
        space, page = self._target()
        if not space or page not in State.spaces[space]:
            self._send(404)
            return
        del State.spaces[space][page]
        self._send(200, b"OK")


class FakeContext:
    def __init__(self, settings):
        self.settings = settings
        self.tools = {}
        self.skills = []
        self.sections = []

    def get_config(self, key, default=None):
        return self.settings.get(key, default)

    def register_tool(self, **kwargs):
        self.tools[kwargs["name"]] = kwargs

    def register_skill(self, *args):
        self.skills.append(args)

    def register_system_prompt_section(self, *args, **kwargs):
        self.sections.append((args, kwargs))


class SilverBulletPluginTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.token_file = Path(cls.temp.name) / "token"
        cls.token_file.write_text(f"{State.token}\n")
        cls.token_file.chmod(0o600)
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.temp.cleanup()

    def setUp(self):
        State.corrupt_upload = False
        stamp = 1_750_000_000_000
        State.spaces = {
            "personal": {
                "Shared.md": {
                    "content": "AAA target\n",
                    "created": stamp,
                    "last_modified": stamp,
                    "permission": "rw",
                },
                "Library/Managed.md": {
                    "content": "system target\n",
                    "created": stamp,
                    "last_modified": stamp,
                    "permission": "ro",
                },
            },
            "ksp": {
                "Shared.md": {
                    "content": "BBB target\n",
                    "created": stamp,
                    "last_modified": stamp,
                    "permission": "rw",
                }
            },
        }
        self.settings = {
            "base_url": self.base_url,
            "allow_insecure_http": True,
            "token_file": str(self.token_file),
            "default_space": "personal",
            "spaces": {
                "personal": {
                    "label": "Personal",
                    "path": "/",
                    "allowed_read_paths": [""],
                    "allowed_write_paths": [""],
                },
                "ksp": {
                    "label": "KSP",
                    "path": "/ksp",
                    "allowed_read_paths": [""],
                    "allowed_write_paths": [""],
                },
            },
            "max_content_bytes": 2 * 1024 * 1024,
            "allowed_upload_roots": [self.temp.name],
            "max_search_bytes": 64 * 1024 * 1024,
            "max_result_chars": 50_000,
        }
        self.client = SilverBulletClient(parse_config(self.settings))

    def test_upload_binary_image_verifies_bytes_and_links(self):
        source = Path(self.temp.name) / "label.png"
        body = b"\x89PNG\r\n\x1a\n\xff\x00label"
        source.write_bytes(body)
        context = self._register()
        self.assertIn("silverbullet_upload_file", context.tools)
        result = self._call(context, "silverbullet_upload_file", {
            "space": "ksp", "source_path": str(source),
            "destination": "assets/Desk label.png",
        })
        self.assertNotIn("error", result)
        self.assertTrue(result["verified"])
        self.assertEqual(result["bytes"], len(body))
        self.assertEqual(result["metadata"]["content_type"], "image/png")
        self.assertEqual(result["markdown_image"],
                         "![Desk label.png](/ksp/assets/Desk%20label.png)")
        self.assertEqual(State.spaces["ksp"]["assets/Desk label.png"]["body"], body)
        self.assertNotIn("assets/Desk label.png", State.spaces["personal"])

    def test_upload_retries_are_idempotent_and_never_replace_different_bytes(self):
        source = Path(self.temp.name) / "document.pdf"
        source.write_bytes(b"%PDF-1.7\x00\xff")
        context = self._register()
        args = {"source_path": str(source), "destination": "assets/document.pdf"}
        first = self._call(context, "silverbullet_upload_file", args)
        self.assertTrue(first["verified"])
        self.assertIsNone(first["markdown_image"])
        self.assertEqual(first["metadata"]["content_type"], "application/pdf")
        second = self._call(context, "silverbullet_upload_file", args)
        self.assertEqual(second["action"], "already_present")
        self.assertEqual(second["metadata"]["last_modified"], first["metadata"]["last_modified"])
        source.write_bytes(b"different")
        refused = self._call(context, "silverbullet_upload_file", args)
        self.assertIn("already exists", refused["error"])
        self.assertEqual(State.spaces["personal"]["assets/document.pdf"]["body"], b"%PDF-1.7\x00\xff")

    def test_upload_refuses_unsafe_sources_destinations_and_oversize_files(self):
        source = Path(self.temp.name) / "source.png"
        source.write_bytes(b"image")
        context = self._register()
        for destination in ("../escape.png", "Library/test.png", "assets/../test.png",
                            "assets/.hidden.png", "/assets/test.png", "assets/test.png "):
            with self.subTest(destination=destination):
                result = self._call(context, "silverbullet_upload_file", {
                    "source_path": str(source), "destination": destination,
                })
                self.assertIn("error", result)
        for unsafe in ("relative.png", "/etc/passwd", str(Path(self.temp.name) / "missing"),
                       self.temp.name):
            with self.subTest(source=unsafe):
                result = self._call(context, "silverbullet_upload_file", {
                    "source_path": unsafe, "destination": "assets/test.png",
                })
                self.assertIn("error", result)
        hidden = Path(self.temp.name) / ".private"
        hidden.write_bytes(b"secret")
        link = Path(self.temp.name) / "alias.png"
        link.symlink_to("/etc/passwd")
        for unsafe in (hidden, link):
            result = self._call(context, "silverbullet_upload_file", {
                "source_path": str(unsafe), "destination": "assets/test.png",
            })
            self.assertIn("error", result)
        self.settings["max_upload_bytes"] = 4
        limited = self._register()
        result = self._call(limited, "silverbullet_upload_file", {
            "source_path": str(source), "destination": "assets/test.png",
        })
        self.assertIn("max_upload_bytes", result["error"])
        self.assertNotIn("assets/test.png", State.spaces["personal"])

    def test_upload_refuses_ancestor_swap_to_hidden_directory_before_open(self):
        with tempfile.TemporaryDirectory(dir=self.temp.name) as directory:
            root = Path(directory)
            visible = root / "visible"
            visible.mkdir()
            source = visible / "source.png"
            source.write_bytes(b"public image")
            hidden = root / ".private"
            hidden.mkdir()
            (hidden / source.name).write_bytes(b"private image")
            real_open = os.open

            def swap_before_open(path, flags, *args, **kwargs):
                self.assertEqual(path, source)
                visible.rename(root / "original")
                visible.symlink_to(hidden, target_is_directory=True)
                return real_open(path, flags, *args, **kwargs)

            with patch("client.os.open", side_effect=swap_before_open) as opened:
                with self.assertRaisesRegex(SilverBulletError, "Hidden source files"):
                    self.client.upload_file(self.client.space(), str(source), "assets/private.png")
            opened.assert_called_once()
            self.assertNotIn("assets/private.png", State.spaces["personal"])

    def test_upload_cannot_bypass_space_write_allowlists(self):
        self.settings["spaces"]["personal"]["allowed_write_paths"] = ["Journal"]
        context = self._register()
        source = Path(self.temp.name) / "source.png"
        source.write_bytes(b"image")
        result = self._call(context, "silverbullet_upload_file", {
            "source_path": str(source), "destination": "assets/test.png",
        })
        self.assertIn("allowlist", result["error"])

    def test_upload_reports_failed_readback_verification(self):
        source = Path(self.temp.name) / "source.png"
        source.write_bytes(b"image")
        State.corrupt_upload = True
        result = self._call(self._register(), "silverbullet_upload_file", {
            "source_path": str(source), "destination": "assets/test.png",
        })
        self.assertIn("verification failed", result["error"])
        self.assertNotIn("verified", result)

    def test_upload_configuration_rejects_roots_resolving_to_filesystem_root(self):
        with self.assertRaises(SilverBulletError):
            parse_config({**self.settings, "allowed_upload_roots": ["/var/.."]})

    def test_configuration_paths_and_credentials_are_restricted(self):
        self.assertEqual(normalize_page("Projects/Test"), "Projects/Test.md")
        with self.assertRaises(SilverBulletError):
            normalize_page("../escape")
        with self.assertRaises(SilverBulletError):
            parse_config({**self.settings, "base_url": f"{self.base_url}/path"})
        with self.assertRaises(SilverBulletError):
            parse_config({**self.settings, "base_url": "http://notes.example.test", "allow_insecure_http": False})
        with self.assertRaises(SilverBulletError):
            parse_config({**self.settings, "spaces": {"bad": {"label": "Bad", "path": "/../bad"}}})
        with self.assertRaises(SilverBulletError):
            parse_config(
                {
                    **self.settings,
                    "spaces": {
                        "personal": {
                            "label": "Personal",
                            "path": "/",
                            "allowed_read_paths": ["Projects"],
                            "allowed_write_paths": ["Journal"],
                        }
                    },
                }
            )
        with self.assertRaises(SilverBulletError):
            parse_config({**self.settings, "spaces": {"Pérsonal": {"label": "Bad", "path": "/"}}})

        self.token_file.chmod(0o640)
        try:
            self.assertFalse(self.client.available())
        finally:
            self.token_file.chmod(0o600)
        self.assertTrue(self.client.available())

    def test_systemd_credential_with_acl_mask_mode_is_accepted(self):
        credential_directory = Path(self.temp.name) / "credentials"
        credential_directory.mkdir()
        token_file = credential_directory / "silverbullet-api-token"
        token_file.write_text(f"{State.token}\n")
        token_file.chmod(0o440)
        settings = {key: value for key, value in self.settings.items() if key != "token_file"}

        config = parse_config(
            settings,
            environ={"CREDENTIALS_DIRECTORY": str(credential_directory)},
        )

        self.assertTrue(SilverBulletClient(config).available())

    def test_lists_reads_and_searches_spaces_independently(self):
        personal = self.client.space()
        ksp = self.client.space("ksp")
        self.assertEqual([item["name"] for item in self.client.list_files(personal)], ["Shared.md"])
        self.assertEqual(self.client.read_page(personal, "Shared.md").content, "AAA target\n")
        self.assertEqual(self.client.read_page(ksp, "Shared.md").content, "BBB target\n")

        context = self._register()
        result = self._call(context, "silverbullet_search", {"space": "ksp", "query": "BBB"})
        self.assertEqual(result["space"], "ksp")
        self.assertEqual(result["matches"][0]["page"], "Shared.md")
        self.assertNotIn("AAA", json.dumps(result))

    def test_create_append_update_and_conflict_guards(self):
        personal = self.client.space()
        created = self.client.create(personal, "Tests/New.md", "created")
        self.assertEqual(created.content, "created")
        with self.assertRaises(SilverBulletError):
            self.client.create(personal, "Tests/New.md", "overwrite")
        with self.assertRaises(ConflictError):
            self.client.append(personal, "Tests/New.md", "append")

        appended, was_created = self.client.append(
            personal,
            "Tests/New.md",
            "append",
            created.metadata.last_modified,
        )
        self.assertFalse(was_created)
        self.assertEqual(appended.content, "created\nappend")
        with self.assertRaises(ConflictError):
            self.client.update(personal, "Tests/New.md", "stale", created.metadata.last_modified)
        updated = self.client.update(personal, "Tests/New.md", "updated", appended.metadata.last_modified)
        self.assertEqual(updated.content, "updated")

    def test_move_soft_delete_and_explicit_permanent_delete(self):
        personal = self.client.space()
        shared = self.client.read_page(personal, "Shared.md")
        moved = self.client.move(personal, "Shared.md", "Archive/Shared.md", shared.metadata.last_modified)
        self.assertEqual(moved.page, "Archive/Shared.md")
        self.assertNotIn("Shared.md", State.spaces["personal"])

        destination, _ = self.client.soft_delete(
            personal,
            "Archive/Shared.md",
            moved.metadata.last_modified,
        )
        self.assertEqual(destination, "Trash/Archive/Shared.md")
        self.assertIn(destination, State.spaces["personal"])
        trashed = self.client.read_page(personal, destination)
        destination, _ = self.client.soft_delete(
            personal,
            destination,
            trashed.metadata.last_modified,
            permanent=True,
        )
        self.assertIsNone(destination)
        self.assertNotIn("Trash/Archive/Shared.md", State.spaces["personal"])

    def test_managed_writes_and_token_reflection_are_safe(self):
        personal = self.client.space()
        with self.assertRaisesRegex(SilverBulletError, "managed path"):
            self.client.update(personal, "Library/Managed.md", "bad", 1_750_000_000_000)

        original = State.token
        State.token = "different-server-token"
        try:
            with self.assertRaises(SilverBulletError) as raised:
                self.client.read_page(personal, "Shared.md")
            self.assertNotIn(original, str(raised.exception))
            self.assertIn("[REDACTED]", str(raised.exception))
        finally:
            State.token = original

    def test_plugin_registers_all_tools_skill_and_prompt_hint(self):
        context = self._register()
        self.assertEqual(set(context.tools), {
            "silverbullet_list_pages",
            "silverbullet_search",
            "silverbullet_read",
            "silverbullet_create",
            "silverbullet_update",
            "silverbullet_append",
            "silverbullet_move",
            "silverbullet_soft_delete",
            "silverbullet_upload_file",
        })
        self.assertEqual(context.skills[0][0], "silverbullet")
        self.assertEqual(context.sections[0][0][0], "inigo.silverbullet")
        read = self._call(context, "silverbullet_read", {"page": "Shared"})
        self.assertEqual(read["last_modified"], 1_750_000_000_000)
        self.assertTrue(read["untrusted_content"])

    def _register(self):
        package_path = Path(__file__).resolve().parent
        spec = importlib.util.spec_from_file_location(
            "inigo_silverbullet",
            package_path / "__init__.py",
            submodule_search_locations=[str(package_path)],
        )
        module = importlib.util.module_from_spec(spec)
        assert spec and spec.loader
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        context = FakeContext(self.settings)
        module.register(context)
        return context

    @staticmethod
    def _call(context, name, arguments):
        result = context.tools[name]["handler"](arguments)
        return json.loads(result)


if __name__ == "__main__":
    unittest.main()
