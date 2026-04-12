{ config, pkgs, ... }:

let
  composeFile = pkgs.writeText "zulip-compose.yaml" ''
    ---
    services:
      database:
        image: "zulip/zulip-postgresql:14"
        restart: unless-stopped
        secrets:
          - zulip__postgres_password
        environment:
          POSTGRES_DB: "zulip"
          POSTGRES_USER: "zulip"
          POSTGRES_PASSWORD_FILE: /run/secrets/zulip__postgres_password
        volumes:
          - "postgresql-14:/var/lib/postgresql/data:rw"

      memcached:
        image: "memcached:alpine"
        restart: unless-stopped
        command:
          - "sh"
          - "-euc"
          - |
            echo 'mech_list: plain' > "$${SASL_CONF_PATH}"
            echo "zulip@$${HOSTNAME}:$$(cat $${MEMCACHED_PASSWORD_FILE})" > "$${MEMCACHED_SASL_PWDB}"
            echo "zulip@localhost:$$(cat $${MEMCACHED_PASSWORD_FILE})" >> "$${MEMCACHED_SASL_PWDB}"
            exec memcached -S
        environment:
          SASL_CONF_PATH: "/home/memcache/memcached.conf"
          MEMCACHED_SASL_PWDB: "/home/memcache/memcached-sasl-db"
          MEMCACHED_PASSWORD_FILE: "/home/memcache/memcached-password"
        volumes:
          - "${
            config.sops.templates."zulip-memcached-password".path
          }:/home/memcache/memcached-password:ro"

      rabbitmq:
        image: "rabbitmq:4.2"
        restart: unless-stopped
        command:
          - "sh"
          - "-euc"
          - |
            export RABBITMQ_DEFAULT_PASS="$$(cat $${RABBITMQ_PASSWORD_FILE})"
            echo "default_user = $${RABBITMQ_DEFAULT_USER}" >> /etc/rabbitmq/rabbitmq.conf
            echo "default_pass = $${RABBITMQ_DEFAULT_PASS}" >> /etc/rabbitmq/rabbitmq.conf
            exec docker-entrypoint.sh rabbitmq-server
        secrets:
          - zulip__rabbitmq_password
        environment:
          RABBITMQ_DEFAULT_USER: "zulip"
          RABBITMQ_PASSWORD_FILE: /run/secrets/zulip__rabbitmq_password
        volumes:
          - "rabbitmq:/var/lib/rabbitmq:rw"

      redis:
        image: "redis:alpine"
        restart: unless-stopped
        command:
          - "sh"
          - "-euc"
          - '/usr/local/bin/docker-entrypoint.sh --requirepass "$$(cat $${REDIS_PASSWORD_FILE})"'
        secrets:
          - zulip__redis_password
        environment:
          REDIS_PASSWORD_FILE: /run/secrets/zulip__redis_password
        volumes:
          - "redis:/data:rw"

      zulip:
        image: "ghcr.io/zulip/zulip-server:11.6-1"
        restart: unless-stopped
        ports:
          - "8080:80"
        env_file:
          - ${config.sops.templates."zulip-settings.env".path}
        secrets:
          - zulip__postgres_password
          - zulip__memcached_password
          - zulip__rabbitmq_password
          - zulip__redis_password
          - zulip__secret_key
          - zulip__email_password
        environment:
          SETTING_REMOTE_POSTGRES_HOST: "database"
          SETTING_MEMCACHED_LOCATION: "memcached:11211"
          SETTING_RABBITMQ_HOST: "rabbitmq"
          SETTING_REDIS_HOST: "redis"
        volumes:
          - "zulip:/data:rw"
        ulimits:
          nofile:
            soft: 1000000
            hard: 1048576
        depends_on:
          - database
          - memcached
          - rabbitmq
          - redis

    secrets:
      zulip__postgres_password:
        file: ${config.sops.secrets."zulip/postgres_password".path}
      zulip__memcached_password:
        file: ${config.sops.secrets."zulip/memcached_password".path}
      zulip__rabbitmq_password:
        file: ${config.sops.secrets."zulip/rabbitmq_password".path}
      zulip__redis_password:
        file: ${config.sops.secrets."zulip/redis_password".path}
      zulip__secret_key:
        file: ${config.sops.secrets."zulip/secret_key".path}
      zulip__email_password:
        file: ${config.sops.secrets."zulip/email_password".path}

    volumes:
      zulip:
      postgresql-14:
      rabbitmq:
      redis:
  '';
in
{
  sops.secrets."zulip/admin_email" = { };
  sops.secrets."zulip/email_username" = { };
  sops.secrets."zulip/email_password" = { };
  sops.secrets."zulip/postgres_password" = { };
  sops.secrets."zulip/memcached_password" = { };
  sops.secrets."zulip/rabbitmq_password" = { };
  sops.secrets."zulip/redis_password" = { };
  sops.secrets."zulip/secret_key" = { };

  sops.templates."zulip-settings.env" = {
    content = ''
      SETTING_EXTERNAL_HOST=chat.mmjo.com
      SETTING_ZULIP_ADMINISTRATOR=${config.sops.placeholder."zulip/admin_email"}
      SETTING_EMAIL_HOST=smtp.protonmail.ch
      SETTING_EMAIL_PORT=587
      SETTING_EMAIL_USE_TLS=True
      SETTING_EMAIL_HOST_USER=${config.sops.placeholder."zulip/email_username"}
      SETTING_NOREPLY_EMAIL_ADDRESS=${config.sops.placeholder."zulip/email_username"}
      SETTING_ADD_TOKENS_TO_NOREPLY_ADDRESS=False
      CONFIG_application_server__queue_workers_multiprocess=false
      TRUST_GATEWAY_IP=True
    '';
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.templates."zulip-memcached-password" = {
    content = ''
      ${config.sops.placeholder."zulip/memcached_password"}
    '';
    owner = "root";
    group = "root";
    mode = "0444";
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 8080 ];

  systemd.services.zulip-init = {
    description = "Initialize Zulip Docker deployment";
    after = [
      "docker.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "30min";
    };
    script = ''
      set -euo pipefail

      ${pkgs.docker}/bin/docker compose --project-name zulip -f ${composeFile} pull
      ${pkgs.docker}/bin/docker compose --project-name zulip -f ${composeFile} run --rm zulip app:init
    '';
  };

  systemd.services.zulip = {
    description = "Run Zulip Docker deployment";
    after = [
      "docker.service"
      "network-online.target"
      "zulip-init.service"
    ];
    wants = [ "network-online.target" ];
    requires = [
      "docker.service"
      "zulip-init.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = "${pkgs.docker}/bin/docker compose --project-name zulip -f ${composeFile} pull";
      ExecStart = "${pkgs.docker}/bin/docker compose --project-name zulip -f ${composeFile} up -d";
      ExecReload = "${pkgs.docker}/bin/docker compose --project-name zulip -f ${composeFile} up -d";
      ExecStop = "${pkgs.docker}/bin/docker compose --project-name zulip -f ${composeFile} down";
      TimeoutStartSec = "30min";
      TimeoutStopSec = "15min";
    };
  };
}
