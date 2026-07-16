{
  pkgs,
  vars,
  self,
  ...
}:

{
  imports = [
    ../modules/appleDefaults.nix
    ../modules/default-zsh.nix
    ../modules/fonts.nix
    ../modules/homebrew.nix
  ];

  environment.systemPackages = with pkgs; [
    vim
    git
    python3
    nixpkgs-fmt
    raycast
    utm
    borgbackup
    sops
    age
  ];

  # Necessary for using flakes on this system.
  nix.enable = false;
  nix.settings.experimental-features = "nix-command flakes";
  nix.settings.download-buffer-size = 524288000;

  # nix.settings.extra-nix-path = "nixpkgs=flake:nixpkgs";

  system.configurationRevision = self.rev or self.dirtyRev or null;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 5;

  system.primaryUser = "mpfammatter";

  system.defaults.CustomUserPreferences."com.github.InputLeap" = {
    autoHide = true;
    autoStart = true;
    configFile = "/Users/mpfammatter/.config/InputLeap/input-leap.conf";
    groupClientChecked = false;
    groupServerChecked = true;
    minimizeToTray = true;
    screenName = "exegol.local";
    startedBefore = true;
    useExternalConfig = true;
    useInternalConfig = false;
    wizardLastRun = 9;
  };

  # The platform the configuration will be used on.
  nixpkgs = {
    hostPlatform = "aarch64-darwin";
    config.allowUnfree = true;
    # Logseq currently depends on Electron 39, which is EOL in nixpkgs.
    config.permittedInsecurePackages = [
      "electron-39.8.10"
    ];
    config.allowBroken = true;
    # direnv's Darwin test suite currently hangs in zsh on this host, which
    # blocks darwin-rebuild while the package is built locally.
    overlays = [
      (_: prev: {
        direnv = prev.direnv.overrideAttrs (_: {
          doCheck = false;
        });
      })
    ];
  };

  programs.direnv.enable = true;

  services = {
    tailscale.enable = true;
  };

  launchd.user.agents.input-leap-server = {
    command = "${pkgs.input-leap}/bin/input-leap";
    serviceConfig = {
      RunAtLoad = true;
      KeepAlive = {
        Crashed = true;
        SuccessfulExit = false;
      };
      StandardOutPath = "/Users/mpfammatter/Library/Logs/input-leap.out.log";
      StandardErrorPath = "/Users/mpfammatter/Library/Logs/input-leap.err.log";
    };
  };

  users.users.mpfammatter = {
    name = "mpfammatter";
    home = "/Users/mpfammatter";
  };
}
