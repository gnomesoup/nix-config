{ config, pkgs, ... }:

{
  users.users.inigo = {
    isNormalUser = true;
    description = "Openclaw automation user";
    home = "/home/inigo";
    shell = pkgs.bash;
    extraGroups = [ "tailscale" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKyV+BoXi7zylx8Y6C2knigd57DOeaJOTNrWBp87Q3Xc openclaw-inigo@ha"
    ];
  };

  services.openssh.extraConfig = ''
    Match User inigo
      AllowTcpForwarding no
      X11Forwarding no
      PermitTunnel no
      PermitRootLogin no
      PasswordAuthentication no
      PubkeyAuthentication yes
      PermitEmptyPasswords no
  '';

  sops.secrets."inigo/ssh_key" = { };
}