# Nix configuration cleanup and hardening roadmap

This roadmap turns the configuration review into small, ordered work sessions. Each phase is intended to fit comfortably in one coding-agent session using a cost-effective model such as Luna.

## How to use this roadmap

- Complete one phase per session unless a phase explicitly says otherwise.
- Check the phase's **Model fit** before reading implementation files or making changes.
- Start each session by reading `AGENTS.md`, this roadmap, and only the files listed for that phase.
- Connect to the `nixos` MCP server before researching NixOS, Home Manager, or nix-darwin options.
- Keep host-specific values under `hosts/*`; put only genuinely shared behavior in reusable modules.
- Inspect `git status` before editing and do not overwrite unrelated work.
- Never decrypt secrets into the repository or print secret values in logs.
- Do not change any `system.stateVersion` or `home.stateVersion` values.
- For security-sensitive changes, build first and activate only after the manual checks are satisfied.
- Update the phase status and notes before ending a session.

## Model suitability gate

Every phase is marked with one of these labels:

- **Luna suitable:** The phase is bounded and mechanical enough for Luna when the instructions and validation steps are followed.
- **Substantial model required:** The phase has high blast radius, security-sensitive design, complex Nix module interactions, or large order-dependent configuration moves.

A model must stop before editing when any of the following is true:

1. The phase says **Substantial model required** and the active model is Luna or another lightweight/cost-focused model.
2. The model cannot inspect or understand all files named in the phase.
3. The model cannot run the required evaluation or validation commands.
4. The working tree contains overlapping changes whose intent is unclear.
5. A manual gate is unsatisfied, especially for SSH, users, passwords, sops keys, storage, or service credentials.
6. The task expands materially beyond the phase's listed scope.

When stopping, make no edits and respond with:

```text
STOPPED: Phase N requires a more substantial model or an unsatisfied manual prerequisite.
Reason: <specific reason>
Recommended next step: <model tier, prerequisite, or narrower follow-up>
```

A substantial model must still stop rather than guess when a manual gate is unsatisfied. Model strength does not replace console access, backups, recipient information, runtime testing, or user decisions.

## Phase model summary

| Phases | Model fit |
| --- | --- |
| 1–7 | Luna suitable |
| 8–18 | Substantial model required |
| 19–20 | Luna suitable |
| 21 | Substantial model required |
| 22–24 | Luna suitable |
| 25–29 | Substantial model required |
| 30 | Luna suitable |
| 31 | Substantial model required |
| 32 | Luna suitable |

## Status legend

- [ ] Not started
- [~] In progress
- [x] Complete
- [!] Blocked or requires a manual decision

## Validation levels

Use the smallest validation that proves the phase works:

1. **Format:** `nix fmt <touched-file>...`
2. **Evaluate:** evaluate the affected host's top-level derivation.
3. **Build:** run the host-specific build command when the current machine supports it.
4. **Test activation:** use `nixos-rebuild test` or `darwin-rebuild test` before switching.
5. **Runtime check:** inspect the affected service after activation.

Do not run a repo-wide formatter merely to fix one phase.

---

# Milestone 1: Restore a reliable baseline

## Phase 1 — Make flake checks green

**Model fit:** Luna suitable  
**Priority:** P0  
**Expected size:** Small  
**Primary files:** `flake.nix`, `users/test.nix`

### Tasks

- [ ] Remove `x86_64-darwin` from `supportedSystems` unless an actual host still requires it.
- [ ] Replace or remove the non-standard `darwinPackages` output.
- [ ] Expose local packages through standard `packages.<system>` outputs.
- [ ] Add a description to the `update-pi-coding-agent` app metadata.
- [ ] Update the renamed Git options in `users/test.nix` to `programs.git.settings.user.*`.
- [ ] Keep the lock file unchanged unless an input update is explicitly required.

### Validation

```sh
nix flake show --no-write-lock-file
nix flake check --no-build --all-systems --keep-going --no-write-lock-file
```

### Done when

- [ ] The unsupported Darwin error is gone.
- [ ] There is no unknown `darwinPackages` warning.
- [ ] There are no renamed-option warnings from the test profile.

---

## Phase 2 — Establish formatting and static checks

**Model fit:** Luna suitable  
**Priority:** P0  
**Expected size:** Small  
**Primary files:** `flake.nix` and currently unformatted `*.nix` files

### Tasks

- [ ] Format the five files identified by the review without changing semantics.
- [ ] Add a formatter workflow suitable for a tree, preferably `treefmt-nix` or `nixfmt-tree`.
- [ ] Add lightweight `statix` and `deadnix` checks if they can be wired without a large new framework.
- [ ] Exclude generated hardware configuration only if formatting it would create recurring churn; document the exception.
- [ ] Ensure checks run through standard `checks.<system>` outputs.

### Validation

```sh
nix fmt
nix flake check --no-build --all-systems --keep-going --no-write-lock-file
```

### Done when

