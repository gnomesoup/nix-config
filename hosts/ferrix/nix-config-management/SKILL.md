---
name: nix-config-management
description: Manage this Nix flake with grounded lookups and checks.
version: 0.1.0
author: Michael Fammatter, Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [nix, nixos, home-manager, nix-darwin]
    related_skills: []
---

# Nix Config Management

Safely maintain the multi-host flake in the current working directory. Prefer declarative, reversible changes and verify package and option details against current sources.

## When to Use

- Use for NixOS, Home Manager, nix-darwin, Nixvim, package, flake-input, or host configuration work in this repository.
- Use for evaluating, formatting, building, or diagnosing this flake.
- Do not activate a configuration, update unrelated inputs, commit, push, or decrypt secrets unless the user explicitly requests it.

## Prerequisites

- The `nixos` MCP server must be available. Use its `nix` tool, registered by Hermes as `mcp_nixos_nix`, before making package or option decisions.
- Work from the repository root supplied as the session working directory.
- Follow `AGENTS.md` and host-local conventions.

## Procedure

1. Synchronize repository state before inspecting or editing:
   - Run `git fetch --prune origin`, `git status --short --branch`, and `git rev-list --left-right --count HEAD...origin/main` with `terminal`.
   - If the worktree is clean and `HEAD` is behind without being ahead, run `git pull --ff-only`, then repeat the status and revision-count checks.
   - If the worktree is dirty, the branch has diverged, or the fetch fails, do not merge, rebase, stash, reset, or begin configuration work. Report the blocker and preserve every local change.
   Repository preparation is complete only when the fetch succeeds and the local/remote relationship is known.
2. Inspect relevant files with `search_files` and `read_file`. Every intended edit must be scoped to files understood from their definitions and usages.
3. Query `mcp_nixos_nix` before choosing or changing packages and options:
   - NixOS: `source="nixos"`
   - Home Manager: `source="home-manager"`
   - nix-darwin: `source="darwin"`
   - Nixvim: `source="nixvim"`
   Use `action="search"` for discovery and `action="info"` for exact declarations. The selected option or package must be confirmed by the result rather than inferred from memory.
4. Apply the smallest declarative edit with `patch`. Keep host-specific behavior under `hosts/<name>/`; use shared modules only when multiple hosts genuinely need the behavior. Do not touch plaintext under `secrets/`.
5. Format only touched Nix files with `terminal(command="nix fmt <paths...>")`. Review `git diff --check` and `git diff`; every changed line must belong to the request.
6. Run the narrowest useful evaluation or build first. For ferrix, use `nix build .#nixosConfigurations.ferrix.config.system.build.toplevel --no-link`; for another host, use its matching configuration output. Run broader `nix flake check` when the change crosses hosts or shared modules.
7. Run `git status --short` after verification. Report changed paths, the exact verification commands, and any activation step that still requires the administrator.

## Pitfalls

- MCP results describe upstream sources; repository-specific values still require local `nix eval` or a build.
- A dirty worktree is never permission to stash or discard another session's changes. Stop before pulling and ask the user to resolve or commit them.
- A successful evaluation does not prove activation. Never claim the running host changed without a successful rebuild and read-back.
- Avoid updating every input for a single dependency; use `nix flake update <name>` and inspect `flake.lock` churn.
- The `inigo` service account has no sudo privileges. Leave `nixos-rebuild switch` to the administrator unless privilege is explicitly provided.
- Never print decrypted SOPS values, environment files, deploy keys, or credential paths.

## Verification

A change is complete only when formatting passes, the relevant evaluation or build succeeds, `git diff --check` is clean, and `git status` shows only intentional files.
