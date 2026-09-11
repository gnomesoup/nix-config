from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("silverbullet-git-setup.py")
SPEC = importlib.util.spec_from_file_location("silverbullet_git_setup", SCRIPT)
assert SPEC and SPEC.loader
setup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(setup)


class GitSetupTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        git = shutil.which("git")
        assert git
        self.git = Path(git)
        self.personal = self.root / "spaces" / "personal-id"
        self.ksp = self.root / "spaces" / "ksp-id"
        self.other = self.root / "spaces" / "other-id"
        for folder in (self.personal, self.ksp, self.other):
            folder.mkdir(parents=True)
            (folder / "index.md").write_text(f"# {folder.name}\n", encoding="utf-8")
        self.config_path = self.root / "spaces.json"
        self.initial = {
            "personal-id": {
                "name": "Personal",
                "folder": "",
                "binding": {"prefix": "/"},
                "shell": {"enabled": False, "whitelist": []},
                "futureField": {"preserved": True},
            },
            "ksp-id": {
                "name": "KSP",
                "folder": "spaces/ksp-id",
                "binding": {"prefix": "/ksp"},
            },
            "other-id": {
                "name": "Other",
                "folder": "spaces/other-id",
                "binding": {"prefix": "/other"},
                "shell": {"enabled": True, "whitelist": []},
            },
        }
        self.config_path.write_text(json.dumps(self.initial), encoding="utf-8")
        self.config_path.chmod(0o600)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def git_output(self, folder: Path, *arguments: str) -> str:
        return subprocess.check_output(
            [str(self.git), "-C", str(folder), *arguments],
            text=True,
        ).strip()

    def test_enables_only_git_for_expected_spaces_and_initializes_repositories(self) -> None:
        setup.configure(self.root, self.git)

        configured = json.loads(self.config_path.read_text(encoding="utf-8"))
        expected_policy = {"enabled": True, "whitelist": ["git"]}
        self.assertEqual(configured["personal-id"]["shell"], expected_policy)
        self.assertEqual(configured["ksp-id"]["shell"], expected_policy)
        self.assertEqual(configured["other-id"]["shell"], {"enabled": False, "whitelist": []})
        self.assertEqual(configured["personal-id"]["futureField"], {"preserved": True})
        self.assertEqual(self.config_path.stat().st_mode & 0o777, 0o600)

        for folder in (self.personal, self.ksp):
            self.assertTrue((folder / ".git").is_dir())
            self.assertEqual(self.git_output(folder, "log", "-1", "--format=%s"), "Initial SilverBullet snapshot")
            self.assertEqual(self.git_output(folder, "show", "HEAD:index.md"), f"# {folder.name}")
        self.assertFalse((self.other / ".git").exists())

    def test_existing_repository_is_not_automatically_committed_again(self) -> None:
        setup.configure(self.root, self.git)
        head = self.git_output(self.personal, "rev-parse", "HEAD")
        (self.personal / "index.md").write_text("changed\n", encoding="utf-8")

        setup.configure(self.root, self.git)

        self.assertEqual(self.git_output(self.personal, "rev-parse", "HEAD"), head)
        self.assertIn("index.md", self.git_output(self.personal, "status", "--porcelain"))

    def test_fails_closed_when_an_expected_space_is_missing(self) -> None:
        del self.initial["ksp-id"]
        self.config_path.write_text(json.dumps(self.initial), encoding="utf-8")
        before = self.config_path.read_bytes()

        with self.assertRaisesRegex(setup.SetupError, "missing expected spaces: KSP"):
            setup.configure(self.root, self.git)

        self.assertEqual(self.config_path.read_bytes(), before)
        self.assertFalse((self.personal / ".git").exists())

    def test_rejects_space_folder_outside_state_directory(self) -> None:
        outside = self.root.parent / f"{self.root.name}-outside"
        outside.mkdir()
        self.addCleanup(lambda: shutil.rmtree(outside, ignore_errors=True))
        self.initial["personal-id"]["folder"] = str(outside)
        self.config_path.write_text(json.dumps(self.initial), encoding="utf-8")

        with self.assertRaisesRegex(setup.SetupError, "existing child"):
            setup.configure(self.root, self.git)

        self.assertFalse((outside / ".git").exists())


if __name__ == "__main__":
    unittest.main()