- [ ] Formatting is reproducible through the flake.
- [ ] Static checks are available as standard flake checks.
- [ ] Any exclusions are documented and narrow.

---

## Phase 3 — Fix platform ownership and architecture ambiguity

**Model fit:** Luna suitable  
**Priority:** P0  
**Expected size:** Small  
**Primary files:** `flake.nix`, `hosts/*/hardware-configuration.nix`, host defaults as needed

### Tasks

- [ ] Choose one source of truth for each host platform.
- [ ] Resolve the `nixvm` conflict: `flake.nix` says `x86_64-linux`, while its hardware module evaluates to `aarch64-linux`.
- [ ] Prefer passing `system` through a host constructor or declaring `nixpkgs.hostPlatform` in the host, but not both.
- [ ] Verify every configured host evaluates to its intended architecture.
- [ ] Remove unused `vars` module arguments from Darwin host files.

### Validation

```sh
nix eval --raw .#nixosConfigurations.hoth.pkgs.stdenv.hostPlatform.system
nix eval --raw .#nixosConfigurations.ferrix.pkgs.stdenv.hostPlatform.system
nix eval --raw .#nixosConfigurations.nixvm.pkgs.stdenv.hostPlatform.system
nix eval --raw .#nixosConfigurations.jedha.pkgs.stdenv.hostPlatform.system
nix eval --raw '.#darwinConfigurations.Coruscant.pkgs.stdenv.hostPlatform.system'
nix eval --raw '.#darwinConfigurations.exegol.pkgs.stdenv.hostPlatform.system'
```

### Done when

- [ ] Each host has one unambiguous platform declaration.
- [ ] `nixvm` matches the real VM architecture.

---

# Milestone 2: Simplify flake and host composition

## Phase 4 — Introduce shared host constructors

**Model fit:** Luna suitable if the refactor remains structural; stop if output behavior changes or evaluation failures cannot be explained.  
**Priority:** P1  
**Expected size:** Medium  
**Primary files:** `flake.nix`, new files under `lib/`

### Tasks

- [ ] Add a small `mkNixosHost` helper.
- [ ] Add a small `mkDarwinHost` helper.
- [ ] Centralize repeated overlay and Home Manager wiring.
- [ ] Keep per-host `specialArgs` explicit and minimal.
- [ ] Merge the two separate `nixosConfigurations` assignments into one clear block.
- [ ] Preserve all existing output names.
- [ ] Do not move host settings during this phase.

### Validation

```sh
nix flake show --no-write-lock-file
nix flake check --no-build --all-systems --keep-going --no-write-lock-file
```

Evaluate every NixOS top-level and Darwin system derivation.

### Done when

- [ ] Shared Home Manager wiring appears only once per platform family.
- [ ] All existing hosts and user outputs still evaluate.
- [ ] The change is structural only.

---

## Phase 5 — Create a shared NixOS core module

**Model fit:** Luna suitable if settings are moved without semantic changes; stop if resolved options differ unexpectedly.  
**Priority:** P1  
**Expected size:** Medium  
**Primary files:** new `hosts/modules/nixos-core.nix`, NixOS host defaults

### Tasks

- [ ] Move genuinely shared Nix settings into the core module.
- [ ] Move shared locale, timezone, zsh, and basic administrative packages where identical.
- [ ] Keep hostname, boot, hardware, storage, desktop, services, and firewall rules host-specific.
- [ ] Avoid `lib.mkForce` unless a documented invariant requires it.
- [ ] Remove empty package lists and generated template comments from host files.
- [ ] Do not harden SSH yet; that is a separate phase.

### Validation

- [ ] Evaluate all four NixOS hosts.
- [ ] Compare key resolved options before and after where practical.
- [ ] Run a build for at least one representative NixOS host if supported.

### Done when

- [ ] Repeated core settings are centralized.
- [ ] Host files still clearly show their unique responsibilities.

---

## Phase 6 — Separate NixOS role modules

**Model fit:** Luna suitable when performed as role extraction without behavior changes; stop if module priority conflicts arise.  
**Priority:** P1  
**Expected size:** Medium  
**Primary files:** new modules under `hosts/modules/`, `hosts/ferrix/default.nix`, `hosts/nixvm/default.nix`

### Tasks

- [ ] Create a reusable Plasma desktop profile for shared KDE, PipeWire, portal, and desktop settings.
- [ ] Keep hardware-specific input rules and host-specific services outside the profile.
- [ ] Create narrowly scoped modules for Docker/container support rather than enabling it in a generic base.
- [ ] Keep WSL behavior isolated to the `jedha` host or a dedicated WSL profile.
- [ ] Remove duplicate `allowUnfree` declarations from `nixvm` without changing package availability yet.

### Validation

- [ ] Evaluate and build `ferrix` and `nixvm`.
- [ ] Confirm display manager, Plasma, audio, portals, and expected packages remain enabled.

### Done when

- [ ] Desktop and container roles are composable and independently reviewable.

---

## Phase 7 — Create shared Darwin core and app roles

