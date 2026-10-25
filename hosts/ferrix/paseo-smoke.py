"""Exercise the packaged Paseo daemon without user credentials or model calls."""

import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request


def main():
    executable, template, output = sys.argv[1:]
    root = Path(os.environ["TMPDIR"]) / "paseo-smoke"
    home = root / "home"
    state = home / ".paseo-test"
    state.mkdir(parents=True)
    pi_settings = home / ".pi/agent/settings.json"
    pi_settings.parent.mkdir(parents=True)
    pi_settings.write_text(json.dumps({"packages": []}))
    shutil.copyfile(template, state / "config.json")
    settings = json.loads(Path(template).read_text())
    assert settings["daemon"]["relay"]["enabled"] is False
    assert settings["pluginsEnabled"] is False
    assert settings["agents"]["providers"]["pi"]["enabled"] is True

    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    password = secrets.token_urlsafe(32)
    env = {
        **os.environ,
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "PASEO_HOME": str(state),
        "PASEO_LISTEN": f"127.0.0.1:{port}",
        "PASEO_RELAY_ENABLED": "false",
        "PASEO_PASSWORD": password,
        "PI_OFFLINE": "1",
    }
    base = f"http://127.0.0.1:{port}"

    def request(path, token=None):
        headers = {} if token is None else {"Authorization": f"Bearer {token}"}
        try:
            with urllib.request.urlopen(
                urllib.request.Request(base + path, headers=headers), timeout=2
            ) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code

    with (root / "daemon.log").open("w") as log:
        daemon = subprocess.Popen(
            [executable, "daemon", "run"],
            env=env,
            cwd=home,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            deadline = time.monotonic() + 60
            while True:
                assert daemon.poll() is None, "Paseo exited before becoming healthy"
                try:
                    if request("/api/health") == 200:
                        break
                except (OSError, urllib.error.URLError):
                    pass
                assert time.monotonic() < deadline, "Paseo startup timed out"
                time.sleep(0.25)

            assert request("/api/status") == 401, "Unauthenticated access was accepted"
            assert request("/api/status", "incorrect-password") == 401
            assert request("/api/status", password) == 200
            # HTTP liveness precedes WebSocket readiness during daemon startup.
            deadline = time.monotonic() + 60
            while True:
                result = subprocess.run(
                    [executable, "--host", f"127.0.0.1:{port}", "--json", "provider", "ls"],
                    env=env,
                    cwd=home,
                    capture_output=True,
                    text=True,
                    timeout=90,
                )
                if result.returncode == 0:
                    providers = json.loads(result.stdout)
                    pi = next(entry for entry in providers if entry["provider"] == "pi")
                    if pi["status"] != "loading":
                        break
                    assert time.monotonic() < deadline, "Pi provider readiness timed out"
                    time.sleep(0.25)
                    continue
                if "Unexpected server response: 503" not in result.stderr:
                    break
                assert time.monotonic() < deadline, "Paseo WebSocket readiness timed out"
                time.sleep(0.25)
            assert result.returncode == 0, (
                "Authenticated Paseo WebSocket CLI failed: "
                + result.stderr.replace(password, "[redacted]")
            )
            providers = json.loads(result.stdout)
            pi = next(entry for entry in providers if entry["provider"] == "pi")
            assert pi["enabled"] == "Enabled", pi
            assert pi["status"] == "available", pi
            summary = {
                "health": "passed",
                "unauthenticated_access": "rejected",
                "incorrect_password": "rejected",
                "authenticated_http": "passed",
                "authenticated_websocket": "passed",
                "pi_provider": pi["status"],
                "relay_enabled": False,
            }
            Path(output).write_text(json.dumps(summary, indent=2) + "\n")
            print(json.dumps(summary, indent=2))
        finally:
            os.killpg(daemon.pid, 15)
            try:
                daemon.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(daemon.pid, 9)
                daemon.wait(timeout=5)


if __name__ == "__main__":
    main()
