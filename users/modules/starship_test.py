"""Real Starship/Zsh integration tests: python3 users/modules/starship_test.py."""

import ctypes
import fcntl
import json
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
import tempfile
import termios
import time
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[2]
LAYOUTS = {
    "full": "wide.toml",
    "no-time": "starship-no-time.toml",
    "no-username": "starship-no-username.toml",
    "path-below": "starship-path-below.toml",
}


def plain(text):
    return re.sub(r"\x1b\[[0-9;]*m", "", text).replace("%{", "").replace("%}", "")


def line_width(text):
    # Use the same locale-aware display-cell accounting as Zsh, not Python len().
    libc = ctypes.CDLL(None)
    libc.wcswidth.argtypes = [ctypes.c_wchar_p, ctypes.c_size_t]
    return libc.wcswidth(text, len(text))


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
            ["init", "-b", "main"],
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

    def environment(self, **changes):
        env = {**os.environ, "STARSHIP_SHELL": "zsh", "TERM": "xterm-256color",
               "HOME": self.scratch.name, "PWD": str(self.project),
               "USER": pwd.getpwuid(os.getuid()).pw_name,
               "LOGNAME": pwd.getpwuid(os.getuid()).pw_name}
        for variable in ("SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY", "VIRTUAL_ENV",
                         "CONDA_DEFAULT_ENV", "IN_NIX_SHELL", "name"):
            env.pop(variable, None)
        return {**env, **changes}

    def render(self, layout, width=4096, keymap="viins", status=0, environment=None):
        env = self.environment(STARSHIP_CONFIG=str(self.artifacts / LAYOUTS[layout]),
                               **(environment or {}))
        result = subprocess.run(
            [str(self.artifacts / "starship"), "prompt", "--terminal-width", str(width),
             "--path", str(self.project), "--status", str(status), "--keymap", keymap],
            env=env, text=True, capture_output=True, check=True,
        )
        self.assertEqual(result.stderr, "")
        return result.stdout

    def shell(self, script, *arguments, **environment):
        result = subprocess.run(
            ["zsh", "-dfc", script, "test", str(self.artifacts / "init.zsh"),
             *map(str, arguments)], cwd=self.project,
            env=self.environment(**environment), text=True, capture_output=True, check=True,
        )
        self.assertEqual(result.stderr, "")
        return result.stdout

    def selected(self, width, **environment):
        return self.shell('''
          COLUMNS=$2
          source "$1"
          _inigo_starship_select
          print -r -- "$_inigo_starship_layout"
        ''', width, **environment).strip()

    def widths(self, **environment):
        return {layout: max(map(line_width, plain(self.render(layout, environment=environment)).splitlines()))
                for layout in LAYOUTS}

    def settings(self, layout):
        return tomllib.loads((self.artifacts / LAYOUTS[layout]).read_text())

    def test_four_progressive_layouts_are_generated(self):
        for name in LAYOUTS.values():
            with self.subTest(name=name):
                self.assertTrue((self.artifacts / name).is_file(), name)

    def test_only_requested_fields_change_at_each_stage(self):
        full = self.settings("full")
        no_time = self.settings("no-time")
        no_username = self.settings("no-username")
        path_below = self.settings("path-below")
        expected = {**full, "time": {**full["time"], "disabled": True}}
        self.assertEqual(no_time, expected)
        expected = {**expected, "username": {**full["username"], "format": "[ ]($style)"}}
        self.assertEqual(no_username, expected)
        self.assertEqual({k: v for k, v in path_below.items() if k != "format"},
                         {k: v for k, v in no_username.items() if k != "format"})
        # Git, runtimes, and environments never move to another line or reorder.
        expected_format = full["format"].replace("$directory", "[ ](bg:color_bg3 fg:color_purple)")
        expected_format = expected_format.replace(
            "$line_break$character", "$line_break$directory$line_break$character")
        self.assertEqual(path_below["format"], expected_format)

    def test_selection_uses_actual_width_and_order_not_fixed_breakpoints(self):
        widths = self.widths()
        self.assertGreater(widths["full"], widths["no-time"])
        self.assertGreater(widths["no-time"], widths["no-username"])
        cases = ((widths["full"] + 1, "full"),
                 (widths["full"], "no-time"),
                 (widths["no-time"], "no-username"),
                 (widths["no-username"], "path-below"))
        for columns, expected in cases:
            with self.subTest(columns=columns):
                self.assertEqual(self.selected(columns), expected)

    def test_environment_contents_affect_selection_without_losing_information(self):
        columns = self.widths()["full"] + 1
        self.assertEqual(self.selected(columns), "full")
        environment = {"IN_NIX_SHELL": "pure", "name": "a-long-active-nix-environment"}
        widths = self.widths(**environment)
        expected = next((stage for stage in ("full", "no-time", "no-username")
                         if widths[stage] < columns), "path-below")
        self.assertNotEqual(expected, "full")
        self.assertEqual(self.selected(columns, **environment), expected)
        for stage in LAYOUTS:
            self.assertIn("a-long-active-nix-environment", plain(self.render(stage, environment=environment)))

    def test_width_measurement_handles_ansi_unicode_and_exact_boundary(self):
        result = self.shell(r'''
          COLUMNS=5
          source "$1"
          for text in abc abcde '界界' '界界界' $'%{\e[31m%}abc%{\e[0m%}'; do
            if _inigo_starship_fits "$text"; then print fits; else print overflow; fi
          done
        ''')
        self.assertEqual(result.splitlines(), ["fits", "overflow", "fits", "overflow", "fits"])

    def test_path_only_moves_below_after_both_reductions(self):
        username = pwd.getpwuid(os.getuid()).pw_name
        for stage in LAYOUTS:
            lines = [line for line in plain(self.render(stage)).splitlines() if line.strip()]
            if stage == "path-below":
                self.assertEqual(len(lines), 3)
                self.assertNotIn("nix-config", lines[0])
                self.assertIn("main", lines[0])
                self.assertIn("nix-config", lines[1])
                self.assertNotIn("main", lines[1])
            else:
                self.assertEqual(len(lines), 2)
                self.assertIn("nix-config", lines[0])
                self.assertLess(lines[0].index("nix-config"), lines[0].index("main"))
            self.assertIn(socket.gethostname().split(".")[0], lines[0])
            self.assertIn("", lines[0]) if stage == "full" else self.assertNotIn("", lines[0])
            if stage in ("full", "no-time"):
                self.assertIn(username, lines[0])
            else:
                self.assertNotIn(username, lines[0])
            self.assertEqual(lines[0].count(""), 6)
            self.assertIn(" ", lines[0]) if stage in ("no-username", "path-below") else None
            self.assertEqual(lines[-1].strip(), "")

    def test_width_measurement_does_not_execute_text_or_change_shell_options(self):
        result = self.shell('''
          COLUMNS=80
          source "$1"
          text='$(touch unexpected-prompt-command)'
          _inigo_starship_fits "$text"
          print -r -- "COLUMNS:$COLUMNS SUBST:$options[promptsubst]"
        ''')
        self.assertFalse((self.project / "unexpected-prompt-command").exists())
        self.assertIn("COLUMNS:80 SUBST:on", result)

    def test_wide_prompt_retains_original_format_and_unbounded_branch(self):
        settings = self.settings("full")
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

    def test_colors_os_git_and_vim_states_survive_all_stages(self):
        for stage in LAYOUTS:
            for status, keymap, glyph, color in (
                (0, "viins", "", "82;173;112"),
                (1, "viins", "", "224;33;29"),
                (1, "vicmd", "", "82;173;112"),
            ):
                with self.subTest(stage=stage, status=status, keymap=keymap):
                    rendered = self.render(stage, status=status, keymap=keymap)
                    text = plain(rendered)
                    self.assertIn("48;2;209;149;29", rendered)
                    self.assertIn("48;2;52;50;62", rendered)
                    self.assertTrue(any(icon in text for icon in self.settings(stage)["os"]["symbols"].values()))
                    self.assertIn("?", text)
                    self.assertIn("⇡", text)
                    self.assertEqual(text.strip().splitlines()[-1], glyph)
                    self.assertIn(f"38;2;{color}", rendered.rstrip("\n").split("\n")[-1])

    def test_selector_preserves_starship_status_and_hook_order(self):
        result = self.shell('''
          COLUMNS=80
          source "$1"
          print -r -- "ORDER:$precmd_functions"
          prompt_starship_preexec
          true | false
          prompt_starship_precmd
          _inigo_starship_select
          print -r -- "STATUS:$STARSHIP_CMD_STATUS PIPE:$STARSHIP_PIPE_STATUS"
        ''')
        self.assertIn("prompt_starship_precmd _inigo_starship_select", result)
        self.assertIn("STATUS:1 PIPE:0 1", result)

    def test_live_resize_preserves_buffer_status_and_vim_modes(self):
        widths = self.widths()
        cases = ((widths["full"] + 1, "full"), (widths["full"], "no-time"),
                 (widths["no-time"], "no-username"),
                 (widths["no-username"], "path-below"), (widths["full"] + 1, "full"))
        pid, fd = pty.fork()
        if pid == 0:
            try:
                os.chdir(self.project)
                os.execvpe("zsh", ["zsh", "-dfi"], self.environment(HOME=self.scratch.name))
            except BaseException:
                # Never unwind unittest in the child and delete the parent's fixture.
                os._exit(127)
        pending = b""

        def read_until(marker, timeout=12):
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
            resize(4096)
            os.write(fd, f"bindkey -v; KEYTIMEOUT=1; source {self.artifacts}/init.zsh\n".encode())
            read_until("".encode())
            for columns, expected in cases:
                os.write(fd, b"false\n")
                self.assertIn(b"38;2;224;33;29", read_until("".encode()))
                os.write(fd, b"\x1b")
                read_until("".encode())
                os.write(fd, b"i")
                self.assertIn(b"38;2;224;33;29", read_until("".encode()))
                os.write(fd, b'print -r -- BUFFER_"OK":$_inigo_starship_layout')
                resize(columns)
                self.assertIn(b"38;2;224;33;29", read_until("".encode()))
                os.write(fd, b"\n")
                output = read_until(b"BUFFER_OK:") + read_until(b"\n")
                self.assertIn(b"BUFFER_OK:" + expected.encode(), output)
                read_until("".encode())
            os.write(fd, b"true | false\n")
            self.assertIn(b"38;2;224;33;29", read_until("".encode()))
            os.write(fd, b'print -r -- "PIPELINE:$STARSHIP_CMD_STATUS:$STARSHIP_PIPE_STATUS"\n')
            read_until(b"PIPELINE:1:0 1")
            read_until("".encode())
        finally:
            os.kill(pid, signal.SIGTERM)
            os.close(fd)
            os.waitpid(pid, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
