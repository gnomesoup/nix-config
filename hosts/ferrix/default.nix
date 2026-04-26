# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./zulip.nix
    ../modules/fonts.nix
  ];

  sops.defaultSopsFile = ../../secrets/secrets.yaml;
  sops.defaultSopsFormat = "yaml";
  sops.age.keyFile = "/home/mpfammatter/.config/sops/age/keys.txt";
  sops.secrets."smb/passwords/ferrix-smb" = { };
  sops.templates."smb-ferrix-smb" = {
    content = ''
      username=ferrix-smb
      password=${config.sops.placeholder."smb/passwords/ferrix-smb"}
      domain=WORKGROUP
    '';
    owner = "root";
    group = "root";
    mode = "0400";
  };
  # sops.secrets."borg/borg_passphrase" = { };
  # sops.secrets."borg/endor/borgbase_path" = { };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelModules = [ "uinput" ];

  networking.hostName = "ferrix"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  services.udev.extraRules = ''
    KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
  '';

  boot.supportedFilesystems = [ "cifs" ];

  fileSystems."/mnt/hoth-jellyfin" = {
    device = "//192.168.40.183/jellyfin";
    fsType = "cifs";
    options = [
      "credentials=${config.sops.templates."smb-ferrix-smb".path}"
      "x-systemd.automount"
      "noauto"
      "nofail"
      "x-systemd.idle-timeout=5min"
      "x-systemd.device-timeout=10s"
      "x-systemd.mount-timeout=10s"
      "vers=3.1.1"
      "uid=jellyfin"
      "gid=jellyfin"
      "file_mode=0664"
      "dir_mode=0775"
    ];
  };

  fileSystems."/mnt/hoth-pinchflat" = {
    device = "//192.168.40.183/pinchflat";
    fsType = "cifs";
    options = [
      "credentials=${config.sops.templates."smb-ferrix-smb".path}"
      "x-systemd.automount"
      "noauto"
      "nofail"
      "x-systemd.idle-timeout=5min"
      "x-systemd.device-timeout=10s"
      "x-systemd.mount-timeout=10s"
      "vers=3.1.1"
      "uid=jellyfin"
      "gid=jellyfin"
      "file_mode=0664"
      "dir_mode=0775"
    ];
  };

  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandleLidSwitchExternalPower = "ignore";
  };

  # Set your time zone.
  time.timeZone = "America/New_York";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Extend sudo password timeout
  security.sudo.extraConfig = ''
    Defaults:${config.users.users.mpfammatter.name} timestamp_timeout=60
  '';

  # Enable the X11 windowing system.
  # You can disable this if you're only using the Wayland session.
  services.xserver.enable = true;

  # Enable the KDE Plasma Desktop Environment.
  services.displayManager.sddm.enable = true;
  services.displayManager.defaultSession = "plasma";
  services.desktopManager.plasma6.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  xdg.portal = {
    enable = true;
    xdgOpenUsePortal = true;
    extraPortals = [
      pkgs.kdePackages.xdg-desktop-portal-kde
      pkgs.xdg-desktop-portal-gtk
    ];
  };

  services.espanso = {
    enable = true;
    package = pkgs.espanso-wayland;
  };

  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.mpfammatter = {
    isNormalUser = true;
    description = "Michael Pfammatter";
    extraGroups = [
      "input"
      "networkmanager"
      "wheel"
    ];
    packages = with pkgs; [
      kdePackages.kate
      #  thunderbird
    ];
    shell = pkgs.zsh;
  };

  # Install firefox.
  programs.firefox.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.permittedInsecurePackages = [
    "openclaw-2026.4.12"
  ];

  # Enable nix-ld for running non-nix packages in a sandbox.
  programs.nix-ld.enable = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    python3
    python3Packages.dbus-python
    python3Packages.pygobject3
    borgbackup
    sops
    age
    grim
    imagemagick
    nixpkgs-fmt
    slurp
    tesseract
    wezterm
    wl-clipboard
    wtype
    ydotool
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  programs.zsh.enable = true;

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  services.tailscale.enable = true;

  # services.borgmatic = {
  #   enable = true;
  #   settings = {
  #     repositories = [
  #       {
  #         path = "/mnt/backup2/borg/ferrix";
  #         label = "local";
  #       }
  #       {
  #         path = "ssh://x387mg6b@x387mg6b.repo.borgbase.com/./repo";
  #         label = "borgbase";
  #       }
  #     ];
  #     source_directories = [
  #       "/home/mpfammatter"
  #     ];
  #     archive_name_format = "endor-{now:%Y-%m-%d-%H%M%S}";
  #     encryption_passcommand = "/run/current-system/sw/bin/cat ${config.sops.secrets."borg/borg_passphrase".path}";
  #     ssh_command = "${pkgs.openssh}/bin/ssh -i /home/mpfammatter/.ssh/id_ed25519";
  #     keep_daily = 1;
  #     keep_weekly = 4;
  #     keep_monthly = 12;
  #     keep_yearly = 2;
  #   };
  # };

  virtualisation.docker.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

}
