"""Exercise the packaged server's persistent search and managed plug retirement."""

from __future__ import annotations

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import uuid


class ServerSearchTest(unittest.TestCase):
    def test_existing_multispace_routes_tokens_and_search_survive_upgrade(self) -> None:
        binary = os.environ["SB_TEST_SERVER"]
        previous = os.environ["SB_TEST_PREVIOUS_SERVER"]
        spec = importlib.util.spec_from_file_location("sync", os.environ["SB_SYNC_SCRIPT"])
        assert spec and spec.loader
        sync = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sync)
        with tempfile.TemporaryDirectory(prefix="silverbullet-multi-") as temporary:
            root = Path(temporary)
            data = root / "data"
            environment = os.environ | {"HOME": str(root / "home"), "SB_RUNTIME_API": "0"}
            for name in ("SB_SEARCH_DIR", "SB_SEARCH_MODEL", "SB_AUTH_TOKEN", "SB_USER"):
                environment.pop(name, None)
            subprocess.run(
                [previous, "setup", "--admin", "fixture:fixture-password",
                 "--space", "Personal", "--at", "/", str(data)],
                check=True, env=environment, stdout=subprocess.DEVNULL, timeout=20,
            )
            spaces_file = data / "spaces.json"
            spaces = json.loads(spaces_file.read_text())
            personal_id, personal = next(iter(spaces.items()))
            ksp_id = str(uuid.uuid4())
            spaces[ksp_id] = personal | {
                "name": "KSP", "folder": f"spaces/{ksp_id}",
                "binding": {"prefix": "/ksp"},
            }
            spaces_file.write_text(json.dumps(spaces))
            expected = {"": "PersonalSearch", "/ksp": "WorkSearch"}
            for space_id, page in ((personal_id, "PersonalSearch"), (ksp_id, "WorkSearch")):
                folder = data / spaces[space_id]["folder"]
                folder.mkdir(parents=True, exist_ok=True)
                (folder / f"{page}.md").write_text("The orchid is searchable.\n")
                (folder / "_plug").mkdir(exist_ok=True)
                (folder / "_plug/silversearch.plug.js").write_text("// retired fixture\n")
            users_file = data / "users.json"
            users = json.loads(users_file.read_text())
            users["fixture"]["tokens"] = {
                "search-fixture": {
                    "tokenHash": hashlib.sha256(b"multispace-test-token").hexdigest(),
                    "createdAt": "2026-11-05T00:00:00Z",
                }
            }
            users_file.write_text(json.dumps(users))
            token = root / "token"
            token.write_text("multispace-test-token\n")
            token.chmod(0o600)
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            base = f"http://127.0.0.1:{port}"
            for _ in range(2):
                with (root / "server.log").open("wb") as log:
                    process = subprocess.Popen(
                        [binary, "-L", "127.0.0.1", "-p", str(port), str(data)],
                        env=environment, stdout=log, stderr=log,
                    )
                    try:
                        for prefix, page in expected.items():
                            deadline = time.monotonic() + 20
                            while True:
                                self.assertIsNone(process.poll(), "MultiSpace fixture exited")
                                req = urllib.request.Request(
                                    base + prefix + "/.search/query",
                                    data=json.dumps({"query": "orchid"}).encode(),
                                    headers={"Content-Type": "application/json",
                                             "Authorization": "Bearer multispace-test-token"},
                                )
                                try:
                                    with urllib.request.urlopen(req, timeout=2) as response:
                                        result = json.load(response)
                                    if result.get("items"):
                                        self.assertEqual(
                                            {item["page"] for item in result["items"]}, {page}
                                        )
                                        break
                                except urllib.error.HTTPError as error:
                                    error.close()
                                except OSError:
                                    pass
                                self.assertLess(time.monotonic(), deadline, "MultiSpace search failed")
                                time.sleep(0.1)
                        sync.remove(token, base, "_plug/silversearch.plug.js")
                        for cfg in spaces.values():
                            self.assertFalse(
                                (data / cfg["folder"] / "_plug/silversearch.plug.js").exists()
                            )
                        indexes = data / "search/indexes"
                        self.assertTrue(indexes.is_dir())
                        self.assertGreaterEqual(len(list(indexes.iterdir())), 2)
                    finally:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)

    def test_search_persists_across_restart_and_retired_plug_is_removed(self) -> None:
        binary = os.environ["SB_TEST_SERVER"]
        spec = importlib.util.spec_from_file_location("sync", os.environ["SB_SYNC_SCRIPT"])
        assert spec and spec.loader
        sync = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sync)
        with tempfile.TemporaryDirectory(prefix="silverbullet-edge-") as temporary:
            root = Path(temporary)
            space = root / "space"
            space.mkdir()
            (space / "Garden.md").write_text("The orchid blooms in winter.\n")
            index = root / "search"
            token = root / "fixture-token"
            token.write_text("search-test-token\n")
            token.chmod(0o600)
            plug = root / "retired.plug.js"
            plug.write_text("// retirement fixture\n")
            environment = os.environ | {
                "HOME": str(root / "home"),
                "SB_SEARCH_DIR": str(index),
                "SB_RUNTIME_API": "0",
                "SB_AUTH_TOKEN": "search-test-token",
                "SB_USER": "fixture:fixture-password",
            }
            # Never inherit model configuration: full-text search needs no downloads.
            environment.pop("SB_SEARCH_MODEL", None)
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            base = f"http://127.0.0.1:{port}"
            removal = Path(os.environ["SB_SYNC_SCRIPT"]).read_text()
            replacements = {
                "tokenFile": str(token),
                "filePathOnDisk": "/dev/null",
                "baseUrl": base,
                "filePathInSpace": "_plug/silversearch.plug.js",
                "spacePrefixes": json.dumps([["Fixture", ""]]),
                "contentType": "application/javascript",
            }
            for name, value in replacements.items():
                removal = removal.replace(f"@{name}@", value)
            removal_script = root / "remove.py"
            removal_script.write_text(removal)

            def request(path: str, payload: dict | None = None) -> dict:
                data = None if payload is None else json.dumps(payload).encode()
                req = urllib.request.Request(
                    base + path,
                    data=data,
                    headers={
                        "Authorization": "Bearer search-test-token",
                        "Content-Type": "application/json",
                    },
                )
                with urllib.request.urlopen(req, timeout=2) as response:
                    return json.load(response)

            def await_search(process: subprocess.Popen, query: str) -> None:
                deadline = time.monotonic() + 20
                while True:
                    self.assertIsNone(process.poll(), "fixture server exited")
                    try:
                        result = request("/.search/query", {"query": query})
                        if any(item["page"] == "Garden" for item in result["items"]):
                            return
                    except urllib.error.HTTPError as error:
                        error.close()
                    except OSError:
                        pass
                    self.assertLess(time.monotonic(), deadline, "search never found Garden")
                    time.sleep(0.1)

            for restart in range(2):
                with (root / "server.log").open("wb") as log:
                    process = subprocess.Popen(
                        [binary, "--single", "-L", "127.0.0.1", "-p", str(port), str(space)],
                        env=environment,
                        stdout=log,
                        stderr=log,
                    )
                    try:
                        await_search(process, "orchid")
                        status = request("/.search/status")
                        self.assertEqual(status["backend"], "fulltext")
                        self.assertTrue((index / "indexes/single").is_dir())
                        self.assertTrue(any((index / "indexes/single").iterdir()))
                        if restart == 0:
                            sync.sync(
                                token, plug, base, "_plug/silversearch.plug.js",
                                space_prefixes=(("Fixture", ""),),
                            )
                        subprocess.run(
                            [sys.executable, str(removal_script), "--remove"],
                            check=True,
                            timeout=10,
                        )
                        self.assertFalse((space / "_plug/silversearch.plug.js").exists())
                        self.assertEqual(
                            (space / "Garden.md").read_text(),
                            "The orchid blooms in winter.\n",
                        )
                    finally:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
                self.assertTrue((index / "indexes/single").is_dir())


if __name__ == "__main__":
    unittest.main(verbosity=2)
