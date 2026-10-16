"""Filesystem-based tests for consistent SQLite snapshots (stdlib only)."""
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest

from unittest import mock

from sqlite_snapshot import snapshot_databases


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "source"
        self.root.mkdir()
        self.destination = Path(self.temp.name) / "snapshot"

    def database(self, path=None):
        path = path or self.root / "state.sqlite"
        connection = sqlite3.connect(path)
        self.addCleanup(connection.close)
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("CREATE TABLE items (value TEXT)")
        connection.execute("INSERT INTO items VALUES ('committed WAL')")
        connection.commit()
        return path, connection

    def test_committed_wal_and_manifest_are_restorable(self):
        path, connection = self.database()
        path.chmod(0o640)
        self.assertTrue(Path(str(path) + "-wal").exists())
        snapshot_databases([self.root], self.destination, reserve_bytes=0)
        target = self.destination / path.relative_to(path.anchor)
        with closing(sqlite3.connect(target)) as restored:
            self.assertEqual(restored.execute("SELECT value FROM items").fetchall(), [("committed WAL",)])
            self.assertEqual(restored.execute("PRAGMA quick_check").fetchall(), [("ok",)])
        self.assertEqual(json.loads((self.destination / "manifest.json").read_text()), [{
            "path": str(path), "uid": os.getuid(), "gid": os.getgid(), "mode": 0o640,
        }])
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)

    def test_exclusions_and_symlinked_directories_are_not_traversed(self):
        self.database()
        for name in ("cache", "node_modules", "configured"):
            folder = self.root / name
            folder.mkdir()
            (folder / "broken.db").write_text("not a database")
        outside = self.root.parent / "outside"
        outside.mkdir()
        (outside / "bad.db").write_text("not a database")
        (self.root / "link").symlink_to(outside, target_is_directory=True)
        snapshot_databases([self.root], self.destination, reserve_bytes=0,
                           excluded_directories=[self.root / "configured"])
        self.assertEqual(len(json.loads((self.destination / "manifest.json").read_text())), 1)

    def test_failed_snapshot_preserves_previous_generation_and_cleans_partial(self):
        self.database()
        snapshot_databases([self.root], self.destination, reserve_bytes=0)
        original = (self.destination / "manifest.json").read_bytes()
        (self.root / "bad.db").write_text("not sqlite")
        with self.assertRaises(sqlite3.DatabaseError):
            snapshot_databases([self.root], self.destination, reserve_bytes=0)
        self.assertEqual((self.destination / "manifest.json").read_bytes(), original)
        self.assertFalse(self.destination.with_name("snapshot.partial").exists())

    def test_missing_root_and_symlink_database_fail_closed(self):
        with self.assertRaises(FileNotFoundError):
            snapshot_databases([self.root / "missing"], self.destination, reserve_bytes=0)
        path, _ = self.database()
        (self.root / "link.db").symlink_to(path)
        with self.assertRaises(ValueError):
            snapshot_databases([self.root], self.destination, reserve_bytes=0)

    def test_free_space_reserve_is_enforced(self):
        self.database()
        with self.assertRaisesRegex(RuntimeError, "space"):
            snapshot_databases([self.root], self.destination, reserve_bytes=10**30)
        self.assertFalse(self.destination.exists())

    def test_walk_errors_are_not_silent(self):
        def denied(*args, **kwargs):
            kwargs["onerror"](PermissionError("denied"))
            return iter(())
        with mock.patch("sqlite_snapshot.os.walk", side_effect=denied):
            with self.assertRaises(PermissionError):
                snapshot_databases([self.root], self.destination, reserve_bytes=0)

    def test_per_database_deadline_is_enforced(self):
        self.database()
        with self.assertRaises(TimeoutError):
            snapshot_databases([self.root], self.destination, reserve_bytes=0, database_timeout_seconds=0)


if __name__ == "__main__":
    unittest.main()
