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
            "drs" = "darwin-rebuild switch --flake ~/nix-config#$(scutil --get LocalHostName)";
            "nrs" = "sudo nixos-rebuild switch --flake ~/nix-config#$(hostname)";
        };
    };
}