**Model fit:** Luna suitable for mechanical module and app-role extraction; stop before changing Determinate Nix behavior or unresolved nix-darwin semantics.  
**Priority:** P1  
**Expected size:** Medium  
**Primary files:** Darwin host defaults, `hosts/modules/homebrew.nix`, new Darwin modules

### Tasks

- [ ] Centralize shared Darwin Nix settings, platform defaults, system packages, and user declaration.
- [ ] Preserve Determinate Nix behavior; verify current `nix.enable` guidance before changing it.
- [ ] Split Homebrew casks into narrow roles such as base, work, media, and remote-access.
- [ ] Stop installing the full personal cask set on `Tests-Virtual-Machine`.
- [ ] Keep host-specific launch agents and preferences in their host modules.
- [ ] Remove duplicate or redundant system packages where Home Manager is authoritative.

### Validation

```sh
nix eval --raw '.#darwinConfigurations.Coruscant.system.drvPath'
nix eval --raw '.#darwinConfigurations.exegol.system.drvPath'
nix eval --raw '.#darwinConfigurations.Tests-Virtual-Machine.system.drvPath'
```

Build the test VM configuration if possible.

### Done when

- [ ] The test VM is minimal.
- [ ] Work, personal, and remote-access apps are assigned intentionally per host.

---

# Milestone 3: Harden access and secrets

## Phase 8 — Add shared SSH hardening

**Model fit:** Substantial model required — stop if the active model is Luna or another lightweight model.  
**Priority:** P0 security  
**Expected size:** Small  
**Primary files:** new SSH hardening module, `hosts/hoth/default.nix`, `hosts/ferrix/default.nix`, `users/inigo.nix`

### Manual gate

Before activation, confirm a working public key for `mpfammatter` on both hosts and keep an existing root/local console session open.

### Tasks

- [ ] Set `PasswordAuthentication = false`.
- [ ] Set `KbdInteractiveAuthentication = false`.
- [ ] Set `PermitRootLogin = "no"`.
- [ ] Disable X11 forwarding unless explicitly needed.
- [ ] Restrict `AllowUsers` to intended SSH accounts.
- [ ] Preserve the stricter `inigo` forwarding and tunnel restrictions.
- [ ] Decide whether SSH should be reachable from LAN, Tailscale, or both; scope firewall rules accordingly.
- [ ] Do not activate remotely until the manual gate is satisfied.

### Validation

```sh
nix eval .#nixosConfigurations.hoth.config.services.openssh.settings --json
nix eval .#nixosConfigurations.ferrix.config.services.openssh.settings --json
nixos-rebuild test --flake .#<host>
sshd -T
```

### Done when

- [ ] Password and keyboard-interactive authentication are disabled.
- [ ] Root cannot log in through SSH.
- [ ] Key login works for every required account.

---

## Phase 9 — Establish sops recipient policy

**Model fit:** Substantial model required — stop if the active model is Luna or another lightweight model.  
**Priority:** P0 security  
**Expected size:** Small planning session  
**Primary files:** new `.sops.yaml`, documentation only

### Tasks

- [ ] Inventory which host and user needs each existing secret key.
- [ ] Choose a root-owned per-host age key strategy or SSH host-key strategy.
- [ ] Add `.sops.yaml` creation rules for host-specific and Home Manager secret files.
- [ ] Document recipient labels without including private keys.
- [ ] Plan a migration where new recipients are added and tested before old recipients are removed.
- [ ] Do not split or re-encrypt the existing secret file in this phase.

### Suggested ownership matrix

| Secret group | Intended consumer |
| --- | --- |
| Borg | `hoth` |
| Samba server passwords | `hoth` |
| Ferrix SMB client credential | `ferrix` |
| Zulip | `ferrix` |
| Immich | `nixvm` |
| WSL share paths | `jedha` |
| Espanso and SSH client config | `mpfammatter` Home Manager |

### Validation

```sh
sops updatekeys --yes <a-copy-or-new-test-file>
```

Do not print decrypted values.

### Done when

- [ ] New secret files receive only their intended host/user recipients.
- [ ] The migration order is documented and reversible.

---

## Phase 10 — Migrate system decryption keys safely

**Model fit:** Substantial model required — stop if the active model is Luna or another lightweight model.  
**Priority:** P0 security  
**Expected size:** One session plus manual activation per host  
**Primary files:** NixOS host defaults and encrypted secret metadata

### Manual gate

Ensure console or recovery access exists for each host before changing its decryption key path.

### Tasks

- [ ] Configure a root-owned system age key location for one pilot host.
- [ ] Add that host's recipient to the existing encrypted data before switching configuration.
- [ ] Test decryption and all dependent services.
- [ ] Repeat one host at a time.
- [ ] Remove dependence on `/home/mpfammatter/.config/sops/age/keys.txt` for system services.
- [ ] Keep Home Manager's user key separate from system keys.

### Validation

