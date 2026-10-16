"""Local-only tests: fixture credentials and mocked SMTP/Borg, never live secrets."""
import importlib.util
import contextlib
import io
import json
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch


class HealthTests(unittest.TestCase):
    def load_module(self):
        path = Path(__file__).with_name("health.py")
        self.assertTrue(path.exists(), "Generic backup health helper is not implemented")
        spec = importlib.util.spec_from_file_location("managed_backup_health", path)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def setUp(self):
        self.health = self.load_module()
        self.now = datetime(2026, 10, 16, tzinfo=timezone.utc).timestamp()
        self.config = {"source_id": "ferrix", "repository_id": "hoth",
                       "archive_prefix": "ferrix-complete-", "max_age_seconds": 129600}

    def test_repository_only_accepts_completed_source_namespace(self):
        for name in ("ferrix-failed-create", "ferrix-incomplete-20261016",
                     "hoth-complete-20261016", "ferrix-complete-a.checkpoint",
                     "ferrix-complete-a.checkpoint.1", "ferrix-complete-"):
            with self.subTest(name=name):
                repository = {"archives": [{"name": name, "time": "2026-10-16T00:00:00Z"}]}
                self.assertIsNotNone(self.health.archive_problem(self.config, repository, self.now))
        repository = {"archives": [{"name": "ferrix-complete-20261016", "time": "2026-10-16T00:00:00Z"}]}
        self.assertIsNone(self.health.archive_problem(self.config, repository, self.now))

    def test_repository_rejects_invalid_missing_nonfinite_and_future_times(self):
        for stamp in (None, "invalid", float("nan"), float("inf"), "2026-10-16T00:10:01Z"):
            with self.subTest(stamp=stamp):
                archive = {"name": "ferrix-complete-a", "time": stamp}
                self.assertIsNotNone(self.health.archive_problem(self.config, {"archives": [archive]}, self.now))
        self.assertIsNotNone(self.health.archive_problem(self.config, {"archives": []}, self.now))
        self.assertIsNotNone(self.health.archive_problem(self.config, {"archives": [{"name": "ferrix-complete-a"}]}, self.now))

    def test_repository_latest_timestamp_timezone_naive_and_age_boundary(self):
        fresh = {"name": "ferrix-complete-new", "time": "2026-10-16T02:00:00+02:00"}
        old = {"name": "ferrix-complete-old", "time": "2026-10-14T00:00:00Z"}
        self.assertIsNone(self.health.archive_problem(self.config, {"archives": [fresh, old]}, self.now))
        self.assertIsNotNone(self.health.archive_problem(self.config, {"archives": [old]}, self.now))
        for delta, healthy in ((129600, True), (129601, False), (-600, True), (-601, False)):
            stamp = datetime.fromtimestamp(self.now - delta, timezone.utc).isoformat()
            archive = {"name": "ferrix-complete-a", "time": stamp}
            problem = self.health.archive_problem(self.config, {"archives": [archive]}, self.now)
            self.assertEqual(problem is None, healthy)
        naive = datetime.fromtimestamp(self.now).isoformat()
        self.assertIsNone(self.health.archive_problem(self.config, {"archives": [{"name": "ferrix-complete-a", "time": naive}]}, self.now))

    def test_local_marker_validates_completed_backup_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "success.json"
            config = dict(self.config, status_file=str(marker))
            self.assertIsNotNone(self.health.local_problem(config, self.now))
            good = {"source": "ferrix", "job": "ferrix-to-hoth", "repository": "hoth",
                    "archive": "ferrix-complete-a", "completed_at": "2026-10-16T00:00:00Z"}
            marker.write_text(json.dumps(good))
            self.assertIsNone(self.health.local_problem(config, self.now))
            for key, value in (("source", "hoth"), ("repository", "cloud"),
                               ("archive", "ferrix-incomplete-a"), ("archive", "ferrix-complete-a.checkpoint"),
                               ("job", ""), ("completed_at", "invalid"), ("completed_at", float("nan")),
                               ("completed_at", self.now + 601), ("completed_at", self.now - 129601)):
                with self.subTest(key=key, value=value):
                    marker.write_text(json.dumps(dict(good, **{key: value})))
                    self.assertIsNotNone(self.health.local_problem(config, self.now))
            marker.write_text(json.dumps(dict(good, completed_at=self.now)))
            self.assertIsNone(self.health.local_problem(config, self.now))
            for contents in ("{", "[]", "null", "{}", json.dumps({k: v for k, v in good.items() if k != "archive"})):
                marker.write_text(contents)
                self.assertIsNotNone(self.health.local_problem(config, self.now))
            marker.write_text(json.dumps(good))
            optional = {k: v for k, v in config.items() if k not in ("source_id", "repository_id")}
            self.assertIsNone(self.health.local_problem(optional, self.now))

    def test_verified_starttls_authentication_and_recipient_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            username, password = Path(directory) / "user", Path(directory) / "pass"
            username.write_text("fixture@example.invalid\r\n")
            password.write_text(" fixture-password \r\n")
            smtp_config = {"host": "smtp.example.invalid", "port": 587,
                           "username_file": str(username), "password_file": str(password),
                           "recipient": "michael@mmjo.com"}
            with patch.object(self.health.smtplib, "SMTP") as smtp:
                client = smtp.return_value.__enter__.return_value
                client.send_message.return_value = {}
                self.health.send_email(smtp_config, "Generic backup problem")
                smtp.assert_called_once_with("smtp.example.invalid", 587, timeout=30)
                self.assertEqual(client.ehlo.call_count, 2)
                context = client.starttls.call_args.kwargs["context"]
                self.assertTrue(context.check_hostname)
                self.assertEqual(context.verify_mode, self.health.ssl.CERT_REQUIRED)
                client.login.assert_called_once_with("fixture@example.invalid", " fixture-password ")
                mail = client.send_message.call_args.args[0]
                self.assertEqual(mail["To"], "michael@mmjo.com")
                self.assertNotIn("fixture-password", mail.as_string())
                names = [call[0] for call in client.method_calls]
                self.assertEqual(names, ["ehlo", "starttls", "ehlo", "login", "send_message"])
                client.send_message.return_value = {"michael@mmjo.com": (550, b"Rejected")}
                with self.assertRaisesRegex(RuntimeError, "rejected"):
                    self.health.send_email(smtp_config, "Generic backup problem")

    def test_alert_throttle_is_written_only_after_accepted_delivery(self):
        with tempfile.TemporaryDirectory() as directory:
            config = dict(self.config, alert_directory=directory, smtp={})
            with patch.object(self.health, "send_email", side_effect=OSError("fixture transport failure")):
                with self.assertRaises(OSError):
                    self.health.deliver(config, "repository", "stale", now=self.now)
            self.assertEqual(list(Path(directory).glob("*.alert")), [])
            with patch.object(self.health, "send_email") as sender:
                self.health.deliver(config, "repository", "stale", now=self.now)
                self.health.deliver(config, "repository", "stale", now=self.now + 86399)
                self.assertEqual(sender.call_count, 1)
                stamp = self.health.alert_path(config, "repository")
                self.assertEqual(stamp.stat().st_mode & 0o777, 0o600)
                self.health.deliver(config, "repository", "stale", now=self.now + 86400)
                self.assertEqual(sender.call_count, 2)
                self.health.deliver(config, "repository", "test", now=self.now + 86401, force=True)
                self.assertEqual(sender.call_count, 3)
                stamp.write_text("nan")
                self.health.deliver(config, "repository", "stale", now=self.now + 86402)
                self.assertEqual(sender.call_count, 4)

    def test_alert_names_are_safe_and_scoped_to_source_repository_and_host(self):
        with tempfile.TemporaryDirectory() as directory:
            config = dict(self.config, alert_directory=directory)
            path = self.health.alert_path(config, "../../unit/unsafe")
            self.assertEqual(path.parent, Path(directory))
            self.assertNotIn("..", path.name)
            for setting, other in (("source_id", "hoth"), ("repository_id", "cloud")):
                self.assertNotEqual(path, self.health.alert_path(dict(config, **{setting: other}), "../../unit/unsafe"))
            with patch.object(self.health.socket, "gethostname", return_value="other-host"):
                self.assertNotEqual(path, self.health.alert_path(config, "../../unit/unsafe"))

    def run_main(self, config, action, identifier="hoth"):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(config))
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as errors:
                result = self.health.main(["--config", str(path), action, identifier])
            return result, errors.getvalue()

    def test_cli_repository_filters_borg_bounds_timeout_and_resets_shared_throttle(self):
        with tempfile.TemporaryDirectory() as directory:
            config = dict(self.config, borg_command=["/fixture/borg-wrapper"], alert_directory=directory, smtp={})
            with patch.object(self.health.subprocess, "run") as borg, patch.object(self.health, "send_email") as sender:
                borg.return_value.stdout = '{"archives": []}'
                self.assertEqual(self.run_main(config, "check-repository")[0], 0)
                self.assertEqual(sender.call_count, 1)
                call = borg.call_args
                self.assertEqual(call.args[0], ["/fixture/borg-wrapper", "list", "--json", "--glob-archives", "ferrix-complete-*", "--last", "1"])
                self.assertEqual(call.kwargs["timeout"], 900)
                self.assertTrue(call.kwargs["check"])
                self.assertEqual(self.run_main(config, "require-fresh")[0], 1)
                self.assertEqual(sender.call_count, 1, "require-fresh must share repository throttle but still fail")
                fresh = {"archives": [{"name": "ferrix-complete-a", "time": "2026-10-16T00:00:00Z"}]}
                borg.return_value.stdout = json.dumps(fresh)
                with patch.object(self.health.time, "time", return_value=self.now):
                    self.assertEqual(self.run_main(config, "require-fresh")[0], 0)
                self.assertEqual(list(Path(directory).glob("*.alert")), [])
                borg.return_value.stdout = '{"archives": []}'
                self.assertEqual(self.run_main(config, "check-repository")[0], 0)
                self.assertEqual(sender.call_count, 2)

    def test_cli_require_fresh_fails_for_stale_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            config = dict(self.config, borg_command=["/fixture/borg"], alert_directory=directory, smtp={})
            with patch.object(self.health.subprocess, "run") as borg, patch.object(self.health, "send_email"):
                borg.return_value.stdout = '{"archives": [{"name": "ferrix-complete-old", "time": "2020-01-01T00:00:00Z"}]}'
                self.assertEqual(self.run_main(config, "require-fresh")[0], 1)

    def test_cli_local_check_alerts_and_recovers_without_running_borg(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "marker.json"
            config = dict(self.config, status_file=str(marker), alert_directory=directory, smtp={})
            with patch.object(self.health.subprocess, "run") as borg, patch.object(self.health, "send_email") as sender:
                self.assertEqual(self.run_main(config, "check-local")[0], 0)
                self.assertEqual(sender.call_count, 1)
                marker.write_text(json.dumps({"source": "ferrix", "repository": "hoth", "job": "backup",
                                             "archive": "ferrix-complete-a", "completed_at": self.now}))
                with patch.object(self.health.time, "time", return_value=self.now):
                    self.assertEqual(self.run_main(config, "check-local")[0], 0)
                self.assertEqual(list(Path(directory).glob("*.alert")), [])
                borg.assert_not_called()

    def test_cli_generic_failed_and_explicit_test_need_only_notifier_config(self):
        with tempfile.TemporaryDirectory() as directory:
            config = {"alert_directory": directory, "smtp": {}}
            with patch.object(self.health, "send_email") as sender, patch.object(self.health.subprocess, "run") as borg:
                self.assertEqual(self.run_main(config, "failed", "backup-unit.service")[0], 0)
                message = sender.call_args.args[1]
                self.assertIn("backup-unit.service", message)
                self.assertIn("failed", message)
                self.assertNotIn("journalctl", message)
                self.assertEqual(self.run_main(config, "failed", "backup-unit.service")[0], 0)
                self.assertEqual(sender.call_count, 1)
                self.assertEqual(self.run_main(config, "test")[0], 0)
                self.assertEqual(self.run_main(config, "test")[0], 0)
                self.assertEqual(sender.call_count, 3)
                borg.assert_not_called()

    def test_cli_transport_error_is_nonzero_and_does_not_leak_exception_details(self):
        with tempfile.TemporaryDirectory() as directory:
            config = {"alert_directory": directory, "smtp": {}}
            with patch.object(self.health, "send_email", side_effect=OSError("sensitive fixture")):
                code, error = self.run_main(config, "failed")
                self.assertEqual(code, 1)
                self.assertIn("delivery", error.lower())
                self.assertNotIn("sensitive fixture", error)
                self.assertEqual(list(Path(directory).glob("*.alert")), [])

    def test_cli_repository_errors_are_nonzero_without_output_or_credential_leaks(self):
        with tempfile.TemporaryDirectory() as directory:
            config = dict(self.config, borg_command=["/fixture/borg"], alert_directory=directory, smtp={})
            for problem in (self.health.subprocess.CalledProcessError(2, ["sensitive-command"], output="sensitive-output", stderr="sensitive-stderr"),
                            self.health.subprocess.TimeoutExpired(["sensitive-command"], 900), OSError("sensitive-path")):
                with self.subTest(problem=type(problem).__name__), patch.object(self.health.subprocess, "run", side_effect=problem), patch.object(self.health, "send_email") as sender:
                    code, error = self.run_main(config, "require-fresh")
                    self.assertEqual(code, 1)
                    self.assertIn("Borg", error)
                    self.assertNotIn("sensitive", error)
                    sender.assert_not_called()
            for output in ("not-json", "[]", "null", '{}', '{"archives": [null]}'):
                with self.subTest(output=output), patch.object(self.health.subprocess, "run") as borg:
                    borg.return_value.stdout = output
                    self.assertEqual(self.run_main(config, "require-fresh")[0], 1)

    def test_cli_rejects_unsafe_archive_prefix_before_running_borg(self):
        with tempfile.TemporaryDirectory() as directory:
            config = dict(self.config, borg_command=["/fixture/borg"], alert_directory=directory, smtp={})
            for prefix in ("ferrix-", "hoth-complete-", "*-complete-", ""):
                with self.subTest(prefix=prefix), patch.object(self.health.subprocess, "run") as borg:
                    self.assertEqual(self.run_main(dict(config, archive_prefix=prefix), "check-repository")[0], 1)
                    borg.assert_not_called()

    def test_local_marker_optional_namespace_config_and_oversized_timestamp(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "marker.json"
            config: dict = {"status_file": str(marker)}
            good = {"source": "ferrix", "repository": "hoth", "job": "backup",
                    "archive": "ferrix-complete-a", "completed_at": self.now}
            marker.write_text(json.dumps(good))
            self.assertIsNone(self.health.local_problem(config, self.now))
            marker.write_text(json.dumps(dict(good, archive="hoth-complete-a")))
            self.assertIsNotNone(self.health.local_problem(config, self.now))
            marker.write_text(json.dumps(dict(good, completed_at=10 ** 1000)))
            self.assertIsNotNone(self.health.local_problem(config, self.now))
            config.update({"alert_directory": directory, "smtp": {}})
            marker.write_text(json.dumps(good))
            with patch.object(self.health.time, "time", return_value=self.now), patch.object(self.health, "send_email") as sender:
                self.assertEqual(self.run_main(config, "check-local")[0], 0)
                sender.assert_not_called()

    def test_parallel_checks_share_one_accepted_delivery(self):
        with tempfile.TemporaryDirectory() as directory:
            config = dict(self.config, alert_directory=directory, smtp={})
            with patch.object(self.health, "send_email") as sender, ThreadPoolExecutor(max_workers=4) as pool:
                futures = [pool.submit(self.health.deliver, config, "repository", "stale", self.now) for _ in range(8)]
                for future in futures:
                    future.result(timeout=10)
                self.assertEqual(sender.call_count, 1)

    def test_real_cli_entrypoint_runs_fixture_borg_without_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            borg = root / "borg.py"
            borg.write_text(
                "import datetime, json, sys\n"
                "assert sys.argv[1:] == ['list', '--json', '--glob-archives', 'ferrix-complete-*', '--last', '1']\n"
                "print(json.dumps({'archives': [{'name': 'ferrix-complete-fixture', "
                "'time': datetime.datetime.now(datetime.timezone.utc).isoformat()}]}))\n"
            )
            config = dict(self.config, alert_directory=str(root / "alerts"),
                          borg_command=[sys.executable, str(borg)], smtp={})
            config_path = root / "config.json"
            config_path.write_text(json.dumps(config))
            result = self.health.subprocess.run(
                [sys.executable, str(Path(__file__).with_name("health.py")), "--config", str(config_path), "require-fresh"],
                capture_output=True, text=True, timeout=10, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertFalse((root / "alerts").exists())


if __name__ == "__main__":
    unittest.main()
