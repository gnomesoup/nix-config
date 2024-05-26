# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, inputs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ../modules/fonts.nix
    ];


  sops.defaultSopsFile = ../../secrets/secrets.yaml;
  sops.defaultSopsFormat = "yaml";
  sops.age.keyFile = "/home/mpfammatter/.config/sops/age/keys.txt";
  sops.secrets."borg/borg_passphrase" = { };
  sops.secrets."borg/endor/borgbase_path" = { };

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.hostName = "hoth"; # Define your hostname.
  # Pick only one of the below networking options.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  # networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

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

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.defaultUserShell = pkgs.zsh;
  users.groups.sambauser = {};
  users.users.mpfammatter = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ]; # Enable ‘sudo’ for the user.
    packages = with pkgs; [
    ];
  };
  users.users.coruscant-tm = {
    isSystemUser = true;
    group = "sambauser";
  };
  users.users.pinkimac-tm = {
    isSystemUser = true;
    group = "sambauser";
  };
  users.users.ha-backup = {
    isSystemUser = true;
    group = "sambauser";
  };
  users.users.eadu-backup = {
    isNormalUser = true;
    extraGroups = ["sambauser"];
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    borgbackup
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
  ## Working on getting the system to boot when usb devices are not found
  ## fount the "nofail" option instead
  # services.gvfs.enable = true;
  # services.udisks2.enable = true;
  # services.udisks2.mountOnMedia = true;
  # services.devmon.enable = true;
  
  ## Time machine samba setup
  # assign passwords to samba users manually with `smbpasswd -a $USER`
  services.samba-wsdd = {
    # make shares visible for Windows clients
    enable = true;
    openFirewall = true;
  };
  services.samba = {
    enable = true;
    securityType = "user";
    extraConfig = ''
      workgroup = WORKGROUP
      server string = hoth
      netbios name = hoth
      security = user 
      #use sendfile = yes
      #max protocol = smb2
      # note: localhost is the ipv6 localhost ::1
      hosts allow = 192.168.40. 127.0.0.1 localhost 100.82.20.42 100.69.20.54 100.94.250.60 100.105.216.37 100.75.55.140 100.64.177.72
      hosts deny = 0.0.0.0/0
      guest account = nobody
      map to guest = bad user
    '';
    shares = {
      homeassistant = {
        path = "/mnt/backup2/homeassistant";
        "valid users" = "ha-backup";
        public = "no";
        writeable = "yes";
        browseable = "yes";
        "comment" = "Backups for Home Assistant";
        "force user" = "ha-backup";
        "fruit:aapl" = "yes";
        "fruit:time machine" = "yes";
        "vfs objects" = "catia fruit streams_xattr";
        "spotlight" = "yes";
      };
      coruscant-tm = {
        path = "/mnt/backup2/tm1";
        "valid users" = "coruscant-tm";
        public = "no";
        writeable = "yes";
        browseable = "yes";
        "comment" = "Time Machine";
        "force user" = "coruscant-tm";
        "fruit:aapl" = "yes";
        "fruit:time machine" = "yes";
        "vfs objects" = "catia fruit streams_xattr";
        "spotlight" = "yes";
      };
      pinkimac-tm = {
        path = "/mnt/backup2/tm2";
        "valid users" = "pinkimac-tm";
        public = "no";
        writeable = "yes";
        browseable = "yes";
        "comment" = "Time Machine";
        "force user" = "pinkimac-tm";
        "fruit:aapl" = "yes";
        "fruit:time machine" = "yes";
        "vfs objects" = "catia fruit streams_xattr";
        "spotlight" = "yes";
      };
    };
  };
  services.samba.openFirewall = true;

  services.borgmatic = {
    enable = true;
    settings = {
      repositories = [
        {
          path = "/mnt/backup2/borg/endor";
          label = "local";
        }
        {
          path = "ssh://x387mg6b@x387mg6b.repo.borgbase.com/./repo";
          label = "borgbase";
        }
      ];
      source_directories = [
        "/home/mpfammatter"
        "/mnt/photoprism/photoprism/originals"
        "/mnt/photoprism/photoprism/storage"
        "/var/lib/docker/volumes/docker_frigatedb/_data"
        "/mnt/backup2/homeassistant"
        "/mnt/backup1/backups/dad"
        "/mnt/backup1/immich/library"
        "/mnt/backup2/backups/afp-northwestern"
      ];
      exclude_patterns = [
        "/home/mpfammatter/docker/photoprism-database/*"
        "/home/mpfammatter/docker/immich-db/*"
      ];
      archive_name_format = "endor-{now:%Y-%m-%d-%H%M%S}";
      encryption_passcommand = "/run/current-system/sw/bin/cat ${config.sops.secrets."borg/borg_passphrase".path}";
      ssh_command = "${pkgs.openssh}/bin/ssh -i /home/mpfammatter/.ssh/id_ed25519";
      keep_daily = 1;
      keep_weekly = 4;
      keep_monthly = 12; 
      keep_yearly = 2;
    };
  };

  virtualisation.docker.enable = true;

  programs.nix-ld.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "23.11"; # Did you read the comment?

}