- [ ] Build and test-activate the pilot host.
- [ ] Confirm expected files exist under `/run/secrets` with narrow ownership and modes.
- [ ] Restart and inspect each dependent service.

### Done when

- [ ] Every system host decrypts with a root-controlled host identity.
- [ ] User compromise no longer automatically exposes all system secrets.

---

## Phase 11 — Split secrets by host

**Model fit:** Substantial model required — stop if the active model is Luna or another lightweight model.  
**Priority:** P0 security  
**Expected size:** Medium; repeat once per host if needed  
**Primary files:** `secrets/*`, `.sops.yaml`, affected host modules

### Tasks

- [ ] Create one encrypted file per host or service boundary.
- [ ] Migrate consumers one host at a time.
- [ ] Never commit a decrypted intermediate file.
- [ ] Verify recipient lists after each re-encryption.
- [ ] Remove unused `borg/endor/borgbase_path` and `inigo/ssh_key` only after confirming no external consumer exists.
- [ ] Leave old ciphertext in place until every consumer has switched successfully.
- [ ] Remove obsolete ciphertext only in a final cleanup commit.

### Validation

- [ ] Evaluate every host after changing `defaultSopsFile` or individual `sopsFile` values.
- [ ] Test-activate each affected host.
- [ ] Confirm unrelated host keys cannot decrypt the new file where practical.

### Done when

- [ ] Secret recipients follow least privilege.
- [ ] No host receives unrelated Zulip, Borg, Samba, Immich, or WSL secrets.

---

## Phase 12 — Make users and passwords reproducible

**Model fit:** Substantial model required — stop if the active model is Luna or another lightweight model.  
**Priority:** P1 security  
**Expected size:** Medium  
**Primary files:** shared user module, host-specific user declarations, host secret files

### Manual gate

Decide whether `users.mutableUsers` should remain enabled. Changing it can reset local passwords and must not be combined casually with unrelated user cleanup.

### Tasks

- [ ] Add sops-backed `hashedPasswordFile` values for interactive NixOS users that require password login or sudo.
- [ ] Mark password-hash secrets as needed during user creation using the current sops-nix option.
- [ ] Decide and document the `users.mutableUsers` policy.
- [ ] Convert noninteractive Samba-only accounts to system users with non-login shells where possible.
- [ ] Review whether `eadu-backup` needs to be a normal login-capable user.
- [ ] Remove duplicate group membership in the resolved `jedha` user configuration.

### Validation

- [ ] Evaluate resolved users for each host.
- [ ] Test activation from a console-accessible session.
- [ ] Confirm sudo works before ending the session.

### Done when

- [ ] New installations do not depend on undocumented `passwd` steps.
- [ ] Service users cannot obtain interactive shells unnecessarily.

---

# Milestone 4: Harden network services and containers

## Phase 13 — Tighten Samba and firewall scope

**Model fit:** Substantial model required — stop if the active model is Luna or another lightweight model.  
**Priority:** P0 security  
**Expected size:** Medium  
**Primary files:** `hosts/hoth/default.nix`, optionally new Samba module

### Tasks

- [ ] Set authenticated shares explicitly to `public = "no"`.
- [ ] Replace `2777` directory masks with the narrowest workable values, preferably `2770` or stricter.
- [ ] Review underlying directory ownership before activation.
- [ ] Replace legacy host patterns with explicit CIDRs or interface-scoped firewall rules.
- [ ] Scope Samba ports to the trusted LAN and/or `tailscale0`.
- [ ] Disable or LAN-scope WSDD.
- [ ] Identify and document the owners of TCP ports `1143` and `1025`; remove them if unused.
- [ ] Preserve Time Machine interoperability.

### Validation

```sh
nix eval .#nixosConfigurations.hoth.config.networking.firewall --json
nixos-rebuild test --flake .#hoth
testparm -s
```

Test each share from one authorized client and confirm unauthorized guest access fails.

### Done when

- [ ] Samba is not globally exposed by convenience options.
- [ ] Writable shares are not world-writable.
- [ ] Every open port has a documented consumer.

---

## Phase 14 — Converge Samba credentials declaratively

**Model fit:** Substantial model required — stop if the active model is Luna or another lightweight model.  
**Priority:** P1 security  
**Expected size:** Medium  
**Primary files:** Samba module and `hoth` secret file

### Tasks

- [ ] Define required Samba password secrets through sops.
- [ ] Add a root-only oneshot service that safely feeds passwords to `smbpasswd` without placing them in the Nix store, command arguments, or logs.
- [ ] Make the service ordering explicit relative to sops and Samba.
- [ ] Ensure repeated runs are safe.
- [ ] Remove the manual `smbpasswd -a` instruction only after every account is managed.
- [ ] Avoid replacing Samba's entire mutable database if doing so would destroy unrelated state.

### Validation

- [ ] Inspect the generated systemd unit without exposing secret content.
- [ ] Test activation on `hoth`.
- [ ] Authenticate every managed share after activation and reboot.

### Done when

- [ ] A fresh host can converge required Samba accounts from encrypted inputs.

