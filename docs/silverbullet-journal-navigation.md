# SilverBullet journal navigation

The Personal and KSP spaces receive a Nix-managed journal calendar and navigation header.

## Behavior

- The calendar action button has priority `2.9`, placing it immediately after the default Home button (`3`). `dropdown = false` keeps it visible beside Home on mobile.
- `Journal: Calendar` opens a month grid. It starts on the current journal date, or today outside a journal, and marks exact existing `Journal/YYYY-MM-DD` pages with a dot.
- Selecting a date invokes the hidden, validated `Journal: Open Date` Space Lua command. That command delegates to `journal.openOrCreate`, preserving the configured journal prefix and `Journal/Template` creation behavior.
- `hooks:renderTopWidgets` adds Previous and Next links to every exact dated journal page without modifying page content. The links use `journal.neighbor`, so they skip dates without existing tagged entries.

## Managed files

- Plug source and tests: `hosts/ferrix/silverbullet-journal-navigation/`
- Space Lua and Space Style: `hosts/ferrix/silverbullet-journal-navigation/journal-navigation.md`
- Deployment wiring: `hosts/ferrix/silverbullet.nix`

The sync service writes the compiled plug to `_plug/silverbullet-journal-navigation.plug.js` and the configuration to `_config/journal-navigation.md` in both spaces.

## Validation

```sh
nix build .#checks.x86_64-linux.silverbullet-journal-navigation
nix flake check -L
```

The package intentionally asserts SilverBullet 2.10.0 so upgrades require reviewing the panel, command, action-button, and top-widget APIs.
