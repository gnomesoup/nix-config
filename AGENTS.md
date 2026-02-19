# AGENT OPERATIONS GUIDE
This repository manages multi-host NixOS, nix-darwin, and home-manager configurations.
Treat changes as infrastructure updates: prefer declarative changes and reversible edits.

## Mission & Mindset
- Prioritize reproducibility; every manual tweak should become a module or option.
- Default to the least privilege that satisfies the task; surface security tradeoffs.
- Keep host-specific logic encapsulated under `hosts/*`; avoid cross-host coupling.
- When in doubt, run `nix flake check` before pushing; assume CI mirrors that flow.
- Document assumptions inside modules rather than commit messages.

## Repository Layout
- `flake.nix` wires inputs (nixpkgs, nix-darwin, home-manager, sops-nix, nixvim).
- `hosts/<name>/default.nix` contains machine-specific modules; hardware files live adjacent.
- `hosts/modules/` provides reusable building blocks (fonts, nixvim, appleDefaults, etc.).
- `users/*.nix` define home-manager profiles plus shared module fragments under `users/modules`.
- `secrets/` stores sops-encrypted material; never commit decrypted data.
- `readme.md` covers quick start; expand on details here when you learn new patterns.

## Toolchain & Environment
- Requires Nix flakes (`nix` >= 2.18) and `darwin-rebuild` or `nixos-rebuild` depending on host.
- Home-manager is consumed as a module; do not run standalone commands unless necessary.
- Formatting relies on `nixfmt-rfc-style` plus `nixpkgs-fmt`; they can be invoked via `nix fmt`.
- Preferred shells are zsh + starship; alias files live under `users/modules/zsh.nix`.
- Keep Determinate Systems installers in mind when touching flake inputs.

## Core Build Commands
- `nix flake show` — inspect available systems and outputs.
- `nix flake check` — run evaluation, formatting, and defined checks for all systems.
- `nixos-rebuild build --flake .#hoth` — build the NixOS configuration without activating.
- `nixos-rebuild test --flake .#hoth` — dry-run activation; use before touching production hosts.
- `nixos-rebuild switch --flake .#hoth` — activate immediately on the `hoth` host.
- `darwin-rebuild build --flake .#Coruscant` — build macOS profile offline.
- `darwin-rebuild test --flake .#Coruscant` — validate macOS changes without switching.
- `darwin-rebuild switch --flake .#Coruscant` — apply macOS changes.
- `home-manager switch --flake .#mpfammatter` — use only for debugging user profiles.
- `nix build .#darwinConfigurations.Tests-Virtual-Machine.system` — CI-friendly macOS build artifact.

## Targeted Tests
- `nix flake check .#nixosConfigurations.hoth` — limit checks to a single host.
- `nix flake check --impure --keep-going` — include impure bits when needed and continue on failure.
- `nix eval .#nixosConfigurations.hoth.config.services.samba` — spot-check option trees.
- `nix build .#checks.x86_64-linux.<checkName>` — run an individual check output once defined.
- `nixos-rebuild test --flake .#nixvm` — best proxy for “single test” on NixOS desktop hosts.

## Lint & Formatting
- `nix fmt` — run repo-wide formatting; configure `nixfmt-rfc-style` in devShells if needed.
- `nix fmt hosts/hoth/default.nix` — scope formatting to a single file before committing.
- Prefer `nixpkgs-fmt` for quick diffs when editing on macOS; keep indentation at two spaces.
- Align attribute assignments and list entries as shown in existing modules.
- Use `git diff` to ensure no unexpected reformatting of large attrsets.

## Secrets & Credentials
- Secrets are encrypted with `sops-nix`; reference them via `config.sops.secrets.<name>.path`.
- Never stage files under `secrets/` in plain text; `.sops.yaml` should govern encryption (add if missing).
- Avoid printing secret paths in logs; prefer `${config.sops.secrets."foo".path}` style expansions.
- When testing sops changes, run `nix build .#nixosConfigurations.hoth.config.system.build.toplevel` locally.

## Code Style: Imports & Structure
- Module files should start with `{ pkgs, ... }:` (extend with `self`, `vars`, etc. only when used).
- Keep `imports` at the top, followed by package lists, service definitions, and finally system metadata.
- Sort imports alphabetically, grouping local modules before remote overlays when applicable.
- Place inline comments above the block they describe; avoid trailing comments unless short.
- For host files, maintain the pattern: imports → secrets → boot → nix settings → networking → locale → users → packages → services → footers.
- In user modules, configure `home` first, then `programs`, then `home.packages`.

