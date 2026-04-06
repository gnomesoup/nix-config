{ pkgs, ... }:
{
  imports = [ ./starship.nix ];
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    initContent = ''
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
            "nix run github:nix-community/home-manager -- switch --flake path:$HOME/nix-config#mpfammatter-darwin -b backup"
          else
            "nix run github:nix-community/home-manager -- switch --flake path:$HOME/nix-config#mpfammatter-linux -b backup"
        }
      }
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
      "gs" = "git status";
      "ga" = "git add .";
      "gc" = "git commit";
      "drs" = "sudo darwin-rebuild switch --flake path:$HOME/nix-config#$(scutil --get LocalHostName)";
      "hms" =
        if pkgs.stdenv.isDarwin then
          "nix run github:nix-community/home-manager -- switch --flake path:$HOME/nix-config#mpfammatter-darwin -b backup"
        else
          "nix run github:nix-community/home-manager -- switch --flake path:$HOME/nix-config#mpfammatter-linux -b backup";
      "nrs" = "sudo nixos-rebuild switch --flake path:$HOME/nix-config#$(hostname)";
      "garbage" =
        if pkgs.stdenv.isDarwin then
          "nix-collect-garbage --delete-older-than 7d; sudo nix store optimise"
        else
          "nix-collect-garbage --delete-older-than 7d; sudo nix-collect-garbage --delete-older-than 30d; sudo nix store optimise";
      "iud" = "immich upload --delete ~/Downloads";
      "doco" = "docker compose";
      "docooc" = "docker compose run --rm openclaw-cli";
    };
  };
}
