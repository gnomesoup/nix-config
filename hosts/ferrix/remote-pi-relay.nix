{ pkgs, ... }:

{
  virtualisation.oci-containers = {
    backend = "docker";

    containers.remote-pi-relay = {
      image = "docker.io/jacobmoura7/remote-pi-relay:latest";
      pull = "always";
      environment = {
        REMOTEPI_RELAY_PORT = "3001";
        RUST_LOG = "info";
      };
      volumes = [ "/var/lib/remote-pi-relay:/data" ];

      # Keep the backend reachable on host loopback for Tailscale Serve
      # without Docker port-publishing bypassing the NixOS firewall.
      extraOptions = [ "--network=host" ];
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/remote-pi-relay 0750 root root -"
  ];

  systemd.services.tailscale-serve-remote-pi-relay = {
    description = "Tailscale Serve configuration for Remote Pi Relay";
    wantedBy = [ "multi-user.target" ];
    after = [
      "docker-remote-pi-relay.service"
      "tailscaled-autoconnect.service"
      "tailscaled-set.service"
      "tailscaled.service"
    ];
    wants = [
      "docker-remote-pi-relay.service"
      "tailscaled.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = "-${pkgs.tailscale}/bin/tailscale serve clear svc:pi";
      ExecStart = "${pkgs.tailscale}/bin/tailscale serve --service=svc:pi --https=443 --bg http://127.0.0.1:3001";
      ExecStop = pkgs.writeShellScript "tailscale-serve-remote-pi-relay-stop" ''
        ${pkgs.tailscale}/bin/tailscale serve drain svc:pi || true
        ${pkgs.tailscale}/bin/tailscale serve clear svc:pi || true
      '';
    };
  };
}
