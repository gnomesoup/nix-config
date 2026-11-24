# Inigo Zulip DM platform

This native Hermes plugin uses the installed `BasePlatformAdapter` API and
`httpx`, already supplied by Hermes. It does not need the Zulip Python SDK.

## Declarative integration

Supply the upstream package's `hermesVenv` passthru to `package.nix`; running the
checks with bare nixpkgs Python would not exercise the deployed Hermes API:

```nix
inigoZulipPlugin = pkgs.callPackage ./inigo-zulip/package.nix {
  hermesVenv =
    inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default.hermesVenv;
};

services.hermes-agent = {
  extraPlugins = [ inigoZulipPlugin ];
  settings = {
    plugins.enabled = [ "inigo-zulip" ];
    platforms.zulip = {
      enabled = true;
      gateway_restart_notification = false;
      typing_indicator = false;
      extra = {
        site = "https://chat.mmjo.com";
        bot_email = "inigo-bot@chat.mmjo.com";
        allowed_email = "michael@mmjo.com";
      };
    };
  };
};
```

`bot_email` must match the provisioned bot. `site` and `allowed_email` have the
shown defaults. The installed Hermes also promotes untyped platform-level keys
into `extra`, so `settings.platforms.zulip.site`, `.bot_email`, and `.allowed_email`
are equivalent. Do not configure a token, API key, or allow-all setting.

The service must provide systemd credential **`inigo-zulip-api-key`**. The adapter
reads only `$CREDENTIALS_DIRECTORY/inigo-zulip-api-key`; there is no dotenv,
config-token, zuliprc, or environment-key fallback.

### Why the manifest uses `kind: standalone`

The plugin is named `inigo-zulip` and registers the messaging platform `zulip`.
The installed Hermes derives a deferred `kind: platform` registry key from the
plugin **directory basename**, unless its manifest name ends in `-platform`.
Nix installs plugins at `plugins/nix-managed-<package-name>`. A deferred manifest
would therefore register the wrong lookup key and leave `platforms.zulip`
unreachable. The standalone manifest eagerly calls the normal, ledger-owned
`ctx.register_platform()` API instead. Tests exercise the real Hermes loader
under this Nix-managed symlink layout. No Hermes patch or extra model tool is
needed.

## Authorization and lifecycle

- Authenticate `users/me` and `users` over HTTPS. Require the configured account
  to be a bot and resolve exactly one active, non-bot owner by configured email.
- Compare incoming numeric `sender_id` to that server-resolved owner ID, never
  `sender_email`. Require `type: private` and exactly the bot/owner recipient IDs.
  Ignore streams, group DMs, bot/self messages, and malformed messages.
- Forward accepted messages via `build_source()` and `handle_message()`; the
  gateway still performs central authorization. Register `ZULIP_ALLOWED_USERS`
  as the gateway's allowlist field and populate runtime
  `config.extra.allowed_users = [ "<resolved numeric owner ID>" ]` only after
  successful connection. No environment allowlist needs to be set. Clear this
  runtime grant on disconnect/fatal failure.
- Register a raw-Markdown DM-only event queue, long-poll with acknowledgments,
  re-register expired queues, refresh identities on re-registration, and dedupe
  message IDs with Hermes's reconnect-aware `MessageDeduplicator`.
- Retry transient polling/network/server failures with capped exponential
  backoff and jitter; honor rate-limit retry delays. Authentication/identity
  failures fail closed. Notify the gateway on fatal polling/dispatch failure.
- Cancel polling and gateway background tasks, attempt bounded queue deletion,
  and close the HTTP client on shutdown. HTTP redirects are not followed.
- Send only to the resolved owner's numeric DM target. Split text losslessly at
  10,000 Unicode characters and return continuation IDs. Do not replay ambiguous
  POST failures or partially delivered multipart replies.
- Never log API keys, server response bodies, or raw exception details.

This is text-only. It does not download attachments, support streams/group DMs,
backfill messages across offline/expired-queue gaps, or provide standalone cron
sending. Queue replacement may therefore lose events that Zulip no longer has.

## Verification

```sh
/nix/store/pzm8889rx2ggms0bkschqgksbbn688n3-hermes-agent-env/bin/python3 \
  -m unittest discover -s hosts/ferrix/inigo-zulip -v
```

The Nix derivation runs the same suite against both source files and the installed
plugin output. Tests use real Hermes classes, authorization, loader, and httpx
request/response handling with a fake HTTP transport, not live bot credentials.
New adapter behaviors were developed through observed red/green test cycles.
Live realm delivery and service activation remain deployment checks.

References inspected before implementation:

- Hermes official developer guide, `docs/developer-guide/adding-platform-adapters`.
- Installed Hermes Python `gateway/platforms/base.py`, `gateway/authz_mixin.py`,
  `gateway/platform_registry.py`, and plugin loader/discovery APIs.
- Zulip API documentation for queue registration, polling, and direct messages.
