{ config, pkgs, ... }:

let
  alertConfig = pkgs.writeText "ferrix-backup-alerts.json" (
    builtins.toJSON {
      recipient = "michael@mmjo.com";
      smtp_host = "smtp.protonmail.ch";
      smtp_port = 587;
      username_file = config.sops.secrets."zulip/email_username".path;
      password_file = config.sops.secrets."zulip/email_password".path;
      state_dir = "/var/lib/ferrix-backup/alerts";
    }
  );
  health = pkgs.writeShellScriptBin "ferrix-backup-health" ''
    exec ${pkgs.python3}/bin/python3 ${./ferrix-backup-health.py} \
      --config ${alertConfig} "$@"
  '';
in
{
  # Reuse the existing noninteractive SMTP credentials, not the Proton Bridge
  # session. Only root can read them; STARTTLS verifies the remote certificate.
  sops.secrets."zulip/email_username".sopsFile = ../../secrets/backup-shared.yaml;
  sops.secrets."zulip/email_password".sopsFile = ../../secrets/backup-shared.yaml;

  environment.systemPackages = [ health ];
  system.build.ferrixBackupHealth = health;
  systemd.tmpfiles.rules = [
    "d /var/lib/ferrix-backup 0700 root root -"
    "d /var/lib/ferrix-backup/alerts 0700 root root -"
  ];

  systemd.services."ferrix-backup-alert@" = {
    description = "Email a Ferrix backup failure to Michael";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      StartLimitIntervalSec = "1h";
      StartLimitBurst = 3;
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${health}/bin/ferrix-backup-health failed %i";
      Restart = "on-failure";
      RestartSec = "5min";
      TimeoutStartSec = "2min";
      User = "root";
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/ferrix-backup/alerts" ];
    };
  };
}