---

## Phase 15 — Harden Docker privileges

**Model fit:** Substantial model required — stop if the active model is Luna or another lightweight model.  
**Priority:** P0 security  
**Expected size:** Medium  
**Primary files:** `hosts/hoth/default.nix`, `hosts/nixvm/default.nix`, container role module

### Tasks

- [ ] Inventory actual Docker workloads on `hoth` and `nixvm`.
- [ ] Remove Docker from `nixvm` if no declared or required workload uses it.
- [ ] Remove interactive users from the `docker` group where possible.
- [ ] Evaluate rootless Docker or Podman for interactive workflows.
- [ ] Keep root-managed service containers controlled by systemd rather than user group access.
- [ ] Document any remaining Docker group membership as root-equivalent access.
- [ ] Review `programs.nix-ld` and keep it only on roles that need it.

### Validation

- [ ] Evaluate user group membership on every NixOS host.
- [ ] Test required container workloads after activation.

### Done when

- [ ] No user has Docker-root capability without an explicit documented reason.
- [ ] Unused container daemons are disabled.

---

## Phase 16 — Make Zulip deployment reproducible

**Model fit:** Substantial model required — stop if the active model is Luna or another lightweight model.  
**Priority:** P0 security/reliability  
**Expected size:** Medium  
**Primary files:** `hosts/ferrix/zulip.nix`

### Tasks

- [ ] Pin every container image by immutable digest.
- [ ] Remove unconditional image pulls from normal service startup.
- [ ] Provide an explicit documented image-update workflow.
- [ ] Bind Zulip to localhost or the intended Tailscale address instead of all host addresses.
- [ ] Reduce the memcached password template from `0444` to `0400` if compatible.
- [ ] Verify whether `app:init` is idempotent; guard it with state if necessary.
- [ ] Review container capabilities, read-only filesystems, and `no-new-privileges` where supported by each image.
- [ ] Preserve persistent volume data.

### Validation

- [ ] Evaluate and build `ferrix`.
- [ ] Inspect the generated Compose file for digests and bind addresses without printing secrets.
- [ ] Test initial startup, restart, and reboot behavior.
- [ ] Confirm port 8080 is reachable only through the intended interface.

### Done when

- [ ] Rebuilding the same flake selects the same container images.
- [ ] Normal boot does not depend on a mutable registry pull.

---

## Phase 17 — Wire Immich secrets declaratively

**Model fit:** Substantial model required — stop if the active model is Luna or another lightweight model.  
**Priority:** P0 reliability/security  
**Expected size:** Small  
**Primary files:** `hosts/nixvm/default.nix`, `nixvm` secret file

### Tasks

- [ ] Replace the unmanaged `/run/secrets/immich` assumption with a sops secret or template.
- [ ] Include only variables required by the NixOS Immich module.
- [ ] Set root/service ownership and the narrowest mode that works.
- [ ] Add explicit service ordering if the module does not already derive it from the secret path.
- [ ] Confirm the external database configuration is intentional.

### Validation

- [ ] Evaluate and build `nixvm`.
- [ ] Test activation and inspect the Immich service status.
- [ ] Confirm secret contents do not appear in the Nix store or service logs.

### Done when

- [ ] Immich starts on a fresh system without manually creating `/run/secrets/immich`.

---

## Phase 18 — Harden Borg credentials and backup dependencies

**Model fit:** Substantial model required — stop if the active model is Luna or another lightweight model.  
**Priority:** P1 security/reliability  
**Expected size:** Small  
**Primary files:** `hosts/hoth/default.nix`, optional Borg module, `hoth` secrets

### Tasks

- [ ] Move the Borg SSH private key to a dedicated root-only sops secret.
- [ ] Stop reading `/home/mpfammatter/.ssh/id_ed25519` from a root-run service.
- [ ] Use a dedicated restricted BorgBase key.
- [ ] Add filesystem/service ordering for required backup sources.
- [ ] Decide whether missing `nofail` disks should skip or fail a backup, and encode that behavior.
- [ ] Remove stale Borg secret declarations.
- [ ] Add a safe periodic consistency check if operationally affordable.

### Validation

- [ ] Evaluate and build `hoth`.
- [ ] Run Borgmatic configuration validation.
- [ ] Perform a dry run or small test backup.
- [ ] Verify repository access uses only the dedicated key.

### Done when

- [ ] Borg no longer depends on a personal interactive SSH key.
- [ ] Missing source mounts cannot silently produce misleading successful backups.

---

# Milestone 5: Narrow package and application trust

## Phase 19 — Remove broad package exceptions

**Model fit:** Luna suitable for narrowing known exceptions; stop if package replacement or override design requires unresolved security tradeoffs.  
**Priority:** P1 security  
**Expected size:** Medium  
**Primary files:** `hosts/Coruscant/default.nix`, `hosts/exegol/default.nix`, `hosts/ferrix/default.nix`, `hosts/nixvm/default.nix`

### Tasks

