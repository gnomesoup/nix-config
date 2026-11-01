"""Exercise the real upstream client against two isolated upstream spaces."""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest


CLIENT = os.environ.get("SB_TEST_BINARY")
SERVER = os.environ.get("SB_TEST_SERVER")
LAUNCHER = Path(__file__).resolve().parent / "launcher.py"


@unittest.skipUnless(CLIENT and SERVER, "set SB_TEST_BINARY and SB_TEST_SERVER")
class UpstreamIntegrationTest(unittest.TestCase):
    def test_binary_copy_conflicts_and_conditional_section_edit(self):
        assert CLIENT is not None and SERVER is not None
        with tempfile.TemporaryDirectory(prefix="sb-integration-") as temporary:
            root = Path(temporary)
            credentials = root / "credentials"
            credentials.mkdir(mode=0o700)
            credential = credentials / "silverbullet-api-token"
            credential.write_text("integration-fixture-token\n")
            credential.chmod(0o400)
            server_environment = os.environ.copy()
            server_environment["SB_AUTH_TOKEN"] = "integration-fixture-token"
            server_environment["SB_USER"] = "fixture:fixture-password"
            processes = []
            endpoints = {}
            try:
                for space in ("personal", "ksp"):
                    data = root / space
                    data.mkdir()
                    with socket.socket() as reservation:
                        reservation.bind(("127.0.0.1", 0))
                        port = reservation.getsockname()[1]
                    process = subprocess.Popen(
                        [SERVER, "--single", "-L", "127.0.0.1", "-p", str(port), str(data)],
                        env=server_environment,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                    processes.append(process)
                    deadline = time.monotonic() + 20
                    while True:
                        self.assertIsNone(process.poll(), "upstream fixture server exited")
                        try:
                            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                                break
                        except OSError:
                            self.assertLess(time.monotonic(), deadline, "server did not start")
                            time.sleep(0.05)
                    endpoints[space] = f"http://127.0.0.1:{port}"
                connections = root / "connections.json"
                connections.write_text(json.dumps(endpoints))
                environment = os.environ.copy()
                environment["CREDENTIALS_DIRECTORY"] = str(credentials)
                setup_environment = environment | {"XDG_CONFIG_HOME": str(root / "setup-probe")}
                setup = subprocess.run(
                    [CLIENT, "space", "add", "--no-browser"],
                    input=f"personal\n{endpoints['personal']}\ntoken\nintegration-fixture-token\n".encode(),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=setup_environment,
                    timeout=40,
                )
                self.assertEqual(setup.returncode, 0, setup.stderr.decode(errors="replace"))
                setup_config = json.loads((root / "setup-probe/silverbullet/config.json").read_text())
                self.assertEqual(setup_config["spaces"][0]["auth"]["method"], "token")

                def client(space, *arguments, input=None, expected=0):
                    result = subprocess.run(
                        [sys.executable, str(LAUNCHER), CLIENT, str(connections), space, "fs", *arguments],
                        input=input,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        env=environment,
                        timeout=100,
                    )
                    self.assertEqual(result.returncode, expected, result.stderr.decode(errors="replace"))
                    return result.stdout

                payload = b"%PDF-fixture\x00\xff\r\nnot-a-real-document\n"
                client("personal", "write", "assets/source.pdf", "--create", input=payload)
                original = client("personal", "read", "assets/source.pdf")
                self.assertEqual(original, payload)
                client("ksp", "stat", "assets/source.pdf", expected=3)
                client("ksp", "write", "assets/destination.pdf", "--create", input=original)
                self.assertEqual(client("ksp", "read", "assets/destination.pdf"), original)
                client("ksp", "write", "assets/destination.pdf", "--create", input=b"different", expected=5)
                self.assertEqual(client("ksp", "read", "assets/destination.pdf"), original)

                note = b"Personal fixture\r\n## Work\r\nMove this\r\n## Personal\r\nKeep this\r\n"
                client("personal", "write", "Mixed.md", "--create", input=note)
                revision = json.loads(client("personal", "stat", "Mixed.md", "--json"))["revision"]
                edit = json.dumps({"edits": [{"old": "## Work\r\nMove this\r\n", "new": ""}]}).encode()
                client("personal", "edit", "Mixed.md", "--if-match", revision, "--file", "-", input=edit)
                self.assertEqual(
                    client("personal", "read", "Mixed.md"),
                    b"Personal fixture\r\n## Personal\r\nKeep this\r\n",
                )
                client("personal", "write", "Mixed.md", "--if-match", revision, input=b"stale", expected=5)
                client("personal", "edit", "Mixed.md", "--old", "missing", "--new", "", expected=6)
                client("personal", "rm", "assets/source.pdf")
                client("personal", "stat", "assets/source.pdf", expected=3)
            finally:
                for process in processes:
                    process.terminate()
                    process.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
