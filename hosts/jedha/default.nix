{
  config,
  pkgs,
  nixos-wsl,
  ...
}:

{
  imports = [
    nixos-wsl.nixosModules.default
    ../modules/fonts.nix
  ];

  wsl.enable = true;
  wsl.defaultUser = "mpfammatter";
  wsl.useWindowsDriver = true;

  networking.hostName = "jedha";

  time.timeZone = "America/Chicago";
  i18n.defaultLocale = "en_US.UTF-8";

  users.users.mpfammatter = {
    isNormalUser = true;
    description = "Michael Pfammatter";
    extraGroups = [ "wheel" ];
    home = "/home/mpfammatter";
    shell = pkgs.zsh;
  };

  environment.systemPackages = with pkgs; [
    neovim
    python3
    git
    curl
    wget
    openssh
  ];

  programs.zsh.enable = true;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
  };

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;

  system.stateVersion = "25.11";
}
