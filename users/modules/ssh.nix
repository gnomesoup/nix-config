{
  pkgs,
  lib,
  config,
  ...
}:
let
  isDarwin = pkgs.stdenv.isDarwin;
  remoteConfigFile = config.sops.secrets."mpfammatter/remote/config".path;
  renderScript = pkgs.writeShellScript "render-ssh-remote-config" ''
    set -euo pipefail

    remote_json="$1"
    output_file="$2"
    output_dir="$(${pkgs.coreutils}/bin/dirname "$output_file")"

    ${pkgs.coreutils}/bin/mkdir -p "$output_dir"

    ${pkgs.jq}/bin/jq -r '
      (.sshHosts // [])
      | map(
          [
            "Host " + .alias,
            "  HostName " + .hostName,
            "  User " + .user
          ]
          + (if .identityFile then ["  IdentityFile " + .identityFile] else [] end)
          + (if .serverAliveInterval then ["  ServerAliveInterval " + (.serverAliveInterval | tostring)] else [] end)
          + (if .serverAliveCountMax then ["  ServerAliveCountMax " + (.serverAliveCountMax | tostring)] else [] end)
          + (if .port then ["  Port " + (.port | tostring)] else [] end)
        )
      | flatten
      | join("\n") + if length > 0 then "\n" else "" end
    ' "$remote_json" > "$output_file"

    ${pkgs.coreutils}/bin/chmod 600 "$output_file"
  '';
in
{
  sops = {
    age.keyFile = lib.mkDefault "${config.home.homeDirectory}/.config/sops/age/keys.txt";
    defaultSopsFormat = "yaml";
    defaultSopsFile = ../../secrets/mpfammatter-remote.json;
    secrets."mpfammatter/remote/config" = {
      format = "json";
      key = "";
      sopsFile = ../../secrets/mpfammatter-remote.json;
    };
  };

  home.packages = [ pkgs.jq ];

  home.activation.ensureSopsLogDir = lib.hm.dag.entryBefore [ "sops-nix" ] ''
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg "${config.home.homeDirectory}/Library/Logs/SopsNix"}
  '';

  home.activation.sops-nix = lib.mkIf isDarwin (
    lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
      /bin/launchctl bootout gui/$(id -u ${config.home.username})/org.nix-community.home.sops-nix && true
      /bin/launchctl bootstrap gui/$(id -u ${config.home.username}) ${lib.escapeShellArg "${config.home.homeDirectory}/Library/LaunchAgents/org.nix-community.home.sops-nix.plist"}
    ''
  );

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    includes = [ "~/.ssh/config.d/remote.conf" ];
    matchBlocks."*" = {
      addKeysToAgent = "yes";
      compression = false;
      controlMaster = "no";
      controlPath = "~/.ssh/master-%r@%n:%p";
      controlPersist = "no";
      forwardAgent = false;
      hashKnownHosts = false;
      identityFile = [ "~/.ssh/id_ed25519" ];
      serverAliveCountMax = 3;
      serverAliveInterval = 0;
      userKnownHostsFile = "~/.ssh/known_hosts";
    };
    extraConfig = lib.concatStringsSep "\n" (
      lib.optionals isDarwin [
        "IgnoreUnknown UseKeychain"
        "UseKeychain yes"
      ]
    );
  };

  home.activation.renderRemoteSshConfig = lib.hm.dag.entryAfter [ "sops-nix" ] ''
    for _ in $(seq 1 50); do
      if [ -e ${lib.escapeShellArg remoteConfigFile} ]; then
        break
      fi
      sleep 0.1
    done

    ${renderScript} ${lib.escapeShellArg remoteConfigFile} ${lib.escapeShellArg "${config.home.homeDirectory}/.ssh/config.d/remote.conf"}
  '';
}
