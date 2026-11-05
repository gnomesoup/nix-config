"""Verify the evaluated deployment and failure propagation without live access."""

from __future__ import annotations

import ast
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


class DeploymentTest(unittest.TestCase):
    def test_silversearch_is_retired_in_both_spaces_and_failures_propagate(self) -> None:
        plan = Path(os.environ["SYNC_PLAN"]).read_text()
        commands = []
        retirements = []
        for line in plan.splitlines():
            parts = shlex.split(line, comments=True)
            if len(parts) < 2 or not parts[1].endswith(".py"):
                continue
            commands.append(parts)
            assignments = {
                node.targets[0].id: node.value
                for node in ast.parse(Path(parts[1]).read_text()).body
                if isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name)
            }
            if ast.literal_eval(assignments["FILE_PATH_IN_SPACE"]) == "_plug/silversearch.plug.js":
                self.assertEqual(parts[2:], ["--remove"])
                self.assertEqual(
                    json.loads(ast.literal_eval(assignments["_SPACE_PREFIXES_JSON"])),
                    [["Personal", ""], ["KSP", "/ksp"]],
                )
                retirements.append(parts)
        self.assertEqual(len(retirements), 1)
        self.assertTrue(os.environ["SERVER_START"].startswith(os.environ["EXPECTED_SERVER"] + " "))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            trace = root / "trace"
            stub = root / "python-stub"
            stub.write_text(
                f"#!{sys.executable}\n"
                "import os, pathlib, sys\n"
                "with pathlib.Path(os.environ['TRACE']).open('a') as output:\n"
                "    output.write(sys.argv[1] + '\\n')\n"
                "sys.exit(7 if sys.argv[2:] == ['--remove'] else 0)\n"
            )
            stub.chmod(0o700)
            for interpreter in {command[0] for command in commands}:
                plan = plan.replace(interpreter, shlex.quote(str(stub)))
            bash = shutil.which("bash")
            assert bash is not None
            result = subprocess.run(
                [bash, "-c", plan],
                env=os.environ | {"TRACE": str(trace)}, timeout=10,
            )
            self.assertEqual(result.returncode, 7)
            stop = commands.index(retirements[0]) + 1
            self.assertEqual(trace.read_text().splitlines(), [cmd[1] for cmd in commands[:stop]])


if __name__ == "__main__":
    unittest.main(verbosity=2)
