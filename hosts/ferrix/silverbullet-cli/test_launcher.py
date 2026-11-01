"""Credential-boundary tests; the file protocol remains upstream's implementation."""

import importlib.util
import contextlib
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent


class LauncherTest(unittest.TestCase):
    def load_launcher(self):
        path = ROOT / "launcher.py"
        self.assertTrue(path.is_file(), "the protected upstream-client launcher is missing")
        spec = importlib.util.spec_from_file_location("inigo_sb_launcher", path)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_secret_is_supplied_only_on_setup_stdin(self):
        launcher = self.load_launcher()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            token = root / "silverbullet-api-token"
            token.write_text("fixture-token-not-a-real-secret\n")
            token.chmod(0o400)
            calls = []

            def upstream(command, **kwargs):
                calls.append((command, kwargs))
                if "add" in command:
                    config = Path(kwargs["env"]["XDG_CONFIG_HOME"]) / "silverbullet"
                    config.mkdir(mode=0o700)
                    (config / "config.json").write_text(
                        '{"spaces":[{"name":"ksp","url":"http://127.0.0.1:3000/ksp",'
                        '"auth":{"method":"token","encryptedToken":"fixture-cipher"}}]}'
                    )
                    (config / "config.json").chmod(0o600)
                    return subprocess.CompletedProcess(command, 0, b"", b"")
                return subprocess.CompletedProcess(command, 0)

            with patch.dict(os.environ, {"CREDENTIALS_DIRECTORY": temporary}), patch.object(
                launcher.subprocess, "run", side_effect=upstream
            ):
                result = launcher.run(
                    ["ksp", "fs", "stat", "GSA.md", "--json"],
                    binary="/upstream/bin/sb",
                    spaces={"ksp": "http://127.0.0.1:3000/ksp"},
                )
            self.assertEqual(result, 0)
            self.assertEqual(len(calls), 2)
            setup, request = calls
            self.assertEqual(setup[1]["input"], b"ksp\nhttp://127.0.0.1:3000/ksp\ntoken\nfixture-token-not-a-real-secret\n")
            self.assertEqual(request[0], ["/upstream/bin/sb", "--space", "ksp", "fs", "stat", "GSA.md", "--json"])
            for command, kwargs in calls:
                self.assertNotIn("fixture-token-not-a-real-secret", repr(command))
                self.assertNotIn("fixture-token-not-a-real-secret", repr(kwargs["env"]))
            self.assertFalse(Path(setup[1]["env"]["XDG_CONFIG_HOME"]).exists())

    def test_systemd_fallback_works_when_terminal_filters_environment(self):
        launcher = self.load_launcher()
        with tempfile.TemporaryDirectory() as temporary:
            token = Path(temporary) / "silverbullet-api-token"
            token.write_text("fixture-token\n")
            token.chmod(0o440)
            with patch.dict(os.environ, {}, clear=True), patch.object(
                launcher, "CREDENTIAL_DIRECTORIES", [Path(temporary)], create=True
            ), patch.object(launcher.subprocess, "run") as upstream, contextlib.redirect_stderr(io.StringIO()):
                upstream.return_value.returncode = 1
                launcher.run(
                    ["personal", "fs", "stat", "GSA.md"],
                    binary="/upstream/bin/sb",
                    spaces={"personal": "http://127.0.0.1:3000"},
                )
            self.assertTrue(upstream.called, "the systemd credential fallback was not used")

    def test_connection_overrides_are_rejected_before_authentication(self):
        launcher = self.load_launcher()
        for option in ("--url", "--url=https://example.invalid", "--token", "--token=x", "--space", "-s"):
            with self.subTest(option=option), patch.object(launcher.subprocess, "run") as upstream:
                with contextlib.redirect_stderr(io.StringIO()):
                    code = launcher.run(
                        ["personal", "fs", "stat", "GSA.md", option],
                        binary="/upstream/bin/sb",
                        spaces={"personal": "http://127.0.0.1:3000"},
                    )
                self.assertEqual(code, 2)
                upstream.assert_not_called()

    def test_unsafe_credentials_never_reach_upstream(self):
        launcher = self.load_launcher()
        for kind in ("world-readable", "group-readable", "symlink", "multiline", "empty", "oversized"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                source = Path(temporary) / "silverbullet-api-token"
                source.write_text("fixture-token\n")
                source.chmod(0o400)
                if kind == "world-readable":
                    source.chmod(0o444)
                elif kind == "group-readable":
                    source.chmod(0o440)
                elif kind == "symlink":
                    target = source.with_name("target")
                    source.rename(target)
                    source.symlink_to(target)
                else:
                    source.chmod(0o600)
                    source.write_text({"multiline": "first\nsecond", "empty": "", "oversized": "x" * 16385}[kind])
                    source.chmod(0o400)
                with patch.dict(os.environ, {"CREDENTIALS_DIRECTORY": temporary}), patch.object(
                    launcher.subprocess, "run"
                ) as upstream, contextlib.redirect_stderr(io.StringIO()):
                    code = launcher.run(
                        ["personal", "fs", "stat", "GSA.md"],
                        binary="/upstream/bin/sb",
                        spaces={"personal": "http://127.0.0.1:3000"},
                    )
                self.assertEqual(code, 4)
                upstream.assert_not_called()

    def test_login_output_is_not_forwarded_and_temporary_state_is_removed(self):
        launcher = self.load_launcher()
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "silverbullet-api-token"
            source.write_text("fixture-token\n")
            source.chmod(0o400)
            output = io.StringIO()
            with patch.dict(os.environ, {"CREDENTIALS_DIRECTORY": temporary}), patch.object(
                launcher.subprocess, "run", return_value=subprocess.CompletedProcess(
                    [], 1, b"fixture-token", b"fixture-token"
                )
            ) as upstream, contextlib.redirect_stderr(output):
                code = launcher.run(
                    ["personal", "fs", "stat", "GSA.md"],
                    binary="/upstream/bin/sb",
                    spaces={"personal": "http://127.0.0.1:3000"},
                )
            self.assertEqual(code, 4)
            self.assertEqual(upstream.call_count, 1)
            self.assertNotIn("fixture-token", output.getvalue())
            self.assertFalse(Path(upstream.call_args.kwargs["env"]["XDG_CONFIG_HOME"]).exists())

    def test_help_does_not_require_a_credential(self):
        launcher = self.load_launcher()
        with patch.dict(os.environ, {}, clear=True), patch.object(
            launcher.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)
        ) as upstream:
            result = launcher.run(
                ["ksp", "fs", "edit", "--help"],
                binary="/upstream/bin/sb",
                spaces={"ksp": "http://127.0.0.1:3000/ksp"},
            )
        self.assertEqual(result, 0)
        upstream.assert_called_once_with(["/upstream/bin/sb", "fs", "edit", "--help"], check=False)


if __name__ == "__main__":
    unittest.main()
