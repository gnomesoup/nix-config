import importlib.util
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path
from contextlib import closing
from unittest.mock import patch


class BackupStateTests(unittest.TestCase):
    def load_module(self):
        path = Path(__file__).with_name("backup-state.py")
        self.assertTrue(path.exists(), "Consistent backup snapshots are not implemented")
        spec = importlib.util.spec_from_file_location("backup_state", path)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_snapshot_includes_uncheckpointed_wal_transactions(self):
        module = self.load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            database = source / "state.db"
            connection = sqlite3.connect(database)
            self.addCleanup(connection.close)
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA wal_autocheckpoint=0")
            connection.execute("CREATE TABLE messages (body TEXT)")
            connection.execute("INSERT INTO messages VALUES ('durable conversation')")
            connection.commit()
            destination = root / "snapshots"
            module.snapshot_databases([source], destination, reserve_bytes=0)
            snapshot = destination / database.relative_to(database.anchor)
            with closing(sqlite3.connect(snapshot)) as restored:
                self.assertEqual(
                    restored.execute("SELECT body FROM messages").fetchall(),
                    [("durable conversation",)],
                )
                self.assertEqual(restored.execute("PRAGMA quick_check").fetchone(), ("ok",))

    def test_refuses_snapshot_when_disk_reserve_would_be_consumed(self):
        module = self.load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            with closing(sqlite3.connect(source / "state.db")) as database:
                database.execute("CREATE TABLE messages (body TEXT)")
            usage = shutil_usage(total=100, used=99, free=1)
            with patch.object(module.shutil, "disk_usage", return_value=usage):
                with self.assertRaisesRegex(RuntimeError, "space"):
                    module.snapshot_databases([source], root / "snapshots")
            self.assertFalse((root / "snapshots").exists())

    def test_replaces_previous_snapshot_without_retaining_deleted_databases(self):
        module = self.load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            database = source / "old.db"
            with closing(sqlite3.connect(database)) as connection:
                connection.execute("CREATE TABLE entries (id INTEGER)")
            destination = root / "snapshots"
            module.snapshot_databases([source], destination, reserve_bytes=0)
            database.unlink()
            module.snapshot_databases([source], destination, reserve_bytes=0)
            self.assertFalse(any(destination.rglob("*.db")))

    def test_refuses_symlinked_database(self):
        module = self.load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            with closing(sqlite3.connect(root / "outside.db")) as database:
                database.execute("CREATE TABLE entries (id INTEGER)")
            (source / "linked.db").symlink_to(root / "outside.db")
            with self.assertRaisesRegex(ValueError, "symlink"):
                module.snapshot_databases([source], root / "snapshots", reserve_bytes=0)

    def test_missing_root_and_corrupt_database_fail_without_publishing(self):
        module = self.load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "snapshots"
            with self.assertRaises(FileNotFoundError):
                module.snapshot_databases([root / "missing"], destination, reserve_bytes=0)
            source = root / "source"
            source.mkdir()
            (source / "broken.db").write_text("not a SQLite database")
            with self.assertRaises(sqlite3.DatabaseError):
                module.snapshot_databases([source], destination, reserve_bytes=0)
            self.assertFalse(destination.exists())
            self.assertFalse(destination.with_name("snapshots.partial").exists())

    def test_excluded_cache_database_is_not_opened(self):
        module = self.load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            cache = source / "cache"
            cache.mkdir(parents=True)
            (cache / "broken.db").write_text("disposable cache")
            module.snapshot_databases(
                [source], root / "snapshots", reserve_bytes=0, excluded_directories=[cache]
            )
            self.assertFalse(any((root / "snapshots").rglob("*.db")))

    def test_zulip_exports_only_a_new_validated_dump(self):
        module = self.load_module()
        self.assertTrue(hasattr(module, "prepare_zulip"), "Zulip application export is missing")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "data"
            backups = data / "backups"
            backups.mkdir(parents=True)
            old = backups / "backup-old.sql"
            old.write_bytes(b"old fixture")
            dump = backups / "backup-new.sql"
            events = []

            def run(command, **kwargs):
                events.append(command)
                if "inspect" in command:
                    output = str(data) + "\n"
                elif "sha256sum" in command:
                    output = module.ZULIP_ENTRYPOINT_SHA256 + "  /sbin/entrypoint.sh\n"
                elif any("pg_database_size(" in argument for argument in command):
                    output = "1024\n"
                else:
                    output = ""
                if command[-1] == "app:backup":
                    dump.write_bytes(b"PGDMP unit-test fixture")
                return subprocess.CompletedProcess(command, 0, stdout=output)

            with patch.object(module.subprocess, "run", side_effect=run):
                module.prepare_zulip(["docker", "compose"], data, root / "export", reserve_bytes=0)
            self.assertEqual((root / "export/database.dump").read_bytes(), b"PGDMP unit-test fixture")
            self.assertTrue(old.exists())
            self.assertFalse(dump.exists())
            self.assertTrue(any("pg_restore" in event and "--list" in event for event in events))

    @unittest.skipUnless(shutil.which("borg"), "Borg is supplied by the Nix check")
    def test_encrypted_borg_roundtrip_restores_snapshot_not_live_database(self):
        module = self.load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "var/lib/inigo/.hermes"
            source.mkdir(parents=True)
            database = source / "state.db"
            connection = sqlite3.connect(database)
            self.addCleanup(connection.close)
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA wal_autocheckpoint=0")
            connection.execute("CREATE TABLE entries (body TEXT)")
            connection.execute("INSERT INTO entries VALUES ('restored through encrypted Borg')")
            connection.commit()
            snapshots = root / "var/lib/ferrix-backup/sqlite"
            module.snapshot_databases([source], snapshots, reserve_bytes=0)
            environment = os.environ | {
                "HOME": str(root / "home"),
                "BORG_PASSPHRASE": "local-integration-test-fixture-only",
                "BORG_REPO": str(root / "repository"),
            }

            def borg(*arguments, cwd=root):
                return subprocess.run(
                    ["borg", *arguments], check=True, env=environment, cwd=cwd,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                ).stdout

            borg("init", "--encryption", "repokey-blake2")
            excludes = json.loads(os.environ.get("FERRIX_TEST_EXCLUDES", json.dumps([
                "sh:var/lib/inigo/.hermes/**/*.db",
                "sh:var/lib/inigo/.hermes/**/*.db-*",
            ])))
            arguments = ["create"]
            for pattern in excludes:
                arguments += ["--exclude", pattern]
            arguments += ["::ferrix-test", "var/lib/inigo", "var/lib/ferrix-backup/sqlite"]
            borg(*arguments)
            archive = borg("list", "--json-lines", "::ferrix-test")
            paths = {json.loads(entry)["path"] for entry in archive.splitlines()}
            self.assertNotIn("var/lib/inigo/.hermes/state.db", paths)
            self.assertNotIn("var/lib/inigo/.hermes/state.db-wal", paths)
            restored = root / "restore"
            restored.mkdir()
            borg("extract", "::ferrix-test", cwd=restored)
            restored_database = restored / snapshots.relative_to(root) / database.relative_to(database.anchor)
            with closing(sqlite3.connect(restored_database)) as result:
                self.assertEqual(result.execute("SELECT body FROM entries").fetchone(),
                                 ("restored through encrypted Borg",))
            borg("check", "--verify-data")


def shutil_usage(**values):
    from collections import namedtuple

    return namedtuple("usage", "total used free")(**values)


if __name__ == "__main__":
    unittest.main()
