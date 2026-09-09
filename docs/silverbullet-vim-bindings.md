# SilverBullet per-browser Vim layout

Phase 9 uses a first-party SilverBullet plug rather than generated Space Lua configuration. Nix builds one immutable `silverbullet-vim-layout.plug.js` and synchronizes the exact compiled bytes to both spaces at `_plug/silverbullet-vim-layout.plug.js`.

SilverBullet layout selection is independent of `vimBindingKeyboardLayout`. That option remains the source of truth for Nixvim, WezTerm, Zsh, Herdr, and other host-managed consumers, but it does not select a SilverBullet layout at build or deployment time.

## Commands and persistence

The plug provides four command-palette commands, with no keyboard shortcuts or modifier bindings:

- `Vim Layout: QWERTY`
- `Vim Layout: Colemak-DH`
- `Vim Layout: Toggle`
- `Vim Layout: Show`

The selection is stored under `vim-layout.selection` through SilverBullet's `clientStore` syscall. An absent or invalid value means QWERTY. Explicit QWERTY applies `set langmap=` and clears any prior native langmap.

`clientStore` is browser-local, not synchronized to the server. SilverBullet backs it with the browser's IndexedDB datastore under the `client` prefix. The database name is derived from both the space folder and `document.baseURI`, so Personal and KSP use distinct stores. Browser profiles also have separate IndexedDB storage. As a result:

- Personal and KSP remember their selections independently;
- Firefox profiles remember their selections independently;
- choosing Colemak-DH in one space or profile does not change another;
- every unset space/profile starts as QWERTY.

Authoritative SilverBullet 2.10 references are `client/plugos/syscalls/clientStore.ts`, `client/client.ts`, `client/data/indexeddb_kv_primitives.ts`, and `plug-api/syscalls/client_store.ts`.

## Native langmap

The plug calls `editor.vimEx` with codemirror-vim's native option:

```vim
set langmap=mh,nj,ek,il,kn,KN,li,LI,fe,FE,hm,tf,TF,jt,JT,NJ
```

QWERTY clears it with:

```vim
set langmap=
```

The Colemak-DH pairs are generated and asserted from `users/modules/vimBindingLayouts.nix`; they are not generated from the currently selected layout. Native `langmap` performs command-key translation in normal, visual, and operator-pending contexts. It also preserves the literal character following commands such as `f` and `t`, and ordinary insert-mode text remains the physical typed character.

No `map`, `noremap`, `unmap`, `vim.map`, or `vim.unmap` configuration is generated. The plug manifest assigns no `key` or `mac` shortcuts, so it does not claim modifier combinations or browser shortcuts. SilverBullet's command-key precedence and codemirror-vim's own native langmap semantics remain unchanged.

## Initialization and lifecycle

`editor.vimEx` reports either `Vim module not loaded.` or `Vim mode not active or not initialized.` while SilverBullet's asynchronous Vim extension is still being constructed. The plug treats only those two initialization races as retryable. It makes at most six attempts using delays of 0, 50, 100, 200, 400, and 800 milliseconds. Unexpected errors fail immediately. Vim-disabled clients perform no Ex call and apply the stored choice when Vim is later enabled.

Applications are serialized, and overlapping lifecycle requests are coalesced. They are triggered by these public plug events:

- `plugs:loaded`
- `editor:init`
- `editor:modeswitch`
- `editor:pageLoaded`
- `editor:pageReloaded`

This covers initial plug loading, page/editor initialization, Vim toggles, and editor replacement without patching SilverBullet itself. Explicit commands show success, deferred-while-disabled, or failure notifications. Background lifecycle failures are logged without repeated UI notifications.

## Source and build

- Plug source: `hosts/ferrix/silverbullet-vim-layout/vim-layout.ts`
- Manifest: `hosts/ferrix/silverbullet-vim-layout/silverbullet-vim-layout.plug.yaml`
- Isolated tests: `hosts/ferrix/silverbullet-vim-layout/vim-layout.test.ts`
- Nix package: `hosts/ferrix/silverbullet-vim-layout/package.nix`
- Semantic generator: `users/modules/silverbullet-vim-layout-lib.nix`
- Hardened synchronizer: `hosts/ferrix/silverbullet-plug-sync.py`
- Synchronizer tests: `hosts/ferrix/silverbullet-plug-sync_test.py`

The package uses the pinned SilverBullet 2.10.0 frontend dependency set and upstream `plug-compile` implementation. Its version assertion intentionally fails when SilverBullet changes so the syscall and bundling assumptions must be reviewed.

## Synchronization and security

The `silverbullet-plug-sync.service` oneshot:

1. reads the runtime sops token only as the unprivileged `mpfammatter` user;
2. waits for the loopback-only SilverBullet server;
3. reads only `_plug/silverbullet-vim-layout.plug.js` in Personal and KSP;
4. writes only when bytes or `rw` metadata differ;
5. reads the plug back and requires exact byte equality;
6. refuses redirects, limits response sizes, validates token ownership/mode, and redacts errors.

The service has no Home Manager dependency or writable home access. It remains active after a successful run so a changed immutable plug or synchronizer restart trigger reruns it on the next NixOS switch. It does not request, modify, or delete `CONFIG.md` or `CONFIG/Vim Bindings.md`.

## Deployment and legacy cleanup

No live page or service is changed merely by building this configuration. Deployment is intentionally separate:

```bash
cd /home/mpfammatter/nix-config
sudo nixos-rebuild switch --flake .#ferrix
```

Then:

1. Check `systemctl show silverbullet-plug-sync.service -p Result -p ExecMainStatus`.
2. In Personal and KSP, run `Space: Reindex` followed by `Plugs: Reload` for deterministic first discovery of the externally installed plug. A later full browser reload is also a useful smoke test.
3. Run `Vim Layout: Show`, select the desired layout independently in each browser/space, toggle Vim off/on, change pages, and test normal, visual, operator, `f`/`t` literal targets, and insert text.
4. Verify QWERTY clears Colemak-DH in the same browser session and remains selected after reload.

The previously synchronized live `CONFIG/Vim Bindings.md` pages are deliberately left untouched by this change. They can still run their old mapping configuration and therefore must be retired as an explicit follow-up rather than silently deleted by deployment. After the plug bytes and commands are verified, back up and delete only `CONFIG/Vim Bindings.md` in Personal and KSP, then reindex/reload scripts and plugs in each space. Never alter either space's existing `CONFIG.md`.
