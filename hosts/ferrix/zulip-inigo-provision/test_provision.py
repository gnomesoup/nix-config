"""Local tests; Docker is never contacted. Run with python3 -m unittest -v."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

HERE = Path(__file__).resolve().parent


class ProvisionTests(unittest.TestCase):
    def test_help_and_unknown_arguments_never_provision(self):
        for args, status in ((["--help"], 0), (["--rotate"], 2)):
            with self.subTest(args=args):
                result = subprocess.run([sys.executable, str(HERE / "provision.py"), *args],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, status)
                self.assertNotIn("api_key", result.stdout + result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    @unittest.skipUnless(os.environ.get("INIGO_PROVISION_CLI"), "installed-package check")
    @unittest.skipIf(os.geteuid() == 0, "requires an actual unprivileged caller")
    def test_installed_command_is_runnable_and_root_only(self):
        result = subprocess.run([os.environ["INIGO_PROVISION_CLI"]], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "inigo-zulip-provision: must run as root\n")

    @unittest.skipIf(os.geteuid() == 0, "requires an actual unprivileged caller")
    def test_unprivileged_cli_fails_without_output(self):
        result = subprocess.run(
            [sys.executable, str(HERE / "provision.py")], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "inigo-zulip-provision: must run as root\n")


class IdentityTests(unittest.TestCase):
    def identities(self):
        realm = {"string_id": "", "url": "https://chat.mmjo.com", "deactivated": False}
        owner = {"id": 17, "delivery_email": "michael@mmjo.com", "is_active": True,
                 "is_bot": False, "role": 100}
        bot = {"id": 44, "email": "inigo-bot@chat.mmjo.com",
               "delivery_email": "inigo-bot@chat.mmjo.com", "full_name": "Inigo",
               "is_active": True, "is_bot": True, "bot_type": 1,
               "bot_owner_id": 17, "role": 400, "is_staff": False,
               "can_forge_sender": False, "can_create_users": False,
               "can_change_user_emails": False}
        return realm, owner, bot

    def test_wrong_identity_or_privileges_fail_closed(self):
        from policy import decide
        cases = [
            (0, "url", "https://elsewhere.example"), (0, "string_id", "other"),
            (0, "string_id", "mmjo"), (0, "string_id", "zulipinternal"),
            (0, "deactivated", True), (0, "deactivated", 0),
            (1, "is_active", False), (1, "is_bot", True), (1, "role", 600),
            (1, "delivery_email", "other@mmjo.com"), (1, "id", True),
            (2, "is_active", False), (2, "is_bot", False), (2, "bot_type", 2),
            (2, "bot_owner_id", 18), (2, "full_name", "Someone"), (2, "role", 100),
            (2, "email", "other@mmjo.com"), (2, "delivery_email", "other@mmjo.com"),
            (2, "is_staff", True), (2, "can_forge_sender", True),
            (2, "can_create_users", True), (2, "can_change_user_emails", True),
            (2, "bot_type", True), (2, "is_bot", 1), (2, "id", True),
        ]
        for target, name, value in cases:
            with self.subTest(target=target, name=name, value=value):
                values = self.identities()
                values[target][name] = value
                with self.assertRaises(ValueError):
                    decide(*values)

    def test_identity_decides_create_or_reuse_without_mutation(self):
        from policy import decide
        realm, owner, bot = self.identities()
        import copy
        original = copy.deepcopy((realm, owner, bot))
        self.assertEqual(decide(realm, owner, None), "created")
        self.assertEqual(decide(realm, owner, bot), "existing")
        self.assertEqual((realm, owner, bot), original)


class CredentialTests(unittest.TestCase):
    def test_invalid_keys_never_create_files(self):
        import tempfile
        from provision import persist_key

        for invalid in ("", "x" * 31, "x" * 33, "x" * 31 + "\n", "é" * 32, None):
            with self.subTest(invalid=repr(invalid)), tempfile.TemporaryDirectory() as directory:
                Path(directory).chmod(0o700)
                with self.assertRaisesRegex(ValueError, "invalid key"):
                    persist_key(Path(directory), invalid, expected_uid=os.geteuid())
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_existing_credential_without_newline_is_reused(self):
        import tempfile
        from provision import persist_key
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            directory.chmod(0o700)
            path = directory / "api-key"
            path.write_text("a" * 32)
            path.chmod(0o400)
            before = path.stat()
            persist_key(directory, "a" * 32, expected_uid=os.geteuid())
            self.assertEqual(path.read_text(), "a" * 32)
            self.assertEqual(path.stat().st_ino, before.st_ino)

    def test_key_is_private_atomic_and_idempotent(self):
        import tempfile
        from provision import persist_key

        with tempfile.TemporaryDirectory() as directory:
            Path(directory).chmod(0o700)
            path = Path(directory) / "api-key"
            persist_key(Path(directory), "a" * 32, expected_uid=os.geteuid())
            self.assertEqual(path.read_text(), "a" * 32 + "\n")
            self.assertEqual(path.stat().st_mode & 0o777, 0o400)
            self.assertEqual(path.stat().st_uid, os.geteuid())
            before = path.stat()
            persist_key(Path(directory), "a" * 32, expected_uid=os.geteuid())
            self.assertEqual(path.stat().st_ino, before.st_ino)
            self.assertEqual(path.stat().st_mtime_ns, before.st_mtime_ns)
            with self.assertRaisesRegex(ValueError, "credential mismatch"):
                persist_key(Path(directory), "b" * 32, expected_uid=os.geteuid())
            self.assertEqual(path.read_text(), "a" * 32 + "\n")
            self.assertEqual(sorted(p.name for p in Path(directory).iterdir()), ["api-key"])


class DockerBoundaryTests(unittest.TestCase):
    def test_docker_failures_and_untrusted_output_are_redacted(self):
        from unittest.mock import Mock
        from provision import fetch_bot
        secret = "a" * 32
        valid = {"status": "existing", "realm": "", "site": "https://chat.mmjo.com",
                 "bot_email": "inigo-bot@chat.mmjo.com", "user_id": 44,
                 "owner_email": "michael@mmjo.com", "api_key": secret}
        responses = [(1, json.dumps(valid)), (0, "unexpected " + secret),
                     (0, json.dumps({"error": secret})), (0, "[]")]
        for name, bad in (("realm", "other"), ("site", "https://evil.example"),
                          ("bot_email", "someone@example.com"), ("owner_email", "x@example.com"),
                          ("status", secret), ("user_id", True), ("api_key", "invalid")):
            responses.append((0, json.dumps(dict(valid, **{name: bad}))))
        responses.append((0, json.dumps(dict(valid, unexpected_secret=secret))))
        for status, output in responses:
            with self.subTest(status=status, output=output):
                runner = Mock(return_value=subprocess.CompletedProcess([], status, output, secret))
                with self.assertRaises(ValueError) as caught:
                    fetch_bot(runner=runner)
                self.assertNotIn(secret, str(caught.exception))
        for exception in (subprocess.TimeoutExpired(["docker"], 180, output=secret),
                          OSError(secret)):
            with self.subTest(exception=type(exception).__name__):
                with self.assertRaises(ValueError) as caught:
                    fetch_bot(runner=Mock(side_effect=exception))
                self.assertNotIn(secret, str(caught.exception))

    def test_compose_exchange_keeps_key_off_metadata_and_uses_stdin(self):
        from unittest.mock import Mock
        from provision import fetch_bot
        import ast

        payload = {"status": "created", "realm": "", "site": "https://chat.mmjo.com",
                   "bot_email": "inigo-bot@chat.mmjo.com", "user_id": 44,
                   "owner_email": "michael@mmjo.com", "api_key": "a" * 32}
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, json.dumps(payload), "ignored"))
        metadata, key = fetch_bot(runner=runner)
        self.assertEqual(key, "a" * 32)
        self.assertEqual(metadata, {k: v for k, v in payload.items() if k != "api_key"})
        self.assertNotIn(key, json.dumps(metadata))
        args, kwargs = runner.call_args
        command = args[0]
        self.assertEqual(command[1:11], ["compose", "--project-name", "zulip", "-f",
                        "/etc/zulip/compose.yaml", "exec", "-T", "--user", "root", "zulip"])
        self.assertEqual(command[11:15], ["su", "zulip", "-c", command[14]])
        self.assertIn("/home/zulip/deployments/current/manage.py shell", command[14])
        self.assertIn("--verbosity 0", command[14])
        self.assertTrue(kwargs["capture_output"])
        self.assertTrue(kwargs["text"])
        ast.parse(kwargs["input"])
        self.assertIn("do_create_user(", kwargs["input"])
        self.assertIn("notify_created_bot(bot)", kwargs["input"])
        self.assertNotIn(key, str(command))


class OrchestrationTests(unittest.TestCase):
    def test_unsafe_local_file_fails_before_docker(self):
        from unittest.mock import Mock
        from provision import run_provision
        import tempfile
        for kind in ("symlink", "hardlink", "fifo", "public", "bad-format", "directory"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                directory = Path(directory)
                directory.chmod(0o700)
                target = directory / "api-key"
                unrelated = directory / "unrelated"
                unrelated.write_text("not an API credential")
                if kind == "symlink":
                    target.symlink_to(unrelated)
                elif kind == "hardlink":
                    os.link(unrelated, target)
                    target.chmod(0o400)
                elif kind == "fifo":
                    os.mkfifo(target, 0o400)
                elif kind == "directory":
                    target.mkdir()
                else:
                    target.write_text("a" * 32 + "\n" if kind == "public" else "invalid\n")
                    target.chmod(0o644 if kind == "public" else 0o400)
                runner = Mock(side_effect=AssertionError("Docker must not run"))
                with self.assertRaises((ValueError, OSError)):
                    run_provision(directory, expected_uid=os.geteuid(), runner=runner)
                runner.assert_not_called()
                self.assertEqual(unrelated.read_text(), "not an API credential")

    def test_locked_or_unsafe_directory_fails_before_docker(self):
        from unittest.mock import Mock
        from provision import run_provision
        import tempfile
        import fcntl
        for kind in ("locked", "public-directory", "symlink-directory", "wrong-owner"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as parent:
                directory = Path(parent) / "state"
                directory.mkdir()
                directory.chmod(0o700)
                uid = os.geteuid()
                runner = Mock(side_effect=AssertionError("Docker must not run"))
                if kind == "public-directory":
                    directory.chmod(0o755)
                elif kind == "symlink-directory":
                    link = Path(parent) / "link"
                    link.symlink_to(directory, target_is_directory=True)
                    directory = link
                elif kind == "wrong-owner":
                    uid += 1
                with open(directory / ".lock", "w") as lock:
                    os.chmod(directory / ".lock", 0o600)
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    with self.assertRaises((ValueError, OSError)):
                        run_provision(directory, expected_uid=uid, runner=runner)
                runner.assert_not_called()

    def test_docker_failure_never_publishes_a_credential(self):
        from unittest.mock import Mock
        from provision import run_provision
        import tempfile
        runner = Mock(return_value=subprocess.CompletedProcess([], 1, "secret-suppressed", "secret-suppressed"))
        with tempfile.TemporaryDirectory() as parent:
            directory = Path(parent) / "state"
            with self.assertRaises(ValueError):
                run_provision(directory, expected_uid=os.geteuid(), runner=runner)
            self.assertFalse((directory / "api-key").exists())

    def test_two_runs_reuse_credential_and_only_return_public_metadata(self):
        from unittest.mock import Mock
        from provision import run_provision
        import tempfile
        import contextlib
        import io
        payload = {"status": "created", "realm": "", "site": "https://chat.mmjo.com",
                   "bot_email": "inigo-bot@chat.mmjo.com", "user_id": 44,
                   "owner_email": "michael@mmjo.com", "api_key": "a" * 32}
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, json.dumps(payload), ""))
        with tempfile.TemporaryDirectory() as parent:
            directory = Path(parent) / "state"
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                first = run_provision(directory, expected_uid=os.geteuid(), runner=runner)
                before = (directory / "api-key").stat()
                payload["status"] = "existing"
                runner.return_value = subprocess.CompletedProcess([], 0, json.dumps(payload), "")
                second = run_provision(directory, expected_uid=os.geteuid(), runner=runner)
            self.assertEqual(first["status"], "created")
            self.assertEqual(second["status"], "existing")
            self.assertEqual((directory / "api-key").stat().st_ino, before.st_ino)
            self.assertNotIn("a" * 32, json.dumps((first, second)))
            self.assertEqual(stdout.getvalue() + stderr.getvalue(), "")
            self.assertEqual(runner.call_count, 2)


if __name__ == "__main__":
    unittest.main()