- [ ] Replace broad `allowUnfree = true` with narrow predicates where practical.
- [ ] Remove the redundant predicate-plus-global-allow combination on `nixvm`.
- [ ] Remove `allowBroken = true` from `exegol`; use a package-specific override only if unavoidable.
- [ ] Determine whether Logseq can be updated, replaced, or run as a PWA so Electron 39 can be removed.
- [ ] Keep any insecure-package exception exact, documented, and host-scoped.
- [ ] Recheck whether disabling `direnv` tests is still necessary; keep the override host-scoped if it remains required.

### Validation

- [ ] Evaluate and build all affected Darwin and NixOS configurations.
- [ ] Confirm required unfree packages remain available.
- [ ] Confirm no unrelated broken package is globally permitted.

### Done when

- [ ] Every insecure, broken, or unfree exception has a named consumer and narrow scope.

---

## Phase 20 — Review remote-access and high-impact applications

**Model fit:** Luna suitable; stop if application ownership or network requirements are unclear.  
**Priority:** P1 security  
**Expected size:** Small  
**Primary files:** Homebrew roles, `users/modules/uiApps.nix`, relevant host modules

### Tasks

- [ ] Inventory Tailscale, RustDesk, Input Leap, remote desktop, and related agents by host.
- [ ] Remove tools from hosts that do not need them.
- [ ] Verify Input Leap uses authenticated/encrypted transport or is restricted to a trusted network.
- [ ] Keep remote-access applications out of the generic base profile.
- [ ] Document why each remotely reachable service is enabled.
- [ ] Remove stale `hosts/exegol/input-leap.conf` if the launch agent does not use it.

### Validation

- [ ] Evaluate affected hosts.
- [ ] Inspect listening services after activation.
- [ ] Confirm required remote-control workflows still function.

### Done when

- [ ] Remote-access software is opt-in by host rather than inherited globally.

---

# Milestone 6: Clean up Home Manager behavior

## Phase 21 — Fix SSH and sops activation scripts

**Model fit:** Substantial model required — shell quoting, permissions, and activation ordering are security-sensitive.  
**Priority:** P1 reliability/security  
**Expected size:** Small  
**Primary files:** `users/modules/ssh.nix`

### Tasks

- [ ] Guard `ensureSopsLogDir` so it runs only on Darwin.
- [ ] Correct `launchctl bootout ... && true` to intentional failure handling.
- [ ] Use fully qualified command paths in activation scripts where practical.
- [ ] Set `umask 077` before rendering SSH configuration.
- [ ] Create `~/.ssh` and `config.d` with mode `0700`.
- [ ] Render to a temporary file, set mode `0600`, and atomically rename it.
- [ ] Fail with a clear message if the sops source never appears.
- [ ] Consider `HashKnownHosts = true` as an explicit privacy decision.

### Validation

- [ ] Evaluate Linux and Darwin Home Manager profiles.
- [ ] Apply in dry-run mode where supported.
- [ ] Confirm generated directory and file permissions.
- [ ] Confirm Darwin launch agent reload is idempotent.

### Done when

- [ ] Linux no longer creates `~/Library/Logs/SopsNix`.
- [ ] SSH configuration is never briefly created with broad permissions.

---

## Phase 22 — Reassess persistent Windows secret exports

**Model fit:** Luna suitable for documentation or an explicitly chosen implementation; stop until the user chooses whether persistent export is acceptable.  
**Priority:** P1 security  
**Expected size:** Small planning/implementation session  
**Primary files:** `users/modules/espanso.nix`, `readme.md`

### Tasks

- [ ] Decide whether decrypted Espanso replacements should persist in the WSL filesystem for Windows access.
- [ ] If retained, document that Windows and WSL processes can access the exported data.
- [ ] Ensure parent export directories have narrow permissions.
- [ ] Prefer exporting only public Espanso configuration when private replacements are not required on Windows.
- [ ] Consider a Windows-native secret mechanism for sensitive replacements.
- [ ] Preserve mode `0600` for any retained private file.

### Validation

- [ ] Evaluate and apply the Linux Home Manager profile.
- [ ] Inspect exported file and parent-directory permissions.
- [ ] Test Espanso on Windows if behavior changes.

### Done when

- [ ] The decrypted Windows export is either removed or documented as an accepted exception.

---

## Phase 23 — Make the test profile generic and minimal

**Model fit:** Luna suitable  
**Priority:** P1 cleanup/security  
**Expected size:** Small  
**Primary files:** `users/test.nix`, `hosts/Tests-Virtual-Machine/default.nix`, Darwin app-role modules

### Tasks

- [ ] Remove personal Espanso secrets from the test profile.
- [ ] Remove personal Git identity or replace it with clearly fake test values.
- [ ] Install only applications needed to test nix-darwin and Home Manager integration.
- [ ] Avoid Tailscale in the test VM unless it is part of the test objective.
- [ ] Keep the test profile free of personal or production credentials.

### Validation

