"""Integration tests for the generated prompts and Zsh width selection.

Run: python3 users/modules/starship_test.py
Builds a minimal Home Manager profile using the repository's locked inputs.
"""

import json
import fcntl
import os
from pathlib import Path
import pty
import pwd
import re
import select
import signal
import socket
import struct
import subprocess
import termios
import tempfile
import time
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[2]


class StarshipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="starship-test-")
        cls.addClassCleanup(cls.scratch.cleanup)
        expression = r'''
          let
            f = builtins.getFlake ROOT;
            pkgs = import f.inputs.nixpkgs { system = builtins.currentSystem; };
            cfg = (f.inputs.home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [ MODULE {
                home.username = "prompt-test";
                home.homeDirectory = HOME;
                home.stateVersion = "25.11";
                programs.zsh.enable = true;
              } ];
            }).config;
          in pkgs.linkFarm "starship-test-configs" (
            [
              { name = "wide.toml";
                path = cfg.home.file.${cfg.programs.starship.configPath}.source; }
              { name = "init.zsh";
                path = pkgs.writeText "starship-init.zsh" cfg.programs.zsh.initContent; }
              { name = "starship"; path = pkgs.lib.getExe cfg.programs.starship.package; }
            ] ++ pkgs.lib.mapAttrsToList (name: value: {
              inherit name; path = value.source;
            }) cfg.xdg.configFile
          )
        '''.replace("ROOT", json.dumps(str(ROOT))).replace(
            "MODULE", str(ROOT / "users/modules/starship.nix")
        ).replace("HOME", json.dumps(cls.scratch.name))
        result = subprocess.run(
            ["nix", "build", "--impure", "--expr", expression,
             "--no-link", "--print-out-paths"],
            text=True, capture_output=True, check=True,
        )
        cls.artifacts = Path(result.stdout.strip())
        cls.project = Path(cls.scratch.name) / "work" / "projects" / "nix-config"
        cls.project.mkdir(parents=True)
        for args in (
            ["init", "-b", "feature/a-very-long-branch-name-for-narrow-windows"],
            ["-c", "user.name=Prompt Test", "-c", "user.email=test@example.invalid",
             "commit", "--allow-empty", "-m", "fixture"],
            ["branch", "upstream"],
            ["branch", "--set-upstream-to=upstream"],
            ["-c", "user.name=Prompt Test", "-c", "user.email=test@example.invalid",
             "commit", "--allow-empty", "-m", "ahead"],
        ):
            subprocess.run(["git", "-C", str(cls.project), *args],
                           capture_output=True, check=True)
        (cls.project / "untracked").touch()

    def render(self, width, logical_path=None, keymap="vicmd", status=1, **environment):
        name = ("starship-minimal.toml" if width < 70 else
                "starship-compact.toml" if width < 110 else "wide.toml")
        env = {**os.environ, "STARSHIP_CONFIG": str(self.artifacts / name),
               "STARSHIP_SHELL": "zsh", "TERM": "xterm-256color",
               "USER": pwd.getpwuid(os.getuid()).pw_name,
               "LOGNAME": pwd.getpwuid(os.getuid()).pw_name}
        for variable in ("SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY", "VIRTUAL_ENV",
                         "CONDA_DEFAULT_ENV", "IN_NIX_SHELL", "name"):
            env.pop(variable, None)
        env.update(environment)
        command = [str(self.artifacts / "starship"), "prompt", "--terminal-width", str(width),
                   "--path", str(self.project), "--status", str(status), "--keymap", keymap]
        if logical_path is not None:
            command.extend(["--logical-path", logical_path])
        result = subprocess.run(
            command,
            env=env, text=True, capture_output=True, check=True,
        )
        self.assertEqual(result.stderr, "")
        plain = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout)
        return result.stdout, plain.replace("%{", "").replace("%}", "")

    def test_width_layouts_are_generated(self):
        for name in ("wide.toml", "starship-compact.toml", "starship-minimal.toml"):
            with self.subTest(name=name):
                self.assertTrue((self.artifacts / name).is_file(), name)

    def test_zsh_selects_layout_at_boundaries(self):
        script = '''
          source "$1"
          for width in 40 60 69 70 80 100 109 110 120; do
            COLUMNS=$width
            _inigo_starship_select
            print -r -- "$width:${STARSHIP_CONFIG:t}"
          done
        '''
        result = subprocess.run(
            ["zsh", "-dfc", script, "test", str(self.artifacts / "init.zsh")],
            env={**os.environ, "TERM": "xterm-256color"},
            text=True, capture_output=True, check=True,
        )
        self.assertEqual(result.stderr, "")
        for line in result.stdout.splitlines():
            width, name = line.split(":", 1)
            expected = ("minimal" if int(width) < 70 else
                        "compact" if int(width) < 110 else "config")
            self.assertIn(expected, name, line)

    def test_rendered_prompts_fit_and_keep_git_and_vim_state(self):
        for width in (40, 60, 80, 100, 120):
            with self.subTest(width=width):
                colored, plain = self.render(width)
                lines = plain.strip().splitlines()
                self.assertEqual(lines[-1], "")
                self.assertIn("feature", plain)
                self.assertIn("?", plain)
                self.assertIn("⇡", plain)
                self.assertIn("nix-config", plain)
                self.assertTrue(all(len(line) < width for line in lines), repr(plain))
                self.assertIn("", plain)
                self.assertIn("", plain)
                self.assertIn("", plain)
                # The normal and error symbols, and all Vim modes, share settings.
                name = ("starship-minimal.toml" if width < 70 else
                        "starship-compact.toml" if width < 110 else "wide.toml")
                settings = tomllib.loads((self.artifacts / name).read_text())
                self.assertIn("color_red", settings["character"]["error_symbol"])
                self.assertIn("color_red", settings["username"]["style_root"])

    def test_ssh_identity_and_active_environments(self):
        for width in (40, 80, 120):
            _, plain = self.render(width, SSH_CONNECTION="192.0.2.1 1234 192.0.2.2 22",
                                   IN_NIX_SHELL="pure", name="dev", VIRTUAL_ENV="/envs/test")
            self.assertIn(pwd.getpwuid(os.getuid()).pw_name, plain)
            if width >= 110:
                self.assertIn("dev", plain)
                self.assertIn("test", plain)

    def test_deep_paths_are_truncated_not_all_ancestors_abbreviated(self):
        path = ("/work/projects/company/platform/infrastructure/production/regions/"
                "us-east/services/backend/application/long-project-name")
        for width in (40, 80):
            with self.subTest(width=width):
                _, plain = self.render(width, logical_path=path)
                self.assertIn("long-project-name", plain)
                self.assertTrue(all(len(line) < width for line in plain.splitlines()),
                                repr(plain))


    def test_actual_insert_mode_error_and_success_colors(self):
        for width in (40, 80, 120):
            for status, color in ((1, "224;33;29"), (0, "82;173;112")):
                with self.subTest(width=width, status=status):
                    colored, plain = self.render(width, keymap="viins", status=status)
                    self.assertEqual(plain.strip().splitlines()[-1], "")
                    self.assertIn(f"38;2;{color}", colored.rstrip("\n").split("\n")[-1])

    def test_wide_prompt_retains_original_format_and_unbounded_branch(self):
        settings = tomllib.loads((self.artifacts / "wide.toml").read_text())
        original_format = (
            "[](color_yellow)$os$hostname[](fg:color_yellow bg:color_purple2)"
            "$username[](fg:color_purple2 bg:color_bg3)$directory"
            "[](fg:color_bg3 bg:color_bg1)$git_branch$git_status"
            "[](fg:color_bg1 bg:color_blue)$c$cpp$rust$golang$nodejs$php$java$kotlin$haskell$python"
            "[](fg:color_blue bg:color_bg1)$nix_shell$conda"
            "[](fg:color_bg1 bg:color_purple2)$time[ ](fg:color_purple2)$line_break$character\n"
        )
        self.assertEqual(settings["format"], original_format)
        self.assertNotIn("truncation_length", settings["git_branch"])
        self.assertNotIn("truncate_to_repo", settings["directory"])

    def test_narrow_prompts_keep_os_hostname_and_original_colors(self):
        for width in (40, 60, 80, 100):
            colored, plain = self.render(width)
            settings = tomllib.loads((self.artifacts /
                ("starship-minimal.toml" if width < 70 else "starship-compact.toml")).read_text())
            self.assertIn(socket.gethostname().split(".")[0], plain)
            self.assertTrue(any(icon in plain for icon in settings["os"]["symbols"].values()))
            self.assertIn("48;2;209;149;29", colored)
            self.assertIn("48;2;52;50;62", colored)
            self.assertIn("", plain)
            self.assertIn("", plain)
            self.assertIn("", plain)

    def test_narrow_environment_indicators_are_icons_not_names(self):
        for width in (40, 80):
            _, baseline = self.render(width)
            for _, plain in (
                self.render(width, VIRTUAL_ENV="/envs/distinctive-python-environment"),
                self.render(width, CONDA_DEFAULT_ENV="distinctive-conda-environment"),
            ):
                self.assertEqual(plain.count(""), baseline.count("") + 1)
                self.assertNotIn("distinctive", plain)
            _, plain = self.render(width, IN_NIX_SHELL="pure", name="distinctive-nix-environment")
            self.assertEqual(plain.count(""), baseline.count("") + 1)
            self.assertNotIn("distinctive", plain)

    def test_selector_preserves_starship_status_and_hook_order(self):
        script = '''
          source "$1"
          print -r -- "ORDER:$precmd_functions"
          prompt_starship_preexec
          false
          prompt_starship_precmd
          COLUMNS=40
          _inigo_starship_select
          print -r -- "STATUS:$STARSHIP_CMD_STATUS PIPE:$STARSHIP_PIPE_STATUS"
        '''
        result = subprocess.run(
            ["zsh", "-dfc", script, "test", str(self.artifacts / "init.zsh")],
            env={**os.environ, "TERM": "xterm-256color"},
            text=True, capture_output=True, check=True,
        )
        self.assertEqual(result.stderr, "")
        self.assertIn("prompt_starship_precmd _inigo_starship_select", result.stdout)
        self.assertIn("STATUS:1 PIPE:1", result.stdout)

    def test_live_resize_preserves_input_and_selects_before_execution(self):
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.project)
            os.environ.update(TERM="xterm-256color", HOME=self.scratch.name)
            os.execvp("zsh", ["zsh", "-dfi"])

        pending = b""

        def read_until(marker, timeout=8):
            nonlocal pending
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if marker in pending:
                    end = pending.index(marker) + len(marker)
                    output, pending = pending[:end], pending[end:]
                    return output
                ready, _, _ = select.select([fd], [], [], 0.1)
                if ready:
                    pending += os.read(fd, 65536)
            self.fail(f"PTY did not produce {marker!r}: {pending!r}")

        def resize(width):
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, width, 0, 0))
            os.kill(pid, signal.SIGWINCH)

        try:
            resize(120)
            os.write(fd, f"bindkey -v; KEYTIMEOUT=1; source {self.artifacts}/init.zsh\n".encode())
            read_until("".encode())
            for width, expected in ((40, b"minimal"), (80, b"compact"), (120, b"config")):
                os.write(fd, b"false\n")
                failure_prompt = read_until("".encode())
                self.assertIn(b"38;2;224;33;29", failure_prompt)
                os.write(fd, b"\x1b")
                read_until("".encode())
                os.write(fd, b"i")
                insert_prompt = read_until("".encode())
                self.assertIn(b"38;2;224;33;29", insert_prompt)
                # Leave a command in the editor while resizing; read STARSHIP_CONFIG
                # before the next precmd can mask a missed live resize.
                os.write(fd, b"print -r -- BUFFER_OK:$STARSHIP_CONFIG")
                resize(width)
                resized_prompt = read_until("".encode())
                self.assertIn(b"38;2;224;33;29", resized_prompt)
                os.write(fd, b"\n")
                output = read_until(b"BUFFER_OK:/nix/store/")
                output += read_until(b"\n")
                self.assertIn(expected, output.split(b"BUFFER_OK:/nix/store/", 1)[1])
                read_until("".encode())
            os.write(fd, b"true | false\n")
            failure_prompt = read_until("".encode())
            self.assertIn(b"38;2;224;33;29", failure_prompt)
            os.write(fd, b'print -r -- "PIPELINE:$STARSHIP_CMD_STATUS:$STARSHIP_PIPE_STATUS"\n')
            read_until(b"PIPELINE:1:0 1")
            read_until("".encode())
        finally:
            os.kill(pid, signal.SIGTERM)
            os.close(fd)
            os.waitpid(pid, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
