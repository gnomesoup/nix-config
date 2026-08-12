# Color Swatches Parser Migration Plan

## Goal

Replace the handwritten CSS color parsing and conversion logic in `color-swatches.ts` with a maintained, tested library while preserving the extension's useful formats and fixing the parser-related accuracy issues found during review.

## Nix management

The extension and this migration plan are managed by Home Manager from:

```text
users/modules/pi/extensions/
├── color-swatches.ts
└── color-swatches-parser-plan.md
```

`users/modules/pi.nix` links both files into `~/.pi/agent/extensions/`. Make changes to the repository copies rather than editing the generated files in the home directory, and update this plan whenever the extension's implementation or migration status changes.

The current extension provides `/color-swatches [on|off|toggle]`. With no argument, the command toggles highlighting for the current extension runtime; restarting Pi or running `/reload` resets highlighting to enabled.

## Selected parser

Use **Culori `4.0.2`**, pinned exactly, with **`@types/culori` `4.0.1`** as a pinned development dependency.

Why Culori:

- It has a substantial automated test suite and dedicated parsing/conversion modules.
- It correctly parses the standard forms currently recognized by the extension: short/long hex with alpha, `rgb()`/`rgba()`, `hsl()`/`hsla()`, `hwb()`, and `color(srgb ...)`.
- Its angle handling correctly converts `grad`, `rad`, `turn`, and degrees.
- It retains alpha and converts supported color spaces to normalized sRGB.
- It provides tested WCAG luminance and contrast functions.
- It is materially smaller than Color.js and loaded successfully through pi's extension/Jiti runtime in a local smoke test.

Known boundaries:

- `0xRRGGBB` and `hsv()`/`hsva()` are not CSS color strings and are not parsed directly by Culori.
- Culori may return `undefined` or throw for malformed candidates, so the adapter must handle both outcomes.
- Candidate detection remains the extension's responsibility; a regex may identify candidates, but only the parser decides whether they are valid colors.

## Target layout

Convert the single-file extension into a dependency-scoped extension directory in the Nix source tree:

```text
users/modules/pi/extensions/
├── color-swatches-parser-plan.md
└── color-swatches/
    ├── index.ts
    ├── color-parser.ts
    ├── ansi-rendering.ts
    ├── package.json
    ├── package-lock.json
    └── test/
        ├── color-parser.test.ts
        └── rendering.test.ts
```

Update `users/modules/pi.nix` to link the directory into `~/.pi/agent/extensions/color-swatches/`. Remove the managed `color-swatches.ts` entry only after the directory version passes its smoke tests. Do not leave both entry points active because pi would load the extension twice.

## Implementation phases

### 1. Establish the behavior contract

Before replacing the parser, create table-driven tests for:

- `#rgb`, `#rgba`, `#rrggbb`, and `#rrggbbaa`.
- `rgb()`/`rgba()` using legacy commas, modern spaces, percentages, and alpha.
- `hsl()`/`hsla()` using `deg`, `grad`, `rad`, and `turn`.
- `hwb()` and `color(srgb ...)`.
- Uppercase forms and boundary matching.
- Out-of-gamut channels and the terminal clipping policy.
- Malformed values such as `rgb(1oops 2 3)`, missing channels, extra channels, bad units, and unterminated functions.
- Alpha values of `0`, fractional values, and `1`.

Record expected normalized sRGB and alpha, not ANSI output, in parser tests.

### 2. Add isolated package metadata

- Create `color-swatches/package.json` rather than placing dependencies in the shared `extensions` directory.
- Pin `culori` to `4.0.2`; do not use `^` or `~`.
- Pin `@types/culori` to `4.0.1` as a development dependency.
- Use Node's test runner through a small pinned TypeScript runner such as `tsx`.
- Commit/create `package-lock.json` for reproducible installation.
- Add scripts for `test`, type checking, and the pi RPC smoke test where practical.

### 3. Introduce a narrow parser adapter

Create `color-parser.ts` with one public operation:

```ts
parseColor(candidate: string): { r: number; g: number; b: number; alpha: number } | undefined
```

Implementation rules:

1. Create Culori's `converter("rgb")` once at module load.
2. Normalize an exact `0xRRGGBB` candidate to `#RRGGBB` before parsing.
3. Pass standard CSS candidates to `parse()` inside `try`/`catch`.
4. Convert successful results to sRGB.
5. Reject missing, nonnumeric, or non-finite channels after conversion.
6. Clip normalized sRGB channels to `[0, 1]` only at the terminal-output boundary, then round to `[0, 255]`.
7. Preserve alpha in the result and make the display policy explicit.

For nonstandard `hsv()`/`hsva()`, choose one of these approaches during implementation:

- **Preferred compatibility option:** retain a small, strict grammar adapter that produces Culori's `hsv` object and delegates all color conversion to Culori.
- **Simplest standards-only option:** drop `hsv()`/`hsva()` support and document the intentional behavior change.

Do not retain the current general-purpose number, angle, RGB, HSL, HSV, or HWB conversion helpers.

### 4. Simplify candidate matching

- Keep matching separate from parsing.
- Use the matcher only to locate plausible color literals.
- Require parser success before applying a swatch.
- Ensure matching never consumes newlines or unrelated closing delimiters.
- Add tests showing malformed candidates remain unchanged.

### 5. Make rendering ANSI-safe

The parser replacement alone will not fix the rendering issues from the review. Refactor rendering at the same time:

- Call the original `Markdown.render()` first; never inject ANSI into Markdown source before lexing.
- Apply swatches to rendered lines so Markdown links and code parsing receive untouched source.
- Skip CSI, OSC, and APC terminal escape payloads while looking for color candidates.
- Preserve and restore the active foreground/background/style state around each swatch instead of ending with unconditional `39m`/`49m` resets.
- Verify URLs containing fragments such as `/#fff` remain intact.
- Prefer a shared prototype-patching helper for `Markdown` and `Text`.
- Store the installed wrapper and restore the original method only if the wrapper is still current, so shutdown cannot remove another extension's later patch.
- Avoid direct mutation of the private `text` field.

### 6. Correct contrast handling

- Use Culori's tested `wcagContrast()` or `wcagLuminance()` rather than the current gamma-encoded luminance approximation.
- Compare black and white contrast and select whichever is higher.
- Add regression tests for mid-gray colors such as `#777`, `#808080`, and `#888`.

Alpha cannot be represented directly by an ANSI background. For the first migration, preserve the existing base-RGB preview only if it is explicitly named and documented as the alpha policy. Keep alpha in the parsed result so a later theme-aware compositing policy does not require another parser change.

### 7. Validation

Run all of the following before activating the replacement:

1. Parser unit tests for valid, invalid, boundary, angle, gamut, and alpha cases.
2. Rendering regressions proving:
   - Markdown links with hex-looking fragments still parse normally.
   - Syntax highlighters receive source without injected ANSI.
   - Existing themed text resumes its prior style after a swatch.
   - OSC hyperlinks are byte-for-byte unchanged.
   - Rendered line widths remain within the TUI width.
   - Shutdown does not overwrite a later prototype wrapper.
3. Type checking against the installed pi and pi-tui APIs.
4. Isolated startup:

   ```bash
   printf '{"type":"get_state"}\n' | \
     pi --mode rpc --no-session --offline --no-extensions \
       --extension ~/.pi/agent/extensions/color-swatches/index.ts
   ```

5. Interactive `/reload` in pi, followed by visual checks of Markdown, tool output, links, code blocks, light colors, dark colors, and narrow terminal wrapping.
6. Reload/shutdown/restart checks to catch duplicate or stale prototype patches.

## Acceptance criteria

- No handwritten conversion remains for CSS RGB, HSL, HWB, hex, or `color(srgb ...)`.
- `100grad` produces the same sRGB result as `90deg`.
- Malformed numeric tokens do not produce swatches.
- Alpha is retained by parsing and handled by an explicit display policy.
- Markdown parsing, syntax highlighting, and OSC hyperlinks are not modified by candidate detection.
- Surrounding ANSI styles are restored after every swatch.
- Black/white foreground selection uses proper contrast calculations.
- The extension loads exactly once and survives `/reload`, session replacement, and shutdown.
- Dependencies and development tooling are pinned and reproducible.

## Rollback

Before activating the directory extension, keep a non-loadable backup in `users/modules/pi/extensions/`, such as `color-swatches.legacy.ts.disabled`. If startup or rendering validation fails, restore the original `color-swatches.ts` Home Manager entry, rebuild the Home Manager configuration, and run `/reload`.