## Formatting & Types
- Use two spaces for indentation; avoid tabs except when required by heredocs.
- Strings default to double quotes; prefer `''` multiline strings for shell snippets.
- Attribute names with slashes require quotes (`"borg/borg_passphrase"`).
- Lists should stay on one line when short; otherwise break into one entry per line with trailing comma omitted.
- Prefer explicit types (booleans, ints) over stringly values; consult `nixos-option` for expected types.

## Naming Conventions
- Hosts follow canon names (e.g., `hoth`, `Coruscant`); keep lowercase for Linux, capitalized for macOS as observed.
- Module files use kebab-case; functions or attrsets use camelCase (e.g., `home.packages`).
- Secrets keys mirror directory structure (`borg/borg_passphrase`); keep names stable to avoid re-encryption.
- Git branches: `feat/<topic>`, `fix/<bug>`, or `chore/<task>`.

## Error Handling & Validation
- Fail fast: if an option might be unset, guard with `lib.mkDefault` or `lib.mkIf config.services...`.
- Prefer `assertions = [{ assertion = condition; message = "reason"; }];` for invariants.
- Use `lib.warn` sparingly to highlight transitional states.
- When services rely on filesystems, set `x-systemd.device-timeout` or Samba `nofail` as shown in `hosts/hoth`.
- Check `journalctl -u <service>` after activating; summarize findings in PRs when relevant.

## Git Workflow
- Use feature branches; keep main clean for reproducible builds.
- Run `git status` before and after formatting to ensure only intended files change.
- Commit messages: `<verb>: <short description>` (e.g., `fix: align samba users`).
- Never commit decrypted secrets or machine-specific cache files.
- Include the relevant build/test command in the PR description.

## Documentation & Comments
- Extend this guide when you discover new host patterns; keep sections concise but actionable.
- Only add inline comments for non-obvious hardware quirks or temporary workarounds.
- Update `readme.md` when onboarding steps change; cross-link here as needed.

## Cursor / Copilot Rules
- No `.cursor/rules` or `.cursorrules` present at this time.
- No `.github/copilot-instructions.md` present; follow this document instead.

## Common Pitfalls
- Forgetting to enable `nix-command flakes` on new hosts stalls rebuilds—mirror existing settings.
- Missing `home-manager.backupFileExtension` duplicates dotfiles; keep it consistent with flake outputs.
- Darwin hosts require `nix-daemon.enable = true`; ensure services stanza matches `Coruscant` pattern.
- Samba shares on `hoth` expect matching system users; do not rename without updating `services.samba.settings`.
- `immich` service on `nixvm` assumes an external secrets file; never bake credentials directly.

## Reference Checklist Before Opening a PR
- [ ] Run `nix fmt` on touched files.
- [ ] Run `nix flake check` (or host-scoped variant) locally.
- [ ] For OS changes, run `*-rebuild test --flake` on a representative host.
- [ ] Verify no unencrypted files under `secrets/` changed.
- [ ] Summarize verification commands in the PR body.
- [ ] Note any required manual steps (e.g., `smbpasswd`) in commit or AGENTS notes.

## Contact & Escalation
- If a rebuild fails due to upstream flakes, consider pinning via `inputs.<name>.rev` update.
- For Determinate Systems installer issues, consult their docs linked in `readme.md`.
- Keep TailScale credentials secure; enabling service on macOS requires admin rights.

## Quick Commands Cheat Sheet
- Update inputs: `nix flake update` (run with care, review `flake.lock`).
- Garbage collect build artifacts: `nix-collect-garbage --delete-older-than 7d` (alias `garbage`).
- Switch active host automatically on macOS: `drs` alias → `sudo darwin-rebuild switch --flake ~/nix-config#$(scutil --get LocalHostName)`.
- Switch active host automatically on NixOS: `nrs` alias → `sudo nixos-rebuild switch --flake ~/nix-config#$(hostname)`.
- Upload and prune downloads via Immich CLI: `iud` alias in zsh module.

Keep this handbook close; update it when reality diverges.
