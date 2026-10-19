{
  pkgs,
  ferrix,
  hoth,
  jedha,
}:

let
  inherit (pkgs) lib;
  mainFile = ../../secrets/secrets.yaml;
  inigoFile = ../../secrets/inigo.yaml;
  backupFile = ../../secrets/backup-shared.yaml;
  ferrixBackupFile = ../../secrets/ferrix-backups.yaml;
  espansoFile = ../../secrets/mpfammatter-espanso.yaml;
  routesTo =
    secrets: file: name: key:
    assert lib.assertMsg (
      toString secrets.${name}.sopsFile == toString file
    ) "SOPS file routing changed for ${name}";
    assert lib.assertMsg (secrets.${name}.key == key) "SOPS lookup key changed for ${name}";
    true;
  unchangedKeys =
    secrets: file: names:
    lib.all (name: routesTo secrets file name name) names;
  smtpAliases =
    secrets:
    lib.all (suffix: routesTo secrets backupFile "backup/email-${suffix}" "zulip/email_${suffix}") [
      "username"
      "password"
    ];
  legacyAlerts = import ./ferrix-backup-alerts.nix {
    config = ferrix;
    inherit pkgs;
  };
  inigoSecrets = [
    "hermes/api-server-key"
    "hermes/dashboard-password"
    "hermes/dashboard-secret"
    "inigo/github-deploy-key"
    "inigo/home-assistant-token"
    "inigo/protonmail-bridge-email"
    "inigo/protonmail-bridge-password"
    "inigo/protonmail-bridge-username"
    "inigo/silverbullet-api-token"
  ];
  smtpSecrets = [
    "zulip/email_username"
    "zulip/email_password"
  ];
in
assert unchangedKeys ferrix.sops.secrets inigoFile inigoSecrets;
assert unchangedKeys hoth.sops.secrets inigoFile [ "inigo/ssh_key" ];
assert unchangedKeys hoth.sops.secrets backupFile [
  "borg/borg_passphrase"
  "borg/endor/borgbase_path"
];
assert unchangedKeys ferrix.sops.secrets backupFile smtpSecrets;
assert smtpAliases ferrix.sops.secrets;
assert smtpAliases hoth.sops.secrets;
# This helper is currently unimported; keep its declarations safe to reuse.
assert lib.all (
  name: toString legacyAlerts.sops.secrets.${name}.sopsFile == toString backupFile
) smtpSecrets;
assert lib.all (host: toString host.sops.defaultSopsFile == toString mainFile) [
  ferrix
  hoth
  jedha
];
assert unchangedKeys ferrix.sops.secrets mainFile [
  "inigo/age-key"
  "silverbullet/pi-api-token"
  "silverbullet/calendar/personal-icloud-url"
  "silverbullet/calendar/ksp-outlook-url"
  "smb/passwords/ferrix-smb"
  "zulip/admin_email"
  "zulip/postgres_password"
  "zulip/memcached_password"
  "zulip/rabbitmq_password"
  "zulip/redis_password"
  "zulip/secret_key"
];
assert unchangedKeys jedha.sops.secrets mainFile (builtins.attrNames jedha.sops.secrets);
assert ferrix.sops.secrets."inigo/age-key".mode == "0400";
assert ferrix.sops.secrets."inigo/silverbullet-api-token".owner == null;
assert ferrix.sops.secrets."inigo/silverbullet-api-token".uid == 0;
assert ferrix.sops.secrets."inigo/silverbullet-api-token".mode == "0400";
assert ferrix.sops.secrets."silverbullet/pi-api-token".owner == "mpfammatter";
assert
  ferrix.services.hermes-agent.environment.SOPS_AGE_KEY_FILE
  == ferrix.sops.secrets."inigo/age-key".path;
assert lib.all
  (
    host:
    lib.all (name: routesTo host.sops.secrets ferrixBackupFile "ferrix-backup/${name}" name) (
      if host.networking.hostName == "ferrix" then
        [
          "hoth-passphrase"
          "borgbase-passphrase"
          "hoth-ssh-key"
          "borgbase-ssh-key"
        ]
      else
        [
          "hoth-passphrase"
          "borgbase-passphrase"
        ]
    )
  )
  [
    ferrix
    hoth
  ];
assert lib.all
  (
    host:
    unchangedKeys host.home-manager.users.mpfammatter.sops.secrets espansoFile (
      map (name: "mpfammatter/espanso/${name}") [
        "emmm"
        "emks"
        "adks"
        "zipks"
        "phks"
        "adta"
        "phmm"
        "ksp"
      ]
    )
  )
  [
    ferrix
    hoth
  ];
pkgs.runCommand "sops-access-check"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    mkdir -p scripts secrets
    cp ${../../scripts/check-sops-access.py} scripts/check-sops-access.py
    cp ${../../scripts/check-sops-access_test.py} scripts/check-sops-access_test.py
    cp ${../../.sops.yaml} .sops.yaml
    cp ${../../secrets}/*.yaml secrets/
    python3 scripts/check-sops-access_test.py -v
    python3 scripts/check-sops-access.py --root "$PWD"
    touch "$out"
  ''
