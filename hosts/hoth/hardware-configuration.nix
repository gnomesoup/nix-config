# Do not modify this file!  It was generated by ‘nixos-generate-config’
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "uas" "usb_storage" "sd_mod" "rtsx_pci_sdmmc" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/75cd5b3b-5d07-4140-910d-e54a37f72387";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/1340-70C6";
      fsType = "vfat";
    };

  fileSystems."/mnt/photoprism" =
    { device = "/dev/disk/by-uuid/5dd70d64-c279-483d-a9d7-68e9738d5d6b";
      fsType = "ext4";
      options = [ "nofail" ];
    };

  fileSystems."/mnt/backup1" =
    { device = "/dev/disk/by-uuid/4ce63432-8223-495e-95a0-8aac69181517";
      fsType = "ext4";
      options = [ "nofail" ];
    };

  fileSystems."/mnt/backup2" =
    { device = "/dev/disk/by-uuid/f8c69028-4b3f-4f4a-9f10-c064aaede45c";
      fsType = "ext4";
      options = [ "nofail" ];
    };

  swapDevices =
    [ { device = "/dev/disk/by-uuid/ea6d8b51-b3b5-4b23-a722-a96bd54b3f18"; }
    ];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.eno1.useDHCP = lib.mkDefault true;
  # networking.interfaces.tailscale0.useDHCP = lib.mkDefault true;
  # networking.interfaces.wlp58s0.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
