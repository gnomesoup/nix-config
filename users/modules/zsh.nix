{ pkgs, config, ... }:
let
  keys = config.vimBindingKeys;
  optimiseNixStore = ''
    if grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease /proc/version 2>/dev/null; then
      echo 'Skipping nix store optimisation on WSL'
    else
      sudo nix store optimise
    fi
  '';
in
{
  imports = [ ./starship.nix ];

  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
    options = [
      "--cmd"
      "cd"
    ];
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    initContent = ''
      ${
        if pkgs.stdenv.isDarwin then
          ''
            if command -v ssh-add >/dev/null 2>&1; then
              ssh-add --apple-load-keychain >/dev/null 2>&1 || true
            fi
          ''
        else
          ""
      }

      bindkey -v
      zmodload -i zsh/complist

      bindkey -rM vicmd h
      bindkey -rM vicmd j
      bindkey -rM vicmd k
      bindkey -rM vicmd l
      bindkey -rM vicmd i
      bindkey -rM vicmd I
      bindkey -rM vicmd e
      bindkey -rM vicmd E
      bindkey -rM vicmd f
      bindkey -rM vicmd F
      bindkey -rM vicmd t
      bindkey -rM vicmd T
      bindkey -rM vicmd n
      bindkey -rM vicmd N
      bindkey -rM vicmd m
      bindkey -rM vicmd J
      bindkey -M vicmd '${keys.left}' vi-backward-char
      bindkey -M vicmd '${keys.down}' vi-down-line-or-history
      bindkey -M vicmd '${keys.up}' vi-up-line-or-history
      bindkey -M vicmd '${keys.right}' vi-forward-char
      bindkey -M vicmd '${keys.insert}' vi-insert
      bindkey -M vicmd '${keys.insertLineStart}' vi-insert-bol
      bindkey -M vicmd '${keys.wordEnd}' vi-forward-word-end
      bindkey -M vicmd '${keys.WORDend}' vi-forward-blank-word-end
      bindkey -M vicmd '${keys.findForward}' vi-find-next-char
      bindkey -M vicmd '${keys.findBackward}' vi-find-prev-char
      bindkey -M vicmd '${keys.tillForward}' vi-find-next-char-skip
      bindkey -M vicmd '${keys.tillBackward}' vi-find-prev-char-skip
      bindkey -M vicmd '${keys.searchNext}' vi-repeat-search
      bindkey -M vicmd '${keys.searchPrev}' vi-rev-repeat-search
      bindkey -M vicmd '${keys.setMark}' vi-set-mark
      bindkey -M vicmd '${keys.joinLines}' vi-join

      bindkey -rM visual h
      bindkey -rM visual j
      bindkey -rM visual k
      bindkey -rM visual l
      bindkey -rM visual e
      bindkey -rM visual E
      bindkey -rM visual f
      bindkey -rM visual F
      bindkey -rM visual t
      bindkey -rM visual T
      bindkey -M visual '${keys.left}' backward-char
      bindkey -M visual '${keys.down}' down-line
      bindkey -M visual '${keys.up}' up-line
      bindkey -M visual '${keys.right}' forward-char
      bindkey -M visual '${keys.wordEnd}' vi-forward-word-end
      bindkey -M visual '${keys.WORDend}' vi-forward-blank-word-end
      bindkey -M visual '${keys.findForward}' vi-find-next-char
      bindkey -M visual '${keys.findBackward}' vi-find-prev-char
      bindkey -M visual '${keys.tillForward}' vi-find-next-char-skip
      bindkey -M visual '${keys.tillBackward}' vi-find-prev-char-skip

      bindkey -rM viopp h
      bindkey -rM viopp j
      bindkey -rM viopp k
      bindkey -rM viopp l
      bindkey -rM viopp e
      bindkey -rM viopp E
      bindkey -rM viopp f
      bindkey -rM viopp F
      bindkey -rM viopp t
      bindkey -rM viopp T
      bindkey -rM viopp n
      bindkey -rM viopp N
      bindkey -M viopp '${keys.left}' backward-char
      bindkey -M viopp '${keys.down}' down-line
      bindkey -M viopp '${keys.up}' up-line
      bindkey -M viopp '${keys.right}' forward-char
      bindkey -M viopp '${keys.wordEnd}' vi-forward-word-end
      bindkey -M viopp '${keys.WORDend}' vi-forward-blank-word-end
      bindkey -M viopp '${keys.findForward}' vi-find-next-char
      bindkey -M viopp '${keys.findBackward}' vi-find-prev-char
      bindkey -M viopp '${keys.tillForward}' vi-find-next-char-skip
      bindkey -M viopp '${keys.tillBackward}' vi-find-prev-char-skip
      bindkey -M viopp '${keys.searchNext}' vi-repeat-search
      bindkey -M viopp '${keys.searchPrev}' vi-rev-repeat-search

      bindkey -rM menuselect h
      bindkey -rM menuselect j
      bindkey -rM menuselect k
      bindkey -rM menuselect l
      bindkey -M menuselect '${keys.left}' backward-char
      bindkey -M menuselect '${keys.down}' down-line-or-history
      bindkey -M menuselect '${keys.up}' up-line-or-history
      bindkey -M menuselect '${keys.right}' forward-char

      hms-kbl() {
        emulate -L zsh

        local layout="$1"
        local config_file="$HOME/nix-config/users/modules/vimBindingKeyboardLayout.nix"
        local target_line
        target_line='vimBindingKeyboardLayout = lib.mkDefault "'

        if [[ -z "$layout" ]]; then
          local choice
          print "Select Vim binding keyboard layout:"
          select choice in qwerty colemak-dh; do
            if [[ -n "$choice" ]]; then
              layout="$choice"
              break
            fi
            print "Invalid selection"
          done
        fi

        case "$layout" in
          qwerty|colemak-dh) ;;
          *)
            print -u2 "Usage: hms-kbl [qwerty|colemak-dh]"
            return 1
            ;;
        esac

        if [[ ! -f "$config_file" ]]; then
          print -u2 "Missing config file: $config_file"
          return 1
        fi

        perl -0pi -e 's/vimBindingKeyboardLayout = lib\.mkDefault "(?:qwerty|colemak-dh)"; # managed by hms-kbl/vimBindingKeyboardLayout = lib.mkDefault "'"$layout"'"; # managed by hms-kbl/' "$config_file"

        if ! grep -q "vimBindingKeyboardLayout = lib.mkDefault \"$layout\"; # managed by hms-kbl" "$config_file"; then
          print -u2 "Failed to update $config_file"
          return 1
        fi

        ${
          if pkgs.stdenv.isDarwin then
            "sudo darwin-rebuild switch --flake path:$HOME/nix-config#$(scutil --get LocalHostName)"
          else
            "nix run github:nix-community/home-manager -- switch --flake path:$HOME/nix-config#mpfammatter-linux -b backup"
        }
      }

      openclaw-refresh-completion() {
        emulate -L zsh

        if ! command -v openclaw >/dev/null 2>&1; then
          print -u2 "openclaw is not installed"
          return 1
        fi

        openclaw completion --shell zsh --write-state
      }

      nix-shell() {
        emulate -L zsh

        local arg
        for arg in "$@"; do
          case "$arg" in
            --run|--command|-r)
              command nix-shell "$@"
              return
              ;;
          esac
        done

        command nix-shell "$@" --run 'exec zsh -i'
      }

      nd() {
        emulate -L zsh
        nix develop "$@" --command zsh
      }

      if command -v opencode >/dev/null 2>&1; then
        source <(opencode completion)
      fi

      if command -v openclaw >/dev/null 2>&1; then
        local openclaw_state_dir="''${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
        local openclaw_completion_file="$openclaw_state_dir/completions/openclaw.zsh"

        if [[ -f "$openclaw_completion_file" ]]; then
          source "$openclaw_completion_file"
        fi
      fi

      if [[ -d /proc/sys/fs/binfmt_misc ]] && [[ -f /proc/sys/fs/binfmt_misc/WSLInterop || -n "$WSL_DISTRO_NAME" ]]; then
        if command -v wslpath >/dev/null 2>&1 && command -v powershell.exe >/dev/null 2>&1; then
          cdw() {
            emulate -L zsh
            local win_path
            win_path="$(powershell.exe -c "[Environment]::GetEnvironmentVariable('USERPROFILE','User')" 2>/dev/null)" || {
              echo "cdw: failed to get Windows USERPROFILE" >&2
              return 1
            }
            local wsl_path
            wsl_path="$(wslpath "$win_path" 2>/dev/null)" || {
              echo "cdw: failed to convert path '$win_path'" >&2
              return 1
            }
            cd "$wsl_path"
          }
        fi
      fi

      if [[ "$TERM_PROGRAM" == "WezTerm" ]] && command -v wezterm >/dev/null 2>&1; then
        autoload -Uz add-zsh-hook

        __wezterm_set_user_var() {
          emulate -L zsh

          if ! command -v base64 >/dev/null 2>&1; then
            return
          fi

          local name="$1"
          local value="$2"
          local encoded_value
          encoded_value="$(printf '%s' "$value" | base64 | tr -d '\n')"
          printf '\033]1337;SetUserVar=%s=%s\007' "$name" "$encoded_value"
        }

        __wezterm_prompt_cwd() {
          emulate -L zsh

          wezterm set-working-directory "$PWD"

          local git_root=""
          if git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
            :
          else
            git_root=""
          fi

          __wezterm_set_user_var git_root "$git_root"
        }

        add-zsh-hook precmd __wezterm_prompt_cwd
      fi
    '';
    shellAliases = {
      "ls" = "ls --color=auto";
      "grep" = "grep --color=auto";
      "fgrep" = "fgrep --color=auto";
      "egrep" = "egrep --color=auto";
      "diff" = "diff --color=auto";
      "less" = "less -R";
      "more" = "less -R";
      "ll" = "ls -lah --color=auto";
      "z" = "cd";
      "gs" = "git status";
      "ga" = "git add .";
      "gc" = "git commit";
      "gp" = "git pull origin";
      "gP" = "git push origin";
      "gl" = "git log --oneline";
      "glg" = "git log --graph --oneline";
      "glp" =
        "git log --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit";
      "apply" =
        if pkgs.stdenv.isDarwin then
          "sudo darwin-rebuild switch --flake path:$HOME/nix-config#$(scutil --get LocalHostName)"
        else
          "nix run github:nix-community/home-manager -- switch --flake path:$HOME/nix-config#mpfammatter-linux -b backup";
      "drs" = "sudo darwin-rebuild switch --flake path:$HOME/nix-config#$(scutil --get LocalHostName)";
      "hms" =
        if pkgs.stdenv.isDarwin then
          "sudo darwin-rebuild switch --flake path:$HOME/nix-config#$(scutil --get LocalHostName)"
        else
          "nix run github:nix-community/home-manager -- switch --flake path:$HOME/nix-config#mpfammatter-linux -b backup";
      "nrs" = "sudo nixos-rebuild switch --flake path:$HOME/nix-config#$(hostname)";
      "garbage" =
        if pkgs.stdenv.isDarwin then
          "nix-collect-garbage --delete-older-than 7d; sudo nix store optimise"
        else
          "nix-collect-garbage --delete-older-than 7d; sudo nix-collect-garbage --delete-older-than 30d; ${optimiseNixStore}";
      "iud" = "immich upload --delete ~/Downloads";
      "doco" = "docker compose";
      "docooc" = "docker compose run --rm openclaw-cli";
      "wz" = "wezterm";
      "wzc" = "wezterm cli";
    };
  };
}