```sh
nix eval --raw '.#darwinConfigurations.Tests-Virtual-Machine.system.drvPath'
nix build '.#darwinConfigurations.Tests-Virtual-Machine.system'
```

### Done when

- [ ] The test VM can build without personal sops keys.
- [ ] It contains no production-only applications or network agents.

---

# Milestone 7: Split oversized modules without behavior changes

These phases should be mechanical. Do not combine module splitting with feature changes.

## Phase 24 — Split the zsh module

**Model fit:** Luna suitable if treated as a mechanical move with before/after comparisons; stop if ordering behavior cannot be verified.  
**Priority:** P2 maintainability  
**Expected size:** Medium  
**Primary files:** `users/modules/zsh.nix`, new `users/modules/zsh/*`

### Tasks

- [ ] Split aliases, shell functions, initialization, and integrations into separate modules.
- [ ] Preserve ordering where `mkBefore` or `mkAfter` matters.
- [ ] Keep platform conditionals near the behavior they control.
- [ ] Remove genuinely stale commented aliases only in a separate final pass.

### Validation

- [ ] Evaluate all Home Manager profiles.
- [ ] Compare resolved aliases and generated zsh configuration before and after.

### Done when

- [ ] `zsh.nix` is a short import/coordination module.
- [ ] Generated behavior is unchanged.

---

## Phase 25 — Split WezTerm core and appearance

**Model fit:** Substantial model required — the generated Lua is large and ordering-dependent.  
**Priority:** P2 maintainability  
**Expected size:** Medium  
**Primary files:** `users/modules/wezterm.nix`, new `users/modules/wezterm/*`

### Tasks

- [ ] Extract appearance, fonts, colors, platform detection, and base settings.
- [ ] Preserve Lua ordering and local-variable scope.
- [ ] Keep Windows export behavior outside the generated terminal configuration.
- [ ] Do not change keybindings in this phase.

### Validation

- [ ] Evaluate all Home Manager profiles.
- [ ] Compare generated `wezterm.lua` before and after.
- [ ] Run WezTerm's configuration validation if available.

### Done when

- [ ] Base and appearance concerns are independently readable.
- [ ] Generated Lua is behaviorally identical.

---

## Phase 26 — Split WezTerm keybindings and workspaces

**Model fit:** Substantial model required — the generated Lua and key-table behavior are ordering-dependent.  
**Priority:** P2 maintainability  
**Expected size:** Medium  
**Primary files:** remaining WezTerm module, new keybinding/workspace modules

### Tasks

- [ ] Extract leader keys and key tables.
- [ ] Extract workspace, pane, tab, and launch-menu logic.
- [ ] Keep OS-specific bindings in explicit platform sections.
- [ ] Update `docs/wezterm-cheatsheet.md` only if structure reveals stale documentation.

### Validation

- [ ] Compare generated `wezterm.lua` before and after.
- [ ] Test config loading on one Linux and one Darwin profile if available.

### Done when

- [ ] No single WezTerm source module remains excessively large.
- [ ] Keybinding behavior remains unchanged.

---

## Phase 27 — Split Nixvim foundation and editor behavior

**Model fit:** Substantial model required — this moves configuration across a very large module with upstream interactions.  
**Priority:** P2 maintainability  
**Expected size:** Medium  
**Primary files:** `users/modules/nixvim.nix`, new `users/modules/nixvim/*`

### Tasks

- [ ] Extract options, globals, filetypes, autocmds, and basic keymaps.
- [ ] Preserve imports from the upstream kickstart module.
- [ ] Keep plugin configuration in the original file for now.
- [ ] Compare generated Neovim configuration rather than relying only on evaluation.

### Validation

- [ ] Evaluate all Home Manager profiles.
- [ ] Run Neovim headlessly against the generated configuration.
- [ ] Compare startup errors before and after.

### Done when

- [ ] Core editor behavior is separated from plugins.
- [ ] No functional changes are introduced.

---

## Phase 28 — Split Nixvim plugins by domain

**Model fit:** Substantial model required — plugin dependencies and initialization order must be preserved.  
**Priority:** P2 maintainability  
**Expected size:** Medium to large; split into two sessions if needed  
**Primary files:** Nixvim modules

### Tasks

- [ ] Group plugins into navigation/UI, editing, Git, language/LSP, and completion modules.
- [ ] Preserve plugin dependency and initialization order.
- [ ] Keep plugin-specific keymaps next to their plugin unless broadly shared.
- [ ] Do not update plugin versions or behavior while moving configuration.

### Validation

- [ ] Evaluate Home Manager profiles.
- [ ] Run headless Neovim startup and health checks.
- [ ] Test representative LSP, completion, picker, and Git workflows.

### Done when

- [ ] Plugins are grouped by concern and can be changed independently.

---

## Phase 29 — Split Nixvim debugging and advanced integrations

**Model fit:** Substantial model required — DAP listeners and raw Lua integration are order-sensitive.  
**Priority:** P2 maintainability  
**Expected size:** Medium  
**Primary files:** Nixvim modules

