"""Regression tests for Hoth's application coverage and Immich native dump validation."""

import contextlib
import importlib.util
import gzip
import hashlib
import datetime
import time
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
            self.assertEqual(self.module().validate_immich_dump(source), native)
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
                    patch.object(module, "validate_immich_dump") as export, \
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
                patch.object(module, "validate_immich_dump") as export, \
                self.frigate_api(module, payload) as probe:
            module.main()
            export.assert_called_once_with("/mnt/backup1/immich/backups")
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

    def native_dump(self, source, age=3600, footer=b"-- PostgreSQL database dump complete", timestamp=None):
        when = time.time() - age if timestamp is None else timestamp
        stamp = datetime.datetime.fromtimestamp(when, datetime.timezone.utc).strftime("%Y%m%dT%H%M%S")
        path = source / f"immich-db-backup-{stamp}-v3.3.6-pg17.10.sql.gz"
        path.write_bytes(gzip.compress(b"-- test-only SQL fixture\n" + footer + b"\n"))
        os.utime(path, (when, when))
        return path

    def test_native_dump_is_validated_in_place_without_creating_files(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            dump = self.native_dump(source)
            original = dump.read_bytes()
            before = {path.name for path in source.iterdir()}
            info = dump.stat()
            with patch.object(shutil, "copyfileobj", side_effect=AssertionError("must not copy")), \
                    patch.object(module.os, "open", wraps=os.open) as opened:
                result = module.validate_immich_dump(source)
            for call in opened.call_args_list:
                self.assertEqual(call.args[1] & (os.O_CREAT | os.O_WRONLY | os.O_RDWR), 0)
            self.assertEqual(dump.stat().st_mtime_ns, info.st_mtime_ns)
            self.assertEqual(result, dump)
            self.assertEqual(dump.read_bytes(), original)
            self.assertEqual({path.name for path in source.iterdir()}, before)

    def test_invalid_native_dumps_fail_closed_without_creating_files(self):
        for problem in ("stale", "future", "empty", "truncated", "crc", "no-footer",
                        "substring-footer", "noncandidate", "partial", "invalid-date"):
            with self.subTest(problem=problem), tempfile.TemporaryDirectory() as directory:
                module = self.module()
                source = Path(directory)
                dump = self.native_dump(source)
                if problem == "stale":
                    when = time.time() - 37 * 3600
                    os.utime(dump, (when, when))
                elif problem == "future":
                    when = time.time() + 3600
                    os.utime(dump, (when, when))
                elif problem == "empty":
                    dump.write_bytes(b"")
                elif problem == "truncated":
                    dump.write_bytes(dump.read_bytes()[:-8])
                elif problem == "crc":
                    content = bytearray(dump.read_bytes())
                    content[-8] ^= 1
                    dump.write_bytes(content)
                elif problem == "no-footer":
                    dump.write_bytes(gzip.compress(b"-- incomplete SQL fixture\n"))
                elif problem == "substring-footer":
                    dump.write_bytes(gzip.compress(b"prefix -- PostgreSQL database dump complete suffix\n"))
                elif problem == "noncandidate":
                    dump = dump.rename(source / "other.sql.gz")
                elif problem == "partial":
                    dump = dump.rename(source / (dump.name + ".tmp"))
                elif problem == "invalid-date":
                    dump = dump.rename(source / "immich-db-backup-20269999T020000-v3.3.6-pg17.10.sql.gz")
                original = dump.read_bytes()
                with self.assertRaises((RuntimeError, OSError, ValueError)):
                    module.validate_immich_dump(source)
                self.assertEqual(dump.read_bytes(), original)
                self.assertEqual(list(source.iterdir()), [dump])

    def test_unsafe_paths_and_nonregular_candidates_fail_closed(self):
        for problem in ("source-link", "source-parent-link", "candidate-link", "candidate-dir", "candidate-fifo"):
            with self.subTest(problem=problem), tempfile.TemporaryDirectory() as directory:
                module = self.module()
                root = Path(directory)
                source = root / "native"
                source.mkdir()
                dump = self.native_dump(source)
                outside = root / "outside"
                outside.write_bytes(b"must not be touched")
                if problem == "candidate-link":
                    dump.unlink()
                    dump.symlink_to(outside)
                elif problem == "candidate-dir":
                    dump.unlink()
                    dump.mkdir()
                elif problem == "candidate-fifo":
                    dump.unlink()
                    os.mkfifo(dump)
                else:
                    link = root / "link"
                    link.symlink_to(source if problem == "source-link" else root, target_is_directory=True)
                    source = link if problem == "source-link" else link / "native"
                with self.assertRaises((RuntimeError, OSError)):
                    module.validate_immich_dump(source)
                self.assertEqual(outside.read_bytes(), b"must not be touched")

    def test_source_changes_during_validation_fail_closed(self):
        for change in ("replace", "modify", "parent-replace"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                module = self.module()
                root = Path(directory)
                source = root / "native"
                source.mkdir()
                dump = self.native_dump(source)
                validate = module.validate_gzip

                def changed_validate(incoming):
                    validate(incoming)
                    if change == "replace":
                        replacement = source / "new.tmp"
                        replacement.write_bytes(dump.read_bytes())
                        replacement.replace(dump)
                    elif change == "modify":
                        with dump.open("ab") as altered:
                            altered.write(b"modified")
                    else:
                        source.rename(root / "moved-native")
                        source.mkdir()

                with patch.object(module, "validate_gzip", side_effect=changed_validate):
                    with self.assertRaisesRegex(RuntimeError, "changed"):
                        module.validate_immich_dump(source)

    def test_main_preserves_all_mount_guards_and_validates_after_frigate(self):
        module = self.module()
        calls = []
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {"BACKUP_STAGING_DIRECTORY": directory}), \
                patch.object(module, "verify_mounts", side_effect=lambda *args: calls.append(args)), \
                patch.object(module, "verify_frigate_database", side_effect=lambda: calls.append("frigate")), \
                patch.object(module, "validate_immich_dump", side_effect=lambda *args: calls.append(args)):
            module.main()
            self.assertEqual(calls, [
                ("immich_server", {"/data": module.IMMICH_DATA, "/usr/src/app/upload": "/mnt/backup1/immich"}),
                ("immich_postgres", {"/var/lib/postgresql/data": "/home/mpfammatter/docker/immich-db-pg17"}),
                ("frigate", {"/config": "/home/mpfammatter/docker/frigate",
                             "/media/frigate": "/home/mpfammatter/docker/frigate/media"}),
                "frigate", ("/mnt/backup1/immich/backups",),
            ])
        self.assertFalse(hasattr(module, "AUTH"))
        self.assertFalse(hasattr(module, "export_postgres"))
        self.assertFalse(hasattr(module, "stage_immich_dump"))

    def test_validation_timeout_fails_closed(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            dump = self.native_dump(source)
            original = dump.read_bytes()
            with patch.object(module.time, "monotonic", side_effect=[0, 1801]):
                with self.assertRaisesRegex(RuntimeError, "timed out"):
                    module.validate_immich_dump(source)
            self.assertEqual(dump.read_bytes(), original)
            self.assertEqual(list(source.iterdir()), [dump])

    def test_gzip_validation_reads_bounded_chunks_to_eof(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            dump = self.native_dump(source)
            with gzip.open(dump, "wb") as fixture:
                for _ in range(20):
                    fixture.write(b"x" * 1024 * 1024)
                fixture.write(b"\n-- PostgreSQL database dump complete\n\\unrestrict fixture\n")
            original_read = gzip.GzipFile.read
            reads = []

            def bounded_read(reader, size=-1):
                self.assertGreater(size, 0)
                self.assertLessEqual(size, 1024 * 1024)
                reads.append(size)
                return original_read(reader, size)

            with patch.object(gzip.GzipFile, "read", bounded_read):
                self.assertEqual(module.validate_immich_dump(source), dump)
            self.assertGreater(len(reads), 20)
            self.assertEqual(list(source.iterdir()), [dump])

    def test_latest_corrupt_dump_is_not_replaced_by_older_valid_dump(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "native"
            source.mkdir()
            self.native_dump(source, age=7200)
            latest = self.native_dump(source, age=3600)
            latest.write_bytes(b"not gzip")
            with self.assertRaises((RuntimeError, OSError)):
                module.validate_immich_dump(source)

    def test_both_completion_footers_allow_pg17_unrestrict_trailer(self):
        module = self.module()
        for kind in (b"database", b"database cluster"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                source = Path(directory) / "native"
                source.mkdir()
                dump = self.native_dump(source, footer=b"-- PostgreSQL " + kind + b" dump complete")
                sql = gzip.decompress(dump.read_bytes()) + b"\n\\unrestrict test-only-token\n"
                dump.write_bytes(gzip.compress(sql))
                self.assertEqual(module.validate_immich_dump(source), dump)
                self.assertEqual(gzip.decompress(dump.read_bytes()), sql)

    def test_latest_is_selected_by_mtime_not_timezone_unspecified_filename(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "native"
            source.mkdir()
            old = self.native_dump(source, age=100)
            latest = self.native_dump(source, timestamp=time.time() - 8 * 3600)
            latest.write_bytes(gzip.compress(b"-- newest SQL fixture\n-- PostgreSQL database dump complete\n"))
            now = time.time()
            os.utime(latest, (now, now))
            self.assertNotEqual(old.name, latest.name)
            self.assertEqual(module.validate_immich_dump(source), latest)


if __name__ == "__main__":
    unittest.main()
