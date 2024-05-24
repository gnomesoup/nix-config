{ pkgs, vars, ... }:

{
    imports = [ ./modules/appleDefaults.nix ./modules/fonts.nix]

    environment.systemPackages =
        [ pkgs.vim pkgs.git pkgs.nixpkgs-fmt pkgs.raycast ];

    fonts = {
        fontDir.enable = true;
        fonts = with pkgs; [
        source-code-pro
        font-awesome
        ];
    };

    # Necessary for using flakes on this system.
    nix.settings.experimental-features = "nix-command flakes";
    
    services = {
        nix-daemon.enable = true;
        tailscale.enable = true;
    }

    users.users.mpfammatter = {
        name = "mpfammatter";
        home = "/Users/mpfammatter";
    };
}