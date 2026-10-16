"""Runtime tests; real Borg integration requires borg and borgmatic on PATH."""
from contextlib import closing, redirect_stdout, redirect_stderr
import io
import fcntl
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from typing import Any

import runner


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "source"
        self.source.mkdir()
        self.state = self.base / "state"
        self.stage = self.state / "jobs" / "source-local" / "staging"
        self.config: dict[str, Any] = dict(
            job_id="source-local", source_id="source", repository_id="local",
            borg_command=["borg-wrapper"], borgmatic_command=["borgmatic"],
            borgmatic_config=str(self.base / "borgmatic.yaml"),
            state_directory=str(self.state), staging_directory=str(self.stage),
            required_directories=[str(self.source)], required_mounts=[],
            preparation_command=[], sqlite_roots=[], sqlite_excluded_directories=[],
            required_sqlite_files=[], timeout_seconds=30,
            preparation_lock_wait_seconds=1, ssh_hostname=None,
            ssh_known_hosts_file=None, expected_repository_id=None,
        )
        self.calls = []

    @property
    def status(self):
        return self.state / "status" / "source-local.json"

    def command(self, args, deadline, env=None):
        self.calls.append((args, env))
        return ""



class RuntimeTests(Fixture):
    def test_cli_reports_static_stage_and_exit_status_without_child_output(self):
        config_file = self.base / "runtime.json"
        config_file.write_text(json.dumps(self.config))
        original = runner.run_command

        def command(args, deadline, env=None):
            if "create" in args:
                return original([sys.executable, "-c",
                    "import sys; print('TEST_SECRET_OUTPUT'); sys.exit(23)"], deadline)
            return ""

        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", ["runner", "--config", str(config_file)]), \
                mock.patch.object(runner, "run_command", side_effect=command), \
                redirect_stdout(output), redirect_stderr(errors):
            self.assertEqual(runner.main(), 1)
        self.assertIn("stage: create", output.getvalue())
        self.assertIn("exit status 23", errors.getvalue())
        self.assertNotIn("TEST_SECRET_OUTPUT", output.getvalue() + errors.getvalue())

    def test_success_promotes_unique_pending_archive_then_records_status(self):
        with mock.patch.object(runner, "run_command", side_effect=self.command):
            runner.run_job(self.config)
        self.assertTrue((self.stage / "sqlite" / "manifest.json").is_file())
        self.assertTrue((self.stage / "exports").is_dir())
        create = self.calls[0][0]
        self.assertEqual(create[:3], ["borgmatic", "--config", self.config["borgmatic_config"]])
        pending = next(arg.split("=", 1)[1] for arg in create if arg.startswith("archive_name_format="))
        self.assertTrue(pending.startswith("incomplete-source-"))
        self.assertEqual(create[-1], "create")
        rename = self.calls[1][0]
        self.assertEqual(rename[:3], ["borg-wrapper", "rename", "::" + pending])
        self.assertTrue(rename[3].startswith("source-complete-"))
        status = json.loads(self.status.read_text())
        self.assertEqual({key: status[key] for key in ("source", "job", "repository", "archive")},
                         dict(source="source", job="source-local", repository="local", archive=rename[3]))
        self.assertLess(abs(status["completed_at"] - time.time()), 5)
        self.assertEqual(self.status.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.stage.stat().st_mode & 0o777, 0o700)

    def test_required_inputs_and_mount_identity_fail_before_any_archive(self):
        cases = [
            {"required_directories": [str(self.source / "missing")]},
            {"required_sqlite_files": [str(self.source / "missing.db")]},
            {"required_mounts": [{"path": str(self.source), "uuid": "expected"}]},
            {"ssh_hostname": "remote.example", "ssh_known_hosts_file": str(self.base / "missing-hosts")},
        ]
        for changed in cases:
            with self.subTest(changed=changed):
                self.calls.clear()
                with mock.patch.object(runner, "run_command", side_effect=self.command):
                    with self.assertRaises((ValueError, RuntimeError, FileNotFoundError)):
                        runner.run_job(self.config | changed)
                self.assertFalse(self.status.exists())
                self.assertFalse(any("create" in args for args, env in self.calls))

    def test_repository_id_mismatch_prevents_create(self):
        def output(args, deadline, env=None):
            self.calls.append((args, env))
            return json.dumps({"repository": {"id": "wrong"}})
        with mock.patch.object(runner, "run_command", side_effect=output):
            with self.assertRaisesRegex(RuntimeError, "identity"):
                runner.run_job(self.config | {"expected_repository_id": "expected"})
        self.assertEqual(self.calls[0][0], ["borg-wrapper", "info", "--json"])
        self.assertFalse(self.status.exists())

    def test_preparation_rebuilds_stale_stage_and_receives_environment(self):
        self.stage.mkdir(parents=True)
        (self.stage / "stale").write_text("must not upload")
        def output(args, deadline, env=None):
            self.calls.append((args, env))
            if args == ["prepare"]:
                self.assertFalse((self.stage / "stale").exists())
                self.assertEqual(env["BACKUP_STAGING_DIRECTORY"], str(self.stage))
                (self.stage / "exports" / "dump").write_text("fresh")
            return ""
        with mock.patch.object(runner, "run_command", side_effect=output):
            runner.run_job(self.config | {"preparation_command": ["prepare"]})
        self.assertEqual(self.calls[0][0], ["prepare"])
        self.assertEqual((self.stage / "exports" / "dump").read_text(), "fresh")

    def test_required_sqlite_must_be_exported_not_merely_exist(self):
        database = self.source / "state.db"
        with closing(sqlite3.connect(database)) as db:
            db.execute("CREATE TABLE items (value)")
        with mock.patch.object(runner, "run_command", side_effect=self.command):
            with self.assertRaisesRegex(RuntimeError, "SQLite"):
                runner.run_job(self.config | {"required_sqlite_files": [str(database)]})
        self.assertFalse(self.status.exists())

    def test_job_identifier_cannot_escape_state_directory(self):
        with self.assertRaises(ValueError):
            runner.run_job(self.config | {"job_id": "../escape"})

    def test_job_lock_covers_preparation_upload_and_promotion_but_shared_lock_does_not(self):
        locks = self.state / "locks"
        def is_locked(path):
            with path.open("a") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    return False
                except BlockingIOError:
                    return True
        def output(args, deadline, env=None):
            self.assertTrue(is_locked(locks / "source-local.lock"))
            self.assertEqual(is_locked(locks / "preparation.lock"), args == ["prepare"])
            return ""
        with mock.patch.object(runner, "run_command", side_effect=output):
            runner.run_job(self.config | {"preparation_command": ["prepare"]})
        self.assertFalse(is_locked(locks / "source-local.lock"))
        self.assertFalse(is_locked(locks / "preparation.lock"))

    def test_lock_contention_is_bounded_and_never_discards_locked_staging(self):
        locks = self.state / "locks"
        locks.mkdir(parents=True)
        self.stage.mkdir(parents=True)
        sentinel = self.stage / "owned-by-another-run"
        sentinel.touch()
        for name in ("source-local.lock", "preparation.lock"):
            with self.subTest(lock=name), (locks / name).open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                start = time.monotonic()
                with mock.patch.object(runner, "run_command", side_effect=self.command):
                    with self.assertRaises(TimeoutError):
                        runner.run_job(self.config | {"timeout_seconds": 0.08,
                                       "preparation_lock_wait_seconds": 0.04})
                self.assertLess(time.monotonic() - start, 1)
                self.assertTrue(sentinel.exists())
        self.assertFalse(self.status.exists())

    def test_staging_cannot_be_a_symlink_or_cover_source(self):
        self.stage.parent.mkdir(parents=True)
        self.stage.symlink_to(self.source, target_is_directory=True)
        (self.source / "valuable").write_text("keep")
        for path in (self.stage, self.source, self.state, Path("/")):
            with self.subTest(path=path), mock.patch.object(runner.shutil, "rmtree", side_effect=AssertionError("unsafe deletion")), self.assertRaises(ValueError):
                runner.run_job(self.config | {"staging_directory": str(path)})
        self.assertEqual((self.source / "valuable").read_text(), "keep")

    def test_stale_status_temporary_does_not_weaken_success_permissions(self):
        self.status.parent.mkdir(parents=True)
        stale = self.status.with_suffix(".json.partial")
        stale.write_text("interrupted")
        stale.chmod(0o644)
        with mock.patch.object(runner, "run_command", side_effect=self.command):
            runner.run_job(self.config)
        self.assertEqual(self.status.stat().st_mode & 0o777, 0o600)

    def test_another_destination_prepares_while_first_upload_is_stalled(self):
        second_stage = self.state / "jobs" / "source-other" / "staging"
        second = self.config | {"job_id": "source-other", "repository_id": "other",
                               "staging_directory": str(second_stage),
                               "preparation_command": ["second-prepare"]}
        events = []
        def output(args, deadline, env=None):
            events.append(args)
            if args[0] == "borgmatic" and not second_stage.exists():
                runner.run_job(second)
                self.assertTrue((self.state / "status" / "source-other.json").exists())
            return ""
        with mock.patch.object(runner, "run_command", side_effect=output):
            runner.run_job(self.config)
        self.assertIn(["second-prepare"], events)
        self.assertTrue(self.status.exists())

    def test_failed_preparation_create_or_promotion_preserves_prior_success(self):
        self.status.parent.mkdir(parents=True)
        previous = b'{"archive":"previous-success"}\n'
        self.status.write_bytes(previous)
        for failing in ("prepare", "borgmatic", "borg-wrapper"):
            with self.subTest(stage=failing):
                calls = []
                def output(args, deadline, env=None):
                    calls.append(args)
                    if args[0] == failing:
                        raise RuntimeError("fixture failure")
                    return ""
                with mock.patch.object(runner, "run_command", side_effect=output):
                    with self.assertRaises(RuntimeError):
                        runner.run_job(self.config | {"preparation_command": ["prepare"]})
                self.assertEqual(self.status.read_bytes(), previous)
                if failing != "borg-wrapper":
                    self.assertFalse(any(args[0] == "borg-wrapper" for args in calls))

    def test_exact_mount_and_repository_identity_and_host_key_allow_create(self):
        known_hosts = self.base / "known_hosts"
        known_hosts.write_text("public fixture")
        def output(args, deadline, env=None):
            self.calls.append((args, env))
            if args[0] == "findmnt":
                return "fixture-uuid\n"
            if args[0] == "ssh-keygen":
                return "fixture key\n"
            if "info" in args:
                return json.dumps({"repository": {"id": "fixture-id"}})
            return ""
        with mock.patch.object(runner, "run_command", side_effect=output):
            runner.run_job(self.config | {"required_mounts": [{"path": str(self.source), "uuid": "fixture-uuid"}],
                "expected_repository_id": "fixture-id", "ssh_hostname": "fixture.example",
                "ssh_known_hosts_file": str(known_hosts)})
        self.assertEqual(self.calls[0][0], ["findmnt", "--noheadings", "--output", "UUID", "--mountpoint", str(self.source)])
        self.assertEqual(self.calls[1][0], ["ssh-keygen", "-F", "fixture.example", "-f", str(known_hosts)])
        self.assertTrue(self.status.exists())

    def test_mount_substrings_are_not_accepted(self):
        with mock.patch.object(runner, "run_command", return_value="prefix-fixture-uuid-suffix\n"):
            with self.assertRaisesRegex(RuntimeError, "mount identity"):
                runner.run_job(self.config | {"required_mounts": [{"path": str(self.source), "uuid": "fixture-uuid"}]})
        self.assertFalse(self.status.exists())

    def test_expired_subprocess_deadline_never_starts_command(self):
        sentinel = self.base / "started"
        with self.assertRaises(TimeoutError):
            runner.run_command([sys.executable, "-c", f"from pathlib import Path; Path({str(sentinel)!r}).touch()"],
                               time.monotonic() - 1)
        self.assertFalse(sentinel.exists())

    def test_timeout_kills_descendant_even_when_it_ignores_termination(self):
        pid_file = self.base / "child.pid"
        child = "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(5)"
        parent = ("import subprocess,sys,time; from pathlib import Path; "
                  f"p=subprocess.Popen([sys.executable,'-c',{child!r}]); "
                  f"Path({str(pid_file)!r}).write_text(str(p.pid)); time.sleep(5)")
        start = time.monotonic()
        try:
            with self.assertRaises(TimeoutError):
                runner.run_command([sys.executable, "-c", parent], time.monotonic() + 0.3)
            self.assertLess(time.monotonic() - start, 2)
            pid = int(pid_file.read_text())
            for attempt in range(30):
                stat = Path(f"/proc/{pid}/stat")
                try:
                    state = stat.read_text().split()[2]
                except (FileNotFoundError, ProcessLookupError):
                    # A successfully killed descendant can disappear during read.
                    break
                if state == "Z":
                    break
                time.sleep(0.02)
            else:
                self.fail("subprocess descendant survived timeout")
        finally:
            if pid_file.exists():
                try:
                    os.kill(int(pid_file.read_text()), 9)
                except ProcessLookupError:
                    pass

    def test_nonzero_command_error_does_not_disclose_child_output(self):
        with self.assertRaises(RuntimeError) as failure:
            runner.run_command([sys.executable, "-c",
                "import sys; print('TEST_SECRET'); print('TEST_SECRET',file=sys.stderr); sys.exit(1)"],
                time.monotonic() + 2)
        self.assertNotIn("TEST_SECRET", str(failure.exception))


