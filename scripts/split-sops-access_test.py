#!/usr/bin/env python3
"""Real age/SOPS fixtures; never load repository secrets or print fixture values."""
import json
import os
from pathlib import Path
import runpy
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

SCRIPT = Path(__file__).with_name("split-sops-access.py")
INTEGRATIONS = (
    "inigo/ssh_key", "inigo/home-assistant-token", "inigo/protonmail-bridge-email",
    "inigo/protonmail-bridge-username", "inigo/protonmail-bridge-password",
    "inigo/silverbullet-api-token", "inigo/github-deploy-key", "hermes/api-server-key",
    "hermes/dashboard-password", "hermes/dashboard-secret",
)
BACKUPS = ("borg/borg_passphrase", "borg/endor/borgbase_path", "zulip/email_username", "zulip/email_password")


def leaves(tree, prefix=""):
    result = {}
    for key, value in tree.items():
        path = f"{prefix}/{key}" if prefix else key
        if isinstance(value, dict):
            result.update(leaves(value, path))
        else:
            result[path] = value
    return result


class Fixtures(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="sops-split-test-", dir=os.environ["TMPDIR"])
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "LANG") if key in os.environ}
        self.env.update(HOME=str(self.root / "home"), XDG_CONFIG_HOME=str(self.root / "config"),
                        GNUPGHOME=str(self.root / "gpg"))
        for key in ("HOME", "XDG_CONFIG_HOME", "GNUPGHOME"):
            Path(self.env[key]).mkdir(mode=0o700)
        self.public = []
        self.keys = []
        for index in range(3):
            key = self.root / f"identity-{index}"
            self.command(["age-keygen", "-o", str(key)])
            key.chmod(0o600)
            self.public.append(self.command(["age-keygen", "-y", str(key)]).stdout.decode().strip())
            self.keys.append(key)
        self.env["SOPS_AGE_KEY_FILE"] = str(self.keys[0])
        self.canary = "fixture-private-" + uuid.uuid4().hex
        self.tree = {"inigo": {}, "hermes": {}, "borg": {"endor": {}}, "zulip": {}}
        for index, path in enumerate(INTEGRATIONS + BACKUPS):
            parts = path.split("/")
            # Mix literal slash keys and nested mappings without changing the shape.
            if index % 2:
                self.tree[path] = self.canary + str(index)
            else:
                target = self.tree
                for part in parts[:-1]:
                    target = target.setdefault(part, {})
                target[parts[-1]] = self.canary + str(index)
        # Do not leave empty containers in fixtures.
        self.tree["borg"].pop("endor")
        self.tree["inigo"]["age-key"] = self.canary + "bootstrap"
        self.tree["unknown"] = {"future_unencrypted": self.canary + "unknown"}
        self.source = self.root / "source.yaml"
        self.integration = self.root / "integration.yaml"
        self.backup = self.root / "backup.yaml"
        self.write_source()

    def command(self, args, data=None, env=None, required=True):
        result = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=env or self.env, cwd=self.root, check=False)
        if required and result.returncode:
            raise RuntimeError("fixture command failed (output suppressed)")
        return result

    def write_source(self, recipients=None, output_type="yaml"):
        result = self.command(["sops", "encrypt", "--input-type", "json", "--output-type", output_type,
                               "--age", ",".join(recipients or self.public), "--encrypted-regex", ".*",
                               "--filename-override", str(self.root / "payload.json")],
                              json.dumps(self.tree).encode())
        self.source.write_bytes(result.stdout)
        self.source.chmod(0o600)
        self.original = result.stdout

    def migrate(self, extra=()):
        result = self.command([sys.executable, str(SCRIPT), "--source", str(self.source),
                               "--integration-output", str(self.integration), "--backup-output", str(self.backup),
                               "--agent-recipient", self.public[0], *extra], required=False)
        self.assertTrue(self.canary.encode() not in result.stdout + result.stderr,
                        "fixture plaintext leaked through process output")
        for path in self.root.rglob("*"):
            if path.is_file() and not path.is_symlink():
                self.assertTrue(self.canary.encode() not in path.read_bytes(), "fixture plaintext leaked to disk")
        return result

    def decrypt(self, path, identity=0, required=True):
        env = dict(self.env, SOPS_AGE_KEY_FILE=str(self.keys[identity]))
        result = self.command(["sops", "decrypt", "--input-type", "yaml", "--output-type", "json", str(path)],
                              env=env, required=required)
        return json.loads(result.stdout) if required else result

    def test_split_reencrypts_preserves_shape_and_limits_access(self):
        result = self.migrate()
        self.assertTrue(result.returncode == 0, "migration must succeed")
        expected = leaves(self.tree)
        recovered = {}
        for path, allowed in ((self.integration, set(INTEGRATIONS)), (self.backup, set(BACKUPS)),
                              (self.source, set(expected) - set(INTEGRATIONS) - set(BACKUPS))):
            tree = self.decrypt(path, identity=1)
            self.assertTrue(set(leaves(tree)) == allowed, "partition keys differ")
            self.assertTrue(all(expected[k] == v for k, v in leaves(tree).items()), "partition values differ")
            recovered.update(leaves(tree))
            encrypted = json.loads(path.read_bytes())
            recipients = {entry["recipient"] for entry in encrypted["sops"]["age"]}
            self.assertTrue(recipients == (set(self.public[1:]) if path == self.source else set(self.public)),
                            "public recipients differ")
            self.assertTrue(stat.S_IMODE(path.stat().st_mode) == 0o600, "ciphertext mode is not private")
        self.assertTrue(recovered == expected, "partition union differs")
        self.assertTrue(self.decrypt(self.integration) == self.decrypt(self.integration, identity=1), "integration differs")
        self.assertTrue(self.decrypt(self.backup) == self.decrypt(self.backup, identity=1), "backup differs")
        self.assertTrue(self.decrypt(self.source, required=False).returncode != 0, "agent must be denied main")
        main = self.decrypt(self.source, identity=1)
        self.assertTrue(main == {"inigo": {"age-key": self.tree["inigo"]["age-key"]}, "unknown": self.tree["unknown"]},
                        "restricted shape differs")
        self.assertTrue(self.decrypt(self.integration)["inigo"]["ssh_key"] == self.tree["inigo"]["ssh_key"],
                        "nested shape differs")
        self.assertTrue(self.decrypt(self.integration)["inigo/home-assistant-token"] == self.tree["inigo/home-assistant-token"],
                        "literal slash shape differs")
        self.assertTrue(self.original != self.source.read_bytes(), "main must be freshly encrypted")

    def assert_refused_without_changes(self, extra=()):
        before = self.source.read_bytes()
        result = self.migrate(extra)
        self.assertTrue(result.returncode != 0, "unsafe migration must be refused")
        self.assertTrue(self.source.read_bytes() == before, "refusal changed original ciphertext")
        self.assertTrue(not self.integration.exists() and not self.backup.exists(), "refusal created output")
        self.assertTrue(not list(self.root.glob(".sops-split-*")), "temporary ciphertext was not cleaned up")

    def test_dry_run_does_not_write(self):
        result = self.migrate(("--dry-run",))
        self.assertTrue(result.returncode == 0, "dry run must succeed")
        report = json.loads(result.stdout)
        self.assertTrue(report["counts"] == [2, 10, 4], "dry run counts differ")
        self.assertTrue(self.source.read_bytes() == self.original, "dry run changed source")
        self.assertTrue(not self.integration.exists() and not self.backup.exists(), "dry run wrote output")

    def test_json_source(self):
        self.write_source(output_type="json")
        result = self.migrate()
        self.assertTrue(result.returncode == 0, "JSON source must succeed")
        self.assertTrue(self.decrypt(self.source, identity=2)["unknown"] == self.tree["unknown"], "human access differs")
        encrypted = json.loads(self.source.read_bytes())
        old = json.loads(self.original)
        self.assertTrue(encrypted["inigo"]["age-key"] != old["inigo"]["age-key"], "data key must be fresh")
        self.assertTrue(encrypted["unknown"] != old["unknown"], "unknown ciphertext must be fresh")

    def test_missing_allowlisted_path(self):
        del self.tree["inigo"]["ssh_key"]
        self.write_source()
        self.assert_refused_without_changes()

    def test_missing_agent_recipient(self):
        self.write_source(recipients=self.public[1:])
        self.assert_refused_without_changes()

    def test_agent_only_recipient(self):
        self.write_source(recipients=self.public[:1])
        self.assert_refused_without_changes()

    def test_nonexistent_output_parent(self):
        self.assert_refused_without_changes(("--backup-output", str(self.root / "absent" / "output.yaml")))

    def test_symlink_output_target(self):
        self.backup.symlink_to(self.source)
        result = self.migrate()
        self.assertTrue(result.returncode != 0, "symlink output must be refused")
        self.assertTrue(self.source.read_bytes() == self.original, "symlink refusal changed source")
        self.assertTrue(self.backup.is_symlink() and not self.integration.exists(), "symlink target changed")

    def test_existing_output_not_overwritten(self):
        self.backup.write_bytes(b"existing ciphertext marker")
        result = self.migrate()
        self.assertTrue(result.returncode != 0, "existing output must be refused")
        self.assertTrue(self.backup.read_bytes() == b"existing ciphertext marker", "existing output was overwritten")
        self.assertTrue(self.source.read_bytes() == self.original and not self.integration.exists(), "refusal wrote files")

    def test_flattened_path_collision(self):
        self.tree["inigo/ssh_key"] = self.canary + "duplicate"
        self.write_source()
        self.assert_refused_without_changes()

    def test_unsupported_key_groups(self):
        self.write_source(output_type="json")
        cipher = json.loads(self.original)
        cipher["sops"]["key_groups"] = []
        self.source.write_bytes(json.dumps(cipher).encode())
        self.assert_refused_without_changes()

    def test_unsupported_backend(self):
        self.write_source(output_type="json")
        cipher = json.loads(self.original)
        cipher["sops"]["pgp"] = [{"fp": "unsupported"}]
        self.source.write_bytes(json.dumps(cipher).encode())
        self.assert_refused_without_changes()

    def test_wrong_private_identity(self):
        self.env["SOPS_AGE_KEY_FILE"] = str(self.keys[1])
        self.assert_refused_without_changes()

    def test_cli_errors_do_not_echo_arguments(self):
        self.assert_refused_without_changes(("--invalid-option", self.canary))

    def test_subprocess_plaintext_error_output_is_suppressed(self):
        wrapper_dir = self.root / "bin"
        wrapper_dir.mkdir()
        wrapper = wrapper_dir / "sops"
        real_sops = shutil.which("sops", path=self.env["PATH"])
        self.assertTrue(real_sops is not None, "SOPS must be installed")
        wrapper.write_text(f"#!{sys.executable}\nimport os,sys\n"
                           "if 'encrypt' in sys.argv:\n"
                           "    data=sys.stdin.buffer.read()\n"
                           "    sys.stdout.buffer.write(data)\n"
                           "    sys.stderr.buffer.write(data)\n"
                           "    sys.exit(1)\n"
                           f"os.execv({real_sops!r},[{real_sops!r},*sys.argv[1:]])\n")
        wrapper.chmod(0o700)
        self.env["PATH"] = str(wrapper_dir) + os.pathsep + self.env["PATH"]
        self.assert_refused_without_changes()

    def test_rollback_after_output_link_failure(self):
        helper = runpy.run_path(str(SCRIPT))
        original_link = os.link
        calls = 0

        def interrupted_link(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("injected link failure")
            return original_link(*args, **kwargs)

        with patch("os.link", interrupted_link), self.assertRaises(OSError):
            helper["commit"](self.source, [(p, self.original) for p in (self.source, self.integration, self.backup)],
                             self.original, self.source.stat())
        self.assertTrue(self.source.read_bytes() == self.original, "rollback changed source")
        self.assertTrue(not self.integration.exists() and not self.backup.exists(), "rollback left output")
        self.assertTrue(not list(self.root.glob(".sops-split-*")), "rollback left staging files")

    def test_rollback_after_main_replace(self):
        helper = runpy.run_path(str(SCRIPT))
        original_fsync = os.fsync
        injected = False

        def interrupted_fsync(fd):
            nonlocal injected
            if not injected and stat.S_ISDIR(os.fstat(fd).st_mode):
                injected = True
                raise OSError("injected directory flush failure")
            return original_fsync(fd)

        fresh = self.command(["sops", "encrypt", "--input-type", "json", "--output-type", "json",
                              "--age", ",".join(self.public), "--filename-override", "fixture.json"],
                             json.dumps(self.tree).encode()).stdout
        with patch("os.fsync", interrupted_fsync), self.assertRaises(OSError):
            helper["commit"](self.source, [(p, fresh) for p in (self.source, self.integration, self.backup)],
                             self.original, self.source.stat())
        self.assertTrue(injected, "post-replace failure must be exercised")
        self.assertTrue(self.source.read_bytes() == self.original, "rollback failed to restore ciphertext")
        self.assertTrue(not self.integration.exists() and not self.backup.exists(), "rollback left output")
        self.assertTrue(not list(self.root.glob(".sops-split-*")), "rollback left staging files")

    def test_rollback_survives_subsequent_write_failure(self):
        helper = runpy.run_path(str(SCRIPT))
        original_fsync = os.fsync
        failed = False

        def persistent_failure(fd):
            nonlocal failed
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                failed = True
            if failed:
                raise OSError("injected persistent flush failure")
            return original_fsync(fd)

        with patch("os.fsync", persistent_failure), self.assertRaises(OSError):
            helper["commit"](self.source, [(p, self.original + b"\n") for p in (self.source, self.integration, self.backup)],
                             self.original, self.source.stat())
        self.assertTrue(failed, "persistent failure was not exercised")
        self.assertTrue(self.source.read_bytes() == self.original, "persistent failure prevented rollback")
        self.assertTrue(not self.integration.exists() and not self.backup.exists(), "persistent failure left outputs")
        self.assertTrue(not list(self.root.glob(".sops-split-*")), "persistent failure left staging files")

    def test_rollback_does_not_remove_racing_output(self):
        helper = runpy.run_path(str(SCRIPT))
        original_link = os.link
        calls = 0

        def racing_link(src, dst):
            nonlocal calls
            calls += 1
            if calls == 2:
                Path(dst).write_bytes(b"external ciphertext marker")
            return original_link(src, dst)

        with patch("os.link", racing_link), self.assertRaises(FileExistsError):
            helper["commit"](self.source, [(p, self.original) for p in (self.source, self.integration, self.backup)],
                             self.original, self.source.stat())
        self.assertTrue(self.source.read_bytes() == self.original, "racing output changed source")
        self.assertTrue(not self.integration.exists(), "own output was not removed")
        self.assertTrue(self.backup.read_bytes() == b"external ciphertext marker", "external output was removed")
        self.assertTrue(not list(self.root.glob(".sops-split-*")), "racing output left staging files")

    def test_original_ciphertext_change_prevents_commit(self):
        helper = runpy.run_path(str(SCRIPT))
        info = self.source.stat()
        self.source.write_bytes(self.original + b"\n")
        with self.assertRaises(helper["Refused"]):
            helper["commit"](self.source, [(p, self.original) for p in (self.source, self.integration, self.backup)],
                             self.original, info)
        self.assertTrue(self.source.read_bytes() == self.original + b"\n", "changed source was overwritten")
        self.assertTrue(not self.integration.exists() and not self.backup.exists(), "changed source created outputs")

    def test_help_is_successful(self):
        result = self.command([sys.executable, str(SCRIPT), "--help"], required=False)
        self.assertTrue(result.returncode == 0, "help must exit successfully")
        self.assertTrue(not result.stderr, "help must not emit a failure status")


if __name__ == "__main__":
    unittest.main(verbosity=1)
