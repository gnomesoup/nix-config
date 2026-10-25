{ pkgs, ferrix }:

let
  inherit (pkgs) lib;
  service = ferrix.systemd.services.paseo-test;
in
assert lib.assertMsg (ferrix.systemd.services ? paseo-test) "Ferrix must provide the Paseo trial";
assert service.serviceConfig.User == "mpfammatter";
assert service.serviceConfig.NoNewPrivileges;
assert service.serviceConfig.UMask == "0077";
assert service.environment.PASEO_RELAY_ENABLED == "false";
assert service.environment.PASEO_HOME == "/home/mpfammatter/.paseo-test";
assert lib.elem 6767 ferrix.networking.firewall.interfaces.tailscale0.allowedTCPPorts;
assert !(lib.elem 6767 ferrix.networking.firewall.allowedTCPPorts);
assert !(ferrix.systemd.services ? docker-remote-pi-relay);
assert !(ferrix.systemd.services ? tailscale-serve-remote-pi-relay);
assert !(ferrix.virtualisation.oci-containers.containers ? remote-pi-relay);
assert !(lib.hasInfix "npm:remote-pi" (builtins.readFile ../../users/modules/pi.nix));
pkgs.runCommand "ferrix-paseo-test"
  {
    # Match the daemon's packaged PATH so missing runtime utilities fail here.
    nativeBuildInputs = [ pkgs.python3 ] ++ builtins.filter lib.isDerivation service.path;
  }
  ''
    python3 ${./paseo-smoke.py} \
      ${pkgs.paseo}/bin/paseo \
      ${service.environment.PASEO_CONFIG_TEMPLATE} \
      "$out"
  ''
