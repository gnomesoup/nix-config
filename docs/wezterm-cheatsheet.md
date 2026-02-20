# WezTerm Cheat Sheet

Neovim-style terminal navigation is powered via home-manager (`users/modules/wezterm.nix`). The key setup mirrors Colemak remaps from the `nixvim` module.

## Modes
- **Insert mode**: default terminal input; space behaves normally.
- **Leader mode**: tap `Space` (in normal mode) to open one-shot leader bindings.
- **Vi copy/search modes**: same Colemak arrows are available when selecting/searching text.

## Cursor / Word Motion (Leader)
| Sequence | Action |
| --- | --- |
| `Space m` | ← (Left arrow) |
| `Space n` | ↓ (Down arrow) |
| `Space e` | ↑ (Up arrow) |
| `Space i` | → (Right arrow) |
| `Space M` | ← with Shift (select) |
| `Space N` | ↓ with Shift |
| `Space E` | ↑ with Shift |
| `Space I` | → with Shift |
| `Space f` | End |
| `Space F` | Shift+End |
| `Space t` | Home |
| `Space T` | Shift+Home |

## Pane Management
| Sequence | Action |
| --- | --- |
| `Space s` | Split horizontally |
| `Space v` | Split vertically |
| `Space w` | Close current pane (confirm) |
| `Space p` | Pane select (swap active) |
| `Space P` | Pane select with `m n e i` hints |
| `Space h/j/k/l` | Focus pane ← ↓ ↑ → |
| `Space z` | Toggle pane zoom |
| `Space d` | Rotate panes clockwise |
| `Space D` | Rotate panes counter-clockwise |

## Tabs & Workspace
| Sequence | Action |
| --- | --- |
| `Space c` | New tab (command in current domain) |
| `Space t` | New empty tab |
| `Space q` | Close current tab (confirm) |
| `Space g` | Next tab |
| `Space b` | Previous tab |
| `Space r` | Rename tab |

## Utilities
| Sequence | Action |
| --- | --- |
| `Space x` | Clear scrollback |
| `Space Space` or `Space Esc` | Exit leader table |

## Copy/Search Mode Keys
- `m n e i` still move left/down/up/right.
- `M/I` shift variants move by words.
- Tapping `Space` while in copy/search modes re-enters leader state without leaving the mode.

## Troubleshooting
- Config lives at `~/.config/wezterm/wezterm.lua` (managed by home-manager).
- Run `home-manager switch --flake .#mpfammatter` (or relevant profile) after edits.
- For macOS builds, use `darwin-rebuild test --flake .#Coruscant`; for Linux `nixos-rebuild test --flake .#nixvm`.
