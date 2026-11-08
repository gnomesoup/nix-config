"""Regression tests for Hoth application guards and direct Borg coverage."""

import contextlib
import importlib.util
import gzip
import hashlib
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
    def setUp(self):
        real_run = subprocess.run

        def fixture_commands_only(command, *args, **kwargs):
            if command[0] == "docker":
                raise AssertionError("Tests must mock Docker; never inspect a live container")
            return real_run(command, *args, **kwargs)

        guard = patch.object(subprocess, "run", side_effect=fixture_commands_only)
        guard.start()
        self.addCleanup(guard.stop)

    @unittest.skipUnless(shutil.which("borg") and os.environ.get("HOTH_BACKUP_EXCLUDES"),
                         "Nix check supplies Borg and actual Hoth exclusions")
    def test_actual_borg_scope_excludes_live_databases_but_preserves_media(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            excluded = [
                "home/mpfammatter/docker/immich-db/PG_VERSION",
                "home/mpfammatter/docker/immich-db-pg17/PG_VERSION",
                "home/mpfammatter/docker/frigate/frigate.db",
                "home/mpfammatter/docker/frigate/frigate.db-wal",
            ]
            included = [
                "home/mpfammatter/docker/frigate/config.yml",
                "home/mpfammatter/docker/frigate/media/recordings/fixture.mp4",
                "mnt/backup1/immich/library/fixture.jpg",
            ]
            for name in excluded + included:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("test-only backup scope fixture")
            source = root / "mnt/backup1/immich/backups"
            source.mkdir(parents=True)
            native = self.native_dump(source)
            native_bytes = native.read_bytes()
            unfinished = source / (native.name + ".tmp")
            unfinished.write_bytes(b"unfinished upstream gzip fixture")
            excluded.append(str(unfinished.relative_to(root)))
            included.append(str(native.relative_to(root)))
            environment = os.environ | {"BORG_REPO": str(root / "repo"),
                "BORG_PASSPHRASE": "test-only-scope-fixture", "HOME": str(root / "home-env")}

            def borg(*args, cwd=root):
                return subprocess.run(["borg", *args], check=True, cwd=cwd, env=environment,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout

            borg("init", "--encryption", "repokey-blake2")
            arguments = ["create"]
            for pattern in json.loads(os.environ["HOTH_BACKUP_EXCLUDES"]):
                arguments += ["--exclude", pattern]
            borg(*arguments, "::scope-test", "home/mpfammatter", "mnt/backup1/immich")
            paths = {json.loads(line)["path"] for line in
                     borg("list", "--json-lines", "::scope-test").splitlines()}
            for name in excluded:
                self.assertNotIn(name, paths)
            for name in included:
                self.assertIn(name, paths)
            restored = root / "restored"
            restored.mkdir()
            borg("extract", "::scope-test", cwd=restored)
            restored_dump = restored / native.relative_to(root)
            self.assertEqual(restored_dump.read_bytes(), native_bytes)
            self.assertEqual(hashlib.sha256(restored_dump.read_bytes()).hexdigest(),
                             hashlib.sha256(native_bytes).hexdigest())
            self.assertIn(b"-- PostgreSQL database dump complete",
                          gzip.decompress(restored_dump.read_bytes()).splitlines())
            self.assertEqual(restored_dump.name, native.name)

            # Borg backs up the folder even when Immich has not produced a dump.
            native.unlink()
            unfinished.unlink()
            source.rmdir()
            photo = "mnt/backup1/immich/library/fixture.jpg"
            for state in ("missing", "empty"):
                with self.subTest(backups_directory=state):
                    if state == "empty":
                        source.mkdir()
                    archive = f"::no-dump-{state}"
                    borg(*arguments, archive, "home/mpfammatter", "mnt/backup1/immich")
                    paths = {json.loads(line)["path"] for line in
                             borg("list", "--json-lines", archive).splitlines()}
                    self.assertIn(photo, paths)
                    self.assertNotIn(str(native.relative_to(root)), paths)
                    for name in excluded:
                        self.assertNotIn(name, paths)
                    recovered = root / f"restored-no-dump-{state}"
                    recovered.mkdir()
                    borg("extract", archive, cwd=recovered)
                    self.assertEqual((recovered / photo).read_bytes(), (root / photo).read_bytes())

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
                    self.frigate_api(module, b'{"database":{"path":"/media/frigate/custom.db"}}'):
                with self.assertRaisesRegex(RuntimeError, "Frigate|frigate"):
                    module.main()

    def test_default_frigate_database_allows_backup_without_disclosing_config(self):
        module = self.module()
        payload = json.dumps({"database": {"path": "/config/frigate.db"},
                              "cameras": {"secret": "test-only-private-camera-url"},
                              "environment_vars": {"TOKEN": "test-only-private-token"}}).encode()
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {"BACKUP_STAGING_DIRECTORY": directory}), \
                patch.object(module, "verify_mounts"), \
                self.frigate_api(module, payload) as probe:
            module.main()
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

    def test_refuses_changed_immich_mount(self):
        module = self.module()
        with patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess(
            [], 0, stdout=json.dumps([{"Destination": "/data", "Source": "/different", "Type": "bind"}])
        )):
            with self.assertRaisesRegex(RuntimeError, "mount"):
                module.verify_mounts("immich_server", {"/data": "/expected"})

    def native_dump(self, source):
        path = source / "immich-db-backup-20260101T010000-v3.3.6-pg17.10.sql.gz"
        path.write_bytes(gzip.compress(
            b"-- test-only SQL fixture\n-- PostgreSQL database dump complete\n"))
        return path

    def test_main_preserves_guards_without_checking_absent_old_or_bad_dumps(self):
        module = self.module()
        for state in ("absent", "old", "bad"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                source = Path(directory) / "backups"
                if state != "absent":
                    source.mkdir()
                    dump = self.native_dump(source)
                    if state == "old":
                        os.utime(dump, (1, 1))
                    else:
                        dump.write_bytes(b"not gzip or SQL")
                calls = []
                with contextlib.ExitStack() as guards:
                    guards.enter_context(patch.object(module.os, "umask"))
                    guards.enter_context(patch.object(module, "verify_mounts",
                        side_effect=lambda *args: calls.append(args)))
                    guards.enter_context(patch.object(module, "verify_frigate_database",
                        side_effect=lambda: calls.append("frigate")))
                    validator = guards.enter_context(patch.object(module, "validate_immich_dump",
                        create=True, side_effect=AssertionError("must not validate dumps")))
                    for target in ("builtins.open", "io.open", "os.open", "os.listdir",
                                   "os.scandir", "os.stat", "os.lstat", "os.fstat",
                                   "gzip.GzipFile", "gzip.decompress"):
                        guards.enter_context(patch(target,
                            side_effect=AssertionError("must not inspect dumps")))
                    module.main()
                    validator.assert_not_called()
                self.assertEqual(calls, [
                    ("immich_server", {"/data": module.IMMICH_DATA,
                                       "/usr/src/app/upload": "/mnt/backup1/immich"}),
                    ("immich_postgres", {"/var/lib/postgresql/data":
                                         "/home/mpfammatter/docker/immich-db-pg17"}),
                    ("frigate", {"/config": "/home/mpfammatter/docker/frigate",
                                 "/media/frigate": "/home/mpfammatter/docker/frigate/media"}),
                    "frigate",
                ])
        self.assertFalse(hasattr(module, "AUTH"))
        self.assertFalse(hasattr(module, "export_postgres"))
        self.assertFalse(hasattr(module, "stage_immich_dump"))


if __name__ == "__main__":
    unittest.main()
