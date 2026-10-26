# Pi native tools

Load this reference when using Pi's SilverBullet extension. Do not use Hermes's
conflict-token arguments or assume uploads, moves, or soft deletion are available.

## Tools and approvals

- `silverbullet_search` searches paths and content; omit `query` to list pages.
- `silverbullet_read` reads a page or line range.
- `silverbullet_create` creates without overwriting.
- `silverbullet_append` appends or creates.
- `silverbullet_update` supports `replace_page`, `replace_text`, and `delete`.
  Prefer `replace_text` to replace an exact string narrowly. Read immediately
  before editing, even though the extension also reads before writing.
- Supply explicit `space` for mutations and `change_summary` for non-journal
  changes. The extension performs journal recording, not the agent separately.
  The summary must be one non-empty line of at most 280 characters. Optional
  `operation_id` identifies one logical journal operation; it does not make the
  original note write safe to replay.
- Replacements and deletions require the extension's interactive approval unless
  the user has granted approval for the current Pi session. They fail closed
  without UI support. Never bypass approval using append or a shell API call.
- Pi's delete operation is permanent. Use it only for explicit approval to delete
  that exact page; do not claim the page was moved to Trash.

## Journal verification and recovery

Inspect `details.journal` and read back its `page`. If `details.status` is
`partial_success`, the note succeeded but journaling failed. Call
`silverbullet_journal_retry` with `{"retry": details.journal.retry}` unchanged.
Retry only journaling, not the note mutation. Read the journal after retrying
before claiming completion. A retry failure returns `journal_failed` and leaves
the original note untouched; preserve the same payload for another retry.

The journal belongs to the selected space and uses `America/New_York` dates.
Journal edits are exempt from automatic logging, as are unchanged replacements.
Preserve the original operation identifier when retrying to avoid duplicate
entries, including after extension reload or process restart.

The extension serializes operations inside its process and verifies writes.
SilverBullet's `/.fs` API does not provide atomic conditional writes; external
browser or other-agent edits can still race. Do not promise cross-agent locking.

## Version-aware UI guidance

Determine the running SilverBullet version before recommending command-palette
labels or shortcuts, and verify them against official documentation or source
for that version. Quote exact labels; never silently substitute older names.
If the version cannot be established, ask the user to search the visible palette
rather than asserting an unverified command. Distinguish page, document, and
annotation pickers; PDF documents are not Markdown pages.