@unittest.skipUnless(shutil.which("borg") and shutil.which("borgmatic"), "borg and borgmatic required")
class BorgIntegrationTests(Fixture):
    def setUp(self):
        super().setUp()
        self.borg = shutil.which("borg")
        self.borgmatic = shutil.which("borgmatic")
        assert self.borg is not None and self.borgmatic is not None
        self.repo = self.base / "repository"
        env = {key: value for key, value in os.environ.items() if not key.startswith("BORG_")}
        env.update(BORG_REPO=str(self.repo), BORG_PASSPHRASE="local-fixture-only",
                   BORG_BASE_DIR=str(self.base / "borg-home"),
                   BORG_CACHE_DIR=str(self.base / "borg-cache"),
                   BORG_SECURITY_DIR=str(self.base / "borg-security"),
                   BORG_KEYS_DIR=str(self.base / "borg-keys"))
        self.environment = mock.patch.dict(os.environ, env, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.borg_run("init", "--encryption=repokey-blake2")
        self.config.update(borg_command=[self.borg], borgmatic_command=[self.borgmatic])
        self.config_path = self.base / "runtime.json"
        self.yaml = Path(self.config["borgmatic_config"])
        self.yaml.write_text("source_directories:\n" +
            "".join("  - " + json.dumps(str(path)) + "\n" for path in
                    (self.source, self.stage / "sqlite", self.stage / "exports")) +
            "repositories:\n  - path: " + json.dumps(str(self.repo)) + "\n" +
            "local_path: " + json.dumps(self.borg) + "\n" +
            "archive_name_format: unused-{now:%Y-%m-%dT%H:%M:%S}\n" +
            "exclude_patterns:\n  - '*.db'\n  - '*-wal'\n  - '*-shm'\n" +
            "borgmatic_source_directory: " + json.dumps(str(self.base / "borgmatic-state")) + "\n")

    def borg_run(self, *args, cwd=None, check=True):
        return subprocess.run([self.borg, *args], cwd=cwd, check=check,
                              capture_output=True, text=True, timeout=30)

    def run_cli(self):
        self.config_path.write_text(json.dumps(self.config))
        return subprocess.run([sys.executable, str(Path(runner.__file__)), "--config", str(self.config_path)],
                              capture_output=True, text=True, timeout=30)

    def archives(self):
        return json.loads(self.borg_run("list", "--json").stdout)["archives"]

    def test_real_encrypted_borgmatic_cli_roundtrip_includes_wal_snapshot_and_export(self):
        (self.source / "document").write_text("restore me")
        database = self.source / "state.sqlite"
        db = sqlite3.connect(database)
        self.addCleanup(db.close)
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("CREATE TABLE items(value)")
        db.execute("INSERT INTO items VALUES ('committed WAL')")
        db.commit()
        self.config.update(sqlite_roots=[str(self.source)], required_sqlite_files=[str(database)],
            expected_repository_id=json.loads(self.borg_run("info", "--json").stdout)["repository"]["id"],
            preparation_command=[sys.executable, "-c", "import os; from pathlib import Path; "
                "(Path(os.environ['BACKUP_STAGING_DIRECTORY'])/'exports'/'application.dump').write_text('export')"])
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        status = json.loads(self.status.read_text())
        self.assertEqual([archive["name"] for archive in self.archives()], [status["archive"]])
        restored = self.base / "restored"
        restored.mkdir()
        self.borg_run("extract", "::" + status["archive"], cwd=restored)
        def extracted(path):
            return restored / path.relative_to(path.anchor)
        self.assertEqual(extracted(self.source / "document").read_text(), "restore me")
        self.assertEqual(extracted(self.stage / "exports" / "application.dump").read_text(), "export")
        snapshot = self.stage / "sqlite" / database.relative_to(database.anchor)
        with closing(sqlite3.connect(extracted(snapshot))) as recovered:
            self.assertEqual(recovered.execute("SELECT value FROM items").fetchall(), [("committed WAL",)])
            self.assertEqual(recovered.execute("PRAGMA quick_check").fetchall(), [("ok",)])
        self.assertEqual(json.loads(extracted(self.stage / "sqlite" / "manifest.json").read_text())[0]["path"], str(database))
        self.assertEqual(json.loads(self.borg_run("info", "--json").stdout)["encryption"]["mode"], "repokey-blake2")

    def test_real_borg_warning_archive_is_never_promoted_or_marked_success(self):
        # Inject the nonexistent input at the Borg boundary: Borgmatic itself
        # validates configured source paths before it starts Borg.
        wrapper = self.base / "warning-borg"
        exit_status = self.base / "borg-create-status"
        wrapper.write_text(f"#!{sys.executable}\nimport os,sys,subprocess\nfrom pathlib import Path\nargs=sys.argv[1:]\n"
            "if 'create' in args and '--dry-run' not in args:\n"
            f"    args.append({str(self.source / 'missing-input')!r})\n"
            f"    status=subprocess.call([{self.borg!r}] + args)\n"
            f"    Path({str(exit_status)!r}).write_text(str(status))\n"
            "    sys.exit(status)\n"
            f"os.execv({self.borg!r}, [{self.borg!r}] + args)\n")
        wrapper.chmod(0o700)
        self.yaml.write_text(self.yaml.read_text().replace(
            "local_path: " + json.dumps(self.borg), "local_path: " + json.dumps(str(wrapper))))
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(int(exit_status.read_text()), {1, 107})
        archives = self.archives()
        self.assertEqual(len(archives), 1)
        self.assertTrue(archives[0]["name"].startswith("incomplete-source-"))
        self.assertFalse(any(archive["name"].startswith("source-complete-") for archive in archives))
        self.assertFalse(self.status.exists())


if __name__ == "__main__":
    unittest.main()
