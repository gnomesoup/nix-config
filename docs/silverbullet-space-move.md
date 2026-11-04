# SilverBullet linked-collection mover

The Nix-managed `silverbullet-space-move` plug adds **Space: Move linked
collection…** to Personal and KSP. It runs inside SilverBullet, independently of
Inigo, using the signed-in browser session and SilverBullet's native file API.
It contains no assistant token, password, cookie-export mechanism, or transfer
backend.

## Operator workflow

1. Open the source Markdown page and invoke the command from the command palette.
2. The command saves the editor, checks its text against the server, and reads both
   authorized inventories. Discovery makes no changes.
3. Review outgoing dependencies and incoming references. Uncheck anything that
   should stay. Shared hubs and incoming pages are unchecked by default; whole
   daily journals and managed files cannot be selected.
4. Use the search/type filters and explicit expansion controls as needed. The scan
   limit applies across both spaces; the depth limit applies to graph traversal.
   Incomplete discovery is reported, never presented as a complete audit.
5. Choose **Review changes**. Inspect every destination write/automatic merge and
   every link-only edit to a retained page. The before/after previews are escaped
   text, not executable note content.
6. Confirm the review, then choose **Move selected**. Stop requests take effect at
   a safe checkpoint after the current request, not as an atomic rollback.
7. Read the completion report. A partial result requires resuming the existing
   operation, not starting a new move with the same selection.

The command infers the opposite configured space: Personal at `/`, KSP at `/ksp`.
Both spaces must be on the same browser origin. Server-side permissions remain
mandatory for every request. Authentication redirects and revision conflicts stop
an operation rather than silently retrying it.

## Discovery and links

Discovery uses SilverBullet's actual Markdown parser and path resolver, including
canonical paths, display aliases, relative document paths and supported reference
fragments. CRLF offsets are mapped back to the original source before editing.
Only explicit relationships are discovered; there is no semantic/AI classifier or
mixed-journal section extraction.

| Referring file | Target | Reviewed result |
| --- | --- | --- |
| Moved | Moved | Destination-local canonical reference |
| Moved | Retained | Explicit original-space URL |
| Retained | Moved | Explicit destination-space URL |
| Retained | Retained | Unchanged |
| Missing locally, verified in the other space | Existing other-space file | Explicit verified URL |
| Missing in both spaces | Missing file | Warning; no invented destination |

Incoming explicit cross-space references are inspected in the destination space
as well, so reverse moves can repair earlier cross-space links. Code examples are
not rewritten. Cross-space page transclusions cannot be replaced with ordinary
hyperlinks without changing behavior, so an affected transclusion blocks the plan.
Ambiguous or unsupported affected references block the move until repaired.
This includes metadata/frontmatter relationships, reference-style definitions,
naked URLs/autolinks and query-bearing links that cannot be safely rewritten.
Managed Markdown is scanned for incoming references but is never edited by the
mover; an affected managed reference must first be repaired declaratively.

The initial scan limit is 1,000 Markdown pages across both spaces. The dialog can
raise it to 5,000 or 10,000. Note discovery is capped at 128 MiB in aggregate;
individual transfers are capped at 64 MiB. Document bodies are loaded only for the
selected transfer plan, not for graph metadata discovery.

## Automatic Markdown merging

A different same-path Markdown destination is not silently overwritten. The
review shows a deterministic, lossless union:

- Existing destination content remains intact.
- Missing complete source sections are added with provenance markers.
- Repeated identical sections are not added twice during retries.
- Simple `aliases` and `tags` metadata can be combined safely.
- Conflicting scalar metadata, unsupported YAML, duplicate anchors/headings,
  malformed fences and reserved-marker ambiguity stop automatic merging.
- A different binary destination blocks the move. Identical binaries are reused
  only after byte verification.

This is structural merging, not a three-way history merge or semantic judgment
about which divergent sentence is correct. A blocked merge retains the source.

## Safety, records and recovery

The engine freezes the reviewed bytes, checks revisions, and uses create-only or
exact-revision conditional writes. It archives originals, verifies destination
bytes and approved link edits, then rechecks the complete safety barrier before
removing each source. Another browser or offline client can still make concurrent
changes; the operation is not a multi-file transaction.

Selected source originals are preserved in the source space at:

```text
Trash/Space Moves/<operation-id>/<source-path>
```

When a destination was merged, its previous original is preserved in the
**destination** space under the same operation/path layout. Do not delete these
copies while an operation is incomplete.

Operation records live in the original source space:

```text
Space Moves/Operations/<operation-id>.json
```

Records contain identifiers, paths, revisions, digests, checkpoints and narrow
inverse link edits, not complete retained-page bodies or credentials. Resume
reconstructs the frozen plan from live files and verified recovery copies. Changed
content or hashes stop reconciliation; they do not authorize an overwrite.

The dialog lists stored operations and accepts an exact operation ID. A resumed
plan is reviewed again before execution. Journal failures are reported separately
from content changes; recovery must not repeat an already verified mutation merely
to repair its activity entry.

Activity entries use `America/New_York` dates, preserve existing daily-journal
content, and carry deterministic operation markers for sequential retry
idempotence. Whole daily journals remain excluded from automatic collection moves
because they can contain unrelated personal/work sections.

## Declarative deployment

`hosts/ferrix/silverbullet-space-move/package.nix` compiles against the exact
SilverBullet frontend source and dependency set already pinned by the flake.
`hosts/ferrix/silverbullet.nix` synchronizes the built plug to `_plug/` in both
spaces through the existing managed-file service. No new credential is needed.

Before new files are tracked, use a path flake for verification:

```sh
nix build "path:$PWD#checks.x86_64-linux.silverbullet-space-move" --no-link
nix build "path:$PWD#nixosConfigurations.ferrix.config.system.build.toplevel" --no-link
```

The package check runs pure core/engine/transport tests, parser/controller/command
integration tests, TypeScript checks and a Chromium test against two isolated
spaces in the real upstream server. The browser fixture generates its own
short-lived account, exercises the native installed plug and browser session, and
never reads production notes or credentials.

An administrator must activate the normal Ferrix rebuild to make the command live.
A successful package build is not deployment or authorization to run a production
note migration. Refresh SilverBullet after activation, then verify the command in
both spaces before using it on a real collection.
