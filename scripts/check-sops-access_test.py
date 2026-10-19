"""Public-metadata-only checks; these fixtures contain no private keys."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CHECK = Path(__file__).with_name("check-sops-access.py")
AGENT = "age1agent"
HUMAN = "age1human"


class AccessPolicyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "secrets").mkdir()
        self.rules = [
            (r"secrets/(inigo|backup-shared|ferrix-backups|mpfammatter-espanso)\.yaml$",
             [HUMAN, AGENT]),
            (r".*\.sops$", [HUMAN]),
            (r"secrets/.*\.yaml$", [HUMAN]),
        ]
        self.write_policy()
        for name in ("inigo", "backup-shared", "ferrix-backups", "mpfammatter-espanso"):
            self.write_file(name, [HUMAN, AGENT])
        self.write_file("secrets", [HUMAN])

    def write_policy(self):
        text = "creation_rules:\n"
        for pattern, recipients in self.rules:
            text += "  - path_regex: " + pattern + "\n    age: >-\n"
            text += ",\n".join("      " + recipient for recipient in recipients) + "\n"
        (self.root / ".sops.yaml").write_text(text)

    def write_file(self, name, recipients):
        text = "fixture: ENC[fixture]\nsops:\n    age:\n"
        text += "".join("        - recipient: " + recipient + "\n" for recipient in recipients)
        (self.root / "secrets" / (name + ".yaml")).write_text(text)

    def run_check(self):
        return subprocess.run(
            [sys.executable, str(CHECK), "--root", str(self.root),
             "--agent-recipient", AGENT], capture_output=True, text=True, timeout=5)

    def test_allowed_partition_passes(self):
        self.assertEqual(self.run_check().returncode, 0)

    def test_agent_recipient_in_restricted_file_fails(self):
        self.write_file("secrets", [HUMAN, AGENT])
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_generic_yaml_policy_cannot_grant_agent_access(self):
        self.rules[-1] = (self.rules[-1][0], [HUMAN, AGENT])
        self.write_policy()
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_generic_sops_policy_cannot_grant_agent_access(self):
        self.rules[-2] = (self.rules[-2][0], [HUMAN, AGENT])
        self.write_policy()
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_unlisted_yaml_must_remain_restricted(self):
        self.write_file("new-unrelated", [HUMAN, AGENT])
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_allowed_file_needs_human_recovery_recipient(self):
        self.write_file("inigo", [AGENT])
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_missing_allowed_file_fails(self):
        (self.root / "secrets" / "inigo.yaml").unlink()
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_json_encrypted_metadata_supported(self):
        import json
        (self.root / "secrets" / "inigo.yaml").write_text(json.dumps({
            "fixture": "ENC[fixture]", "sops": {
                "age": [{"recipient": HUMAN}, {"recipient": AGENT}]}}))
        self.assertEqual(self.run_check().returncode, 0)

    def test_errors_do_not_echo_unexpected_file_content(self):
        (self.root / ".sops.yaml").write_text("PRIVATE_CANARY_DO_NOT_ECHO")
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("PRIVATE_CANARY", result.stdout + result.stderr)

    def test_yaml_age_envelope_can_precede_recipient(self):
        text = "fixture: ENC[fixture]\nsops:\n    age:\n"
        for recipient in (HUMAN, AGENT):
            text += "        - enc: encrypted-envelope\n          recipient: " + recipient + "\n"
        (self.root / "secrets" / "inigo.yaml").write_text(text)
        self.assertEqual(self.run_check().returncode, 0)


if __name__ == "__main__":
    unittest.main()
