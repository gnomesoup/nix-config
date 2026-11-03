"""Check that the evaluated Ferrix sync plan deploys the repository theme."""

from __future__ import annotations

import ast
import json
import os
import shlex
import unittest
from pathlib import Path


class ThemeSyncTest(unittest.TestCase):
    def test_sync_plan_installs_exact_theme_in_both_spaces(self) -> None:
        plan = Path(os.environ["THEME_SYNC_PLAN"]).read_text()
        candidates = []
        for line in plan.splitlines():
            words = shlex.split(line, comments=True)
            if len(words) != 2 or not words[1].endswith(".py"):
                continue
            assignments = {
                statement.targets[0].id: statement.value
                for statement in ast.parse(Path(words[1]).read_text()).body
                if isinstance(statement, ast.Assign)
                and len(statement.targets) == 1
                and isinstance(statement.targets[0], ast.Name)
            }
            destination = assignments.get("FILE_PATH_IN_SPACE")
            if destination is not None and ast.literal_eval(destination) == (
                "_config/spacemacs-notebook.md"
            ):
                candidates.append(assignments)

        self.assertEqual(len(candidates), 1, "theme must be synchronized exactly once")
        theme = candidates[0]
        self.assertEqual(
            json.loads(ast.literal_eval(theme["_SPACE_PREFIXES_JSON"])),
            [["Personal", ""], ["KSP", "/ksp"]],
        )
        self.assertEqual(
            ast.literal_eval(theme["_CONTENT_TYPE"]), "text/markdown; charset=utf-8"
        )
        source = theme["FILE_PATH_ON_DISK"]
        self.assertIsInstance(source, ast.Call)
        deployed = Path(ast.literal_eval(source.args[0])).read_bytes()
        expected = Path(os.environ["THEME_SOURCE"]).read_bytes()
        self.assertEqual(deployed, expected)
        self.assertEqual(deployed.count(b"```space-style\n"), 1)


if __name__ == "__main__":
    unittest.main()
