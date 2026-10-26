"""Regression checks for the single, agent-neutral SilverBullet skill bundle."""

from pathlib import Path
import unittest


class SharedSkillTest(unittest.TestCase):
    def test_shared_bundle_has_both_adapters_and_journal_contract(self):
        root = Path(__file__).resolve().parent
        packaged = root / "skills" / "silverbullet"
        bundle = packaged if (packaged / "SKILL.md").is_file() else (
            root.parents[2] / "agents" / "skills" / "silverbullet"
        )
        content = (bundle / "SKILL.md").read_text()
        self.assertIn("change_summary", content)
        self.assertIn("America/New_York", content)
        self.assertIn("silverbullet_journal_retry", content)
        self.assertIn("Do not append a second journal entry", content)
        for agent in ("pi", "hermes"):
            reference = f"references/{agent}.md"
            self.assertIn(reference, content)
            self.assertTrue((bundle / reference).is_file())
        self.assertNotIn("silverbullet-journal-links", content)

    def test_shared_markdown_is_wrapped_and_has_portable_frontmatter(self):
        root = Path(__file__).resolve().parent
        packaged = root / "skills" / "silverbullet"
        bundle = packaged if (packaged / "SKILL.md").is_file() else (
            root.parents[2] / "agents" / "skills" / "silverbullet"
        )
        content = (bundle / "SKILL.md").read_text()
        self.assertTrue(content.startswith("---\nname: silverbullet\n"))
        self.assertNotIn("silverbullet_list_pages\n", content.split("---", 2)[1])
        for file in bundle.rglob("*.md"):
            for number, line in enumerate(file.read_text().splitlines(), 1):
                with self.subTest(file=file.name, line=number):
                    self.assertLessEqual(len(line), 88)


if __name__ == "__main__":
    unittest.main()