### Tasks

- [ ] Extract DAP, test, terminal, AI, and other advanced integrations.
- [ ] Isolate raw Lua blocks behind clearly named modules.
- [ ] Revisit the existing temporary kickstart override and document its removal condition.
- [ ] Remove dead commented plugin configuration only after confirming it is obsolete.

### Validation

- [ ] Evaluate Home Manager profiles.
- [ ] Run headless startup.
- [ ] Test DAP initialization and shutdown listeners.

### Done when

- [ ] The Nixvim entry module is primarily imports and high-level options.

---

# Milestone 8: Final hygiene and operations

## Phase 30 — Remove dead files and stale declarations

**Model fit:** Luna suitable; stop rather than delete anything whose consumer cannot be disproved.  
**Priority:** P2 cleanup  
**Expected size:** Small  
**Primary files:** repository-wide, but deletion-only where possible

### Tasks

- [ ] Remove `hosts/modules/kmonad.nix` if still unused.
- [ ] Remove the commented kmonad flake input if there is no near-term plan to restore it.
- [ ] Remove `hosts/exegol/input-leap.conf` if still unused.
- [ ] Remove unused secret declarations after the secret migration is complete.
- [ ] Remove redundant packages available through Home Manager or another profile.
- [ ] Remove stale generated-template comments from host files.
- [ ] Confirm `.DS_Store`, editor sessions, build results, and local npm state remain ignored.

### Validation

```sh
git status --short
nix flake check --no-build --all-systems --keep-going --no-write-lock-file
```

### Done when

- [ ] Every remaining module and data file has a known consumer.
- [ ] No encrypted secret key remains merely because its declaration was forgotten.

---

## Phase 31 — Add host-focused CI checks

**Model fit:** Substantial model required — multi-platform flake outputs and runner capabilities require architectural judgment.  
**Priority:** P1 reliability  
**Expected size:** Medium  
**Primary files:** `flake.nix`, CI configuration, documentation

### Tasks

- [ ] Run formatting and static analysis in CI.
- [ ] Evaluate all NixOS and Darwin configurations.
- [ ] Build at least one representative Linux output per architecture.
- [ ] Build the Darwin test VM output on a Darwin runner if available.
- [ ] Add a dedicated package build for `pi-coding-agent`.
- [ ] Avoid accidental input updates in CI.
- [ ] Document the closest local equivalent for each CI check.

### Validation

- [ ] Run the CI commands locally where supported.
- [ ] Confirm each check is exposed under `checks.<system>` when appropriate.

### Done when

- [ ] A pull request cannot merge with formatting, evaluation, or representative build failures.

---

## Phase 32 — Refresh operational documentation

**Model fit:** Luna suitable  
**Priority:** P2 documentation  
**Expected size:** Small  
**Primary files:** `readme.md`, `docs/wiring-diagram.md`, `AGENTS.md`

### Tasks

- [ ] Correct the statement that Linux always uses standalone Home Manager; distinguish NixOS-integrated and standalone profiles.
- [ ] Update the wiring diagram for host constructors, role modules, and split secret files.
- [ ] Document SSH lockout precautions and secret key recovery.
- [ ] Document the pinned container image update process.
- [ ] Document host-specific build and test commands.
- [ ] Add newly discovered durable patterns to `AGENTS.md` without duplicating the README.

### Validation

- [ ] Verify every documented command names an existing flake output.
- [ ] Check links and Mermaid syntax.

### Done when

- [ ] Documentation matches the implemented architecture and recovery procedures.

---

# Final completion checklist

- [ ] `nix flake show` succeeds without schema warnings.
- [ ] `nix flake check --no-build --all-systems` succeeds.
- [ ] All touched Nix files are formatted.
- [ ] Every NixOS and Darwin top-level derivation evaluates.
- [ ] Representative host builds succeed.
- [ ] SSH password login and root login are disabled where SSH is enabled.
- [ ] Firewall openings are interface-scoped and documented.
- [ ] Samba writable directories are not world-writable.
- [ ] Interactive users do not have undocumented Docker-root access.
- [ ] Container images are pinned immutably.
- [ ] System secrets use root-controlled per-host identities.
- [ ] Secret recipients follow least privilege.
- [ ] Fresh hosts do not depend on undocumented password or secret-file creation.
- [ ] Broad `allowBroken` and insecure package exceptions are gone or narrowly justified.
- [ ] Test configurations contain no personal secrets.
- [ ] Large Home Manager modules are split by concern.
- [ ] Dead files and stale declarations are removed.
- [ ] Runtime-sensitive changes have been tested after activation.

# Session handoff template

Add this summary to the end of each coding-agent session or the relevant commit/PR description:

```markdown
## Phase N handoff

- Status: complete / partial / blocked
- Files changed:
  - `path/to/file`
- Decisions made:
  - ...
- Validation run:
  - `command` — passed/failed
- Manual validation still required:
  - ...
- Follow-up for next phase:
  - ...
```
