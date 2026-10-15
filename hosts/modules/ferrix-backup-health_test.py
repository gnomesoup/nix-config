import importlib.util
import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import MagicMock, patch


class BackupHealthTests(unittest.TestCase):
    def load_module(self):
        path = Path(__file__).with_name("ferrix-backup-health.py")
        self.assertTrue(path.exists(), "Backup freshness monitoring is not implemented")
        spec = importlib.util.spec_from_file_location("backup_health", path)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_freshness_uses_latest_matching_archive_and_rejects_future_dates(self):
        module = self.load_module()
        now = datetime(2026, 10, 14, tzinfo=timezone.utc).timestamp()
        fresh = {"archives": [{"name": "ferrix-20261014", "time": "2026-10-14T00:00:00+00:00"}]}
        self.assertIsNone(module.archive_problem(fresh, now=now))
        stale = {"archives": [{"name": "ferrix-20261010", "time": "2026-10-10T00:00:00+00:00"}]}
        self.assertIn("36 hours", module.archive_problem(stale, now=now))
        self.assertIn("no Ferrix", module.archive_problem({"archives": []}, now=now))
        future = {"archives": [{"name": "ferrix-future", "time": "2026-10-16T00:00:00+00:00"}]}
        self.assertIn("future", module.archive_problem(future, now=now))

    def test_alerts_are_throttled_only_after_successful_email(self):
        module = self.load_module()
        with tempfile.TemporaryDirectory() as directory:
            config = {"state_dir": directory}
            with patch.object(module, "send_email", side_effect=OSError("SMTP unavailable")):
                with self.assertRaises(OSError):
                    module.deliver(config, "hoth", "missing backup", now=100000)
            with patch.object(module, "send_email") as sender:
                module.deliver(config, "hoth", "missing backup", now=100001)
                module.deliver(config, "hoth", "missing backup", now=100002)
                self.assertEqual(sender.call_count, 1)
                module.deliver(config, "hoth", "missing backup", now=200000)
                self.assertEqual(sender.call_count, 2)

    def test_smtp_requires_verified_starttls_and_uses_selected_recipient(self):
        module = self.load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            username = root / "username"
            password = root / "password"
            username.write_text("backup-test@example.invalid\n")
            password.write_text("test-fixture-not-a-real-secret\n")
            config = {
                "smtp_host": "smtp.example.invalid", "smtp_port": 587,
                "username_file": str(username), "password_file": str(password),
                "recipient": "michael@mmjo.com",
            }
            with patch.object(module.smtplib, "SMTP") as smtp:
                client = smtp.return_value.__enter__.return_value
                client.send_message.return_value = {}
                module.send_email(config, "test alert")
                client.starttls.assert_called_once()
                context = client.starttls.call_args.kwargs["context"]
                self.assertTrue(context.check_hostname)
                self.assertEqual(client.send_message.call_args.args[0]["To"], "michael@mmjo.com")

    def test_local_success_is_not_recorded_before_backup_completes(self):
        module = self.load_module()
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            self.assertIn("no successful", module.local_problem(state, "hoth", now=100000))
            module.record_success(state, "hoth", now=100001)
            self.assertIsNone(module.local_problem(state, "hoth", now=100002))
            self.assertIn("36 hours", module.local_problem(state, "hoth", now=300000))

    def test_nonfinite_success_timestamp_is_not_considered_fresh(self):
        module = self.load_module()
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            (state / "hoth.success").write_text("nan\n")
            self.assertIsNotNone(module.local_problem(state, "hoth", now=100000))

    def test_require_fresh_blocks_maintenance_when_repository_is_empty(self):
        module = self.load_module()
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps({"state_dir": directory}))
            result = MagicMock(stdout='{"archives": []}')
            with patch("sys.argv", ["health", "--config", str(config), "require-fresh", "hoth"]):
                with patch.object(module.subprocess, "run", return_value=result):
                    with patch.object(module, "send_email"):
                        with self.assertRaisesRegex(RuntimeError, "no Ferrix"):
                            module.main()


if __name__ == "__main__":
    unittest.main()
