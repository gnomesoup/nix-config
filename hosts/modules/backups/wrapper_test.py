"""Exercise generated Borg wrappers and pinned public host keys without networking."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.environ.get("BACKUP_WRAPPER_TESTS"), "Nix supplies generated wrappers")
class WrapperTests(unittest.TestCase):
    def run_missing(self, missing, expected):
        for config in json.loads(os.environ["BACKUP_WRAPPER_TESTS"]):
            with self.subTest(wrapper=config["wrapper"], missing=missing), \
                    tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                script = Path(config["wrapper"]).read_text()
                for field in ["passphraseFile", "sshKeyFile", "knownHostsFile"]:
                    path = root / field
                    self.assertIn(config[field], script)
                    script = script.replace(config[field], str(path))
                    if field != missing:
                        path.write_text("test-only-credential" if field != "knownHostsFile" else
                            "unrelated.example ssh-ed25519 "
                            "AAAAC3NzaC1lZDI1NTE5AAAAIGU0mISTyHBw9tBs6SuhSq8tvNM8m9eifQxM+88TowPO\n")
                # Prevent any regression from reaching the actual Borg/SSH call.
                script = script.replace("    exec ", "    exit 99 # exec ")
                lines = script.splitlines()
                for index, line in enumerate(lines):
                    if line.lstrip().startswith("exec "):
                        lines[index] = "exit 99 # network access forbidden in this test"
                probe = root / "wrapper"
                probe.write_text("\n".join(lines) + "\n")
                probe.chmod(0o700)
                result = subprocess.run([str(probe), "info"], text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(expected, result.stderr)
                self.assertNotIn("test-only-credential", result.stdout + result.stderr)

    def test_missing_passphrase_reports_failure(self):
        self.run_missing("passphraseFile", "Repository passphrase file is missing or empty")

    def test_missing_ssh_identity_reports_failure(self):
        self.run_missing("sshKeyFile", "SSH identity file is missing or empty")

    def test_missing_trust_file_reports_failure(self):
        self.run_missing("knownHostsFile", "Verified SSH trust file is missing or empty")

    def test_missing_host_entry_reports_failure(self):
        self.run_missing(None, "Verified SSH host key is missing")

    def test_pinned_keys_match_verified_fingerprints(self):
        path = os.environ["BACKUP_KNOWN_HOSTS"]
        expected = {
            "hoth.tailbb897.ts.net": "SHA256:C8Wdh7MCKOmbiSIaLW9qzTx7HpdpIJD3anYgN+fJhFs",
            "hlek3m3n.repo.borgbase.com": "SHA256:tlz8o+DhESqRqmPaDA1yOlT7avGqCEqdhbjB8h6R29s",
            "x387mg6b.repo.borgbase.com": "SHA256:tlz8o+DhESqRqmPaDA1yOlT7avGqCEqdhbjB8h6R29s",
        }
        for host, fingerprint in expected.items():
            with self.subTest(host=host):
                entry = subprocess.run(["ssh-keygen", "-F", host, "-f", path], check=True,
                    text=True, stdout=subprocess.PIPE).stdout
                result = subprocess.run(["ssh-keygen", "-lf", "/dev/stdin"], input=entry,
                    check=True, text=True, stdout=subprocess.PIPE).stdout
                self.assertEqual(result.split()[1], fingerprint)
        for config in json.loads(os.environ["BACKUP_WRAPPER_TESTS"]):
            self.assertEqual(config["knownHostsFile"], "/etc/managed-backups/ssh_known_hosts")


if __name__ == "__main__":
    unittest.main()
