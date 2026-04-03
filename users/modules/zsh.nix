{ pkgs, ... }: {
    imports = [ ./starship.nix ];
    programs.zsh = {
        enable = true;
        enableCompletion = true;
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
            "drs" = "sudo darwin-rebuild switch --flake ~/nix-config#$(scutil --get LocalHostName)";
            "hms" = if pkgs.stdenv.isDarwin then "nix run github:nix-community/home-manager -- switch --flake path:$HOME/nix-config#mpfammatter-darwin -b backup" else "nix run github:nix-community/home-manager -- switch --flake path:$HOME/nix-config#mpfammatter-linux -b backup";
            "nrs" = "sudo nixos-rebuild switch --flake ~/nix-config#$(hostname)";
            "garbage" = "nix-collect-garbage --delete-older-than 7d";
            "iud" = "immich upload --delete ~/Downloads";
        };
    };
}
