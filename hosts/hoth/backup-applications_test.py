"""Regression tests for Hoth's application coverage and Immich database export."""

import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import urllib.error
import urllib.request
from email.message import Message
from pathlib import Path
from unittest.mock import patch


class ApplicationBackupTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("borg") and os.environ.get("HOTH_BACKUP_EXCLUDES"),
                         "Nix check supplies Borg and actual Hoth exclusions")
    def test_actual_borg_scope_excludes_live_databases_but_preserves_media(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = [
                "home/mpfammatter/docker/immich-db/PG_VERSION",
                "home/mpfammatter/docker/frigate/frigate.db",
                "home/mpfammatter/docker/frigate/frigate.db-wal",
                "home/mpfammatter/docker/frigate/config.yml",
                "home/mpfammatter/docker/frigate/media/recordings/fixture.mp4",
            ]
            for name in files:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("test-only backup scope fixture")
            environment = os.environ | {"BORG_REPO": str(root / "repo"),
                "BORG_PASSPHRASE": "test-only-scope-fixture", "HOME": str(root / "home-env")}

            def borg(*args):
                return subprocess.run(["borg", *args], check=True, cwd=root, env=environment,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout

            borg("init", "--encryption", "repokey-blake2")
            arguments = ["create"]
            for pattern in json.loads(os.environ["HOTH_BACKUP_EXCLUDES"]):
                arguments += ["--exclude", pattern]
            borg(*arguments, "::scope-test", "home/mpfammatter")
            paths = {json.loads(line)["path"] for line in
                     borg("list", "--json-lines", "::scope-test").splitlines()}
            for name in files[:3]:
                self.assertNotIn(name, paths)
            for name in files[3:]:
                self.assertIn(name, paths)

    def module(self):
        path = Path(__file__).with_name("backup-applications.py")
        self.assertTrue(path.exists(), "Hoth application preparation is missing")
        spec = importlib.util.spec_from_file_location("backup_applications", path)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def frigate_api(self, module, payload, error=None):
        """Execute the container Python probe, replacing only its HTTP transport."""
        def run(command, **kwargs):
            self.assertEqual(command[:5], ["docker", "exec", "frigate", "python3", "-c"])
            self.assertTrue(kwargs["check"])
            self.assertLessEqual(kwargs["timeout"], 60)
            output = io.StringIO()
            errors = io.StringIO()

            def open_request(request, timeout):
                self.assertEqual(request.full_url, "http://127.0.0.1:5000/api/config")
                self.assertEqual(request.get_method(), "GET")
                self.assertEqual(request.get_header("X-cache-bypass"), "1")
                self.assertLessEqual(timeout, 30)
                if error is not None:
                    raise error
                return io.BytesIO(payload)

            with patch.object(urllib.request.OpenerDirector, "open", side_effect=open_request), \
                    contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                try:
                    exec(command[-1], {"__name__": "__main__"})
                except SystemExit as failure:
                    if failure.code:
                        self.assertEqual(output.getvalue(), "")
                        self.assertEqual(errors.getvalue(), "")
                        raise subprocess.CalledProcessError(1, command) from None
            self.assertEqual(output.getvalue(),
                             json.dumps(json.loads(payload)["database"]["path"]) + "\n")
            self.assertEqual(errors.getvalue(), "")
            return subprocess.CompletedProcess(command, 0, stdout=output.getvalue())
        return patch.object(module.subprocess, "run", side_effect=run)

    def test_stale_default_export_does_not_cover_active_custom_frigate_database(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # Generic capture has already exported the stale required default DB.
            (root / "frigate.db").write_bytes(b"stale default database")
            (root / "sqlite-export.db").write_bytes(b"successful stale export")
            (root / "custom.db").write_bytes(b"active database omitted from capture")
            with patch.dict(os.environ, {"BACKUP_STAGING_DIRECTORY": directory}), \
                    patch.object(module, "verify_mounts"), \
                    patch.object(module, "export_postgres") as export, \
                    self.frigate_api(module, b'{"database":{"path":"/media/frigate/custom.db"}}'):
                with self.assertRaisesRegex(RuntimeError, "Frigate|frigate"):
                    module.main()
                export.assert_not_called()

    def test_default_frigate_database_allows_export_without_disclosing_config(self):
        module = self.module()
        payload = json.dumps({"database": {"path": "/config/frigate.db"},
                              "cameras": {"secret": "test-only-private-camera-url"},
                              "environment_vars": {"TOKEN": "test-only-private-token"}}).encode()
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {"BACKUP_STAGING_DIRECTORY": directory}), \
                patch.object(module, "verify_mounts"), \
                patch.object(module, "export_postgres") as export, \
                self.frigate_api(module, payload) as probe:
            module.main()
            export.assert_called_once_with("immich_postgres", Path(directory) / "exports")
            self.assertEqual(probe.call_count, 1)

    def test_invalid_or_missing_effective_config_fails_closed(self):
        module = self.module()
        payloads = [b"", b"not JSON", b"<html>login</html>", b"null", b"[]",
                    b"{}", b'{"database": null}', b'{"database": []}',
                    b'{"database": {}}', b'{"database": {"path": null}}',
                    b'{"database": {"path": 42}}', b'{"database": {"path": []}}',
                    b'{"database": {"path": ""}}']
        for payload in payloads:
            with self.subTest(payload=payload), self.frigate_api(module, payload):
                with self.assertRaisesRegex(RuntimeError, "Frigate"):
                    module.verify_frigate_database()

    def test_frigate_api_errors_fail_closed_without_disclosing_response(self):
        module = self.module()
        errors = [urllib.error.URLError("test-only-private-token"),
                  urllib.error.HTTPError("http://127.0.0.1:5000/api/config", 500,
                                         "test-only-private-token", Message(), None),
                  TimeoutError("test-only-private-token")]
        for error in errors:
            if isinstance(error, urllib.error.HTTPError):
                self.addCleanup(error.close)
            with self.subTest(error=type(error).__name__), \
                    self.frigate_api(module, b"", error=error):
                with self.assertRaisesRegex(RuntimeError, "Frigate") as failure:
                    module.verify_frigate_database()
                self.assertNotIn("test-only-private-token", str(failure.exception))

    def test_frigate_docker_errors_fail_closed_without_disclosing_output(self):
        module = self.module()
        errors = [subprocess.CalledProcessError(1, ["docker"],
                                              output="test-only-private-token"),
                  subprocess.TimeoutExpired(["docker"], 30,
                                            output="test-only-private-token"),
                  FileNotFoundError("docker unavailable")]
        for error in errors:
            with self.subTest(error=type(error).__name__), \
                    patch.object(module.subprocess, "run", side_effect=error):
                with self.assertRaisesRegex(RuntimeError, "Frigate") as failure:
                    module.verify_frigate_database()
                self.assertNotIn("test-only-private-token", str(failure.exception))

    def test_refuses_changed_immich_mount_before_export(self):
        module = self.module()
        with patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess(
            [], 0, stdout=json.dumps([{"Destination": "/data", "Source": "/different", "Type": "bind"}])
        )):
            with self.assertRaisesRegex(RuntimeError, "mount"):
                module.verify_mounts("immich_server", {"/data": "/expected"})

    def test_dump_is_published_only_after_success_and_completion_footer(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)

            def run(command, **kwargs):
                if "pg_database_size" in command[-1]:
                    return subprocess.CompletedProcess(command, 0, stdout="1024\n")
                if "pg_dumpall" in command[-1]:
                    kwargs["stdout"].write(b"-- test-only SQL fixture\n-- PostgreSQL database cluster dump complete\n")
                return subprocess.CompletedProcess(command, 0, stdout="")

            with patch.object(module.subprocess, "run", side_effect=run):
                module.export_postgres("immich_postgres", destination, reserve_bytes=0)
            self.assertTrue((destination / "immich.sql").is_file())
            self.assertEqual((destination / "immich.sql").stat().st_mode & 0o777, 0o600)
            self.assertFalse((destination / "immich.sql.partial").exists())

    def test_failed_export_leaves_no_published_dump(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)

            def run(command, **kwargs):
                if "pg_database_size" in command[-1]:
                    return subprocess.CompletedProcess(command, 0, stdout="1024\n")
                kwargs["stdout"].write(b"incomplete test-only fixture")
                raise subprocess.CalledProcessError(1, command)

            with patch.object(module.subprocess, "run", side_effect=run):
                with self.assertRaises(subprocess.CalledProcessError):
                    module.export_postgres("immich_postgres", destination, reserve_bytes=0)
            self.assertFalse((destination / "immich.sql").exists())
            self.assertFalse((destination / "immich.sql.partial").exists())

    def test_missing_dump_footer_fails_closed(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)

            def run(command, **kwargs):
                if "pg_database_size" in command[-1]:
                    return subprocess.CompletedProcess(command, 0, stdout="1024\n")
                kwargs["stdout"].write(b"truncated test-only SQL")
                return subprocess.CompletedProcess(command, 0)

            with patch.object(module.subprocess, "run", side_effect=run):
                with self.assertRaisesRegex(RuntimeError, "complete"):
                    module.export_postgres("immich_postgres", destination, reserve_bytes=0)
            self.assertFalse((destination / "immich.sql").exists())


if __name__ == "__main__":
    unittest.main()
