{
  config,
  lib,
  pkgs,
  nixos-wsl,
  ...
}:

let
  networkShareSecrets = {
    j = "jedha/network-shares/j";
    k = "jedha/network-shares/k";
    m = "jedha/network-shares/m";
    o = "jedha/network-shares/o";
    p = "jedha/network-shares/p";
    q = "jedha/network-shares/q";
    r = "jedha/network-shares/r";
    s = "jedha/network-shares/s";
    t = "jedha/network-shares/t";
    u = "jedha/network-shares/u";
    v = "jedha/network-shares/v";
    z = "jedha/network-shares/z";
  };

  drvfsMountOptions = "metadata,uid=1000,gid=100,nofail";
in
{
  imports = [
    nixos-wsl.nixosModules.default
    ../modules/fonts.nix
  ];

  sops.defaultSopsFile = ../../secrets/secrets.yaml;
  sops.defaultSopsFormat = "yaml";
  sops.age.keyFile = "/home/mpfammatter/.config/sops/age/keys.txt";
  sops.secrets = builtins.listToAttrs (
    map (secretName: {
      name = secretName;
      value = { };
    }) (builtins.attrValues networkShareSecrets)
  );

  wsl.enable = true;
  wsl.defaultUser = "mpfammatter";
  wsl.useWindowsDriver = true;
  wsl.interop.register = true;

  networking.hostName = "jedha";

  systemd.services.mount-wsl-network-shares = {
    description = "Mount WSL network shares";
    wantedBy = [ "multi-user.target" ];
    wants = [ "sops-nix.service" ];
    after = [ "sops-nix.service" ];

    path = [
      pkgs.coreutils
      pkgs.util-linux
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -u

      mount_options=${lib.escapeShellArg drvfsMountOptions}

      mount_share() {
        mountpoint="$1"
        secret_file="$2"

        if [ ! -s "$secret_file" ]; then
          echo "Skipping $mountpoint: missing or empty network path secret" >&2
          return 0
        fi

        device="$(tr -d '\r\n' < "$secret_file")"

        if [ -z "$device" ]; then
          echo "Skipping $mountpoint: empty network path secret" >&2
          return 0
        fi

        mkdir -p "$mountpoint"

        if mountpoint -q "$mountpoint"; then
          return 0
        fi

        if ! mount -t drvfs "$device" "$mountpoint" -o "$mount_options" >/dev/null 2>&1; then
          echo "Failed to mount $mountpoint" >&2
        fi
      }

      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          letter: secretName:
          "mount_share ${lib.escapeShellArg "/mnt/${letter}"} ${
            lib.escapeShellArg (config.sops.secrets.${secretName}.path)
          }"
        ) networkShareSecrets
      )}
    '';
  };

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
  programs.nix-ld.enable = true;

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
