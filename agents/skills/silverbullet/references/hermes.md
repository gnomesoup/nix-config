# Hermes native tools

Load this reference when using the Hermes `inigo-silverbullet` plugin. Do not
assume these arguments or capabilities exist in Pi.

## Tools and conflict guards

- `silverbullet_list_pages` lists pages; `silverbullet_search` searches literal
  text; `silverbullet_read` returns content and `last_modified`.
- `silverbullet_create` creates without overwriting.
- `silverbullet_append` appends or creates. Existing pages require the exact
  `expected_last_modified` returned by the latest read.
- `silverbullet_update` replaces content with the same conflict guard. Construct
  replacement content from a fresh read; preserve everything outside the edit.
- `silverbullet_move` requires `source`, `destination`, and the source conflict
  token. It refuses an existing destination.
- `silverbullet_soft_delete` requires the page conflict token. Its default moves
  to Trash before removing the source. `permanent=true` is only for an explicit
  user request for irreversible deletion of that exact page.
- Supply explicit `space` for mutations and `change_summary` for non-journal
  changes. Existing-path write allowlists and protected paths remain enforced.
  The summary must be one non-empty line of at most 240 characters. Daily
  `Journal/YYYY-MM-DD.md` pages are exempt; other `Journal/` notes are not.

## Uploads

`silverbullet_upload_file` accepts `space`, absolute `source_path`, exact
space-relative `destination` under `assets/`, and `change_summary`. Preserve the
file extension; uploads do not append `.md`. The default maximum is 20 MiB.

Sources must be within configured upload roots. Require `verified: true` for byte
read-back. Use `markdown_image` for images and `markdown_link` for other files.
Identical uploads return `already_present`; different-content overwrites fail.
On collision choose a distinct name rather than deleting the old attachment.
Markdown links embedded in notes are space-root-relative, for example
`/assets/diagram.png`, even in KSP. Do not prepend the `/ksp` deployment prefix;
SilverBullet resolves the link within the selected space.

Update the intended note with the returned durable link and its own summary.
Verify the upload separately from note embedding and journal completion.

## Journal verification and recovery

Non-journal mutations automatically record their activity in the same space.
Inspect the returned journal status and read back its page. A verified note write
with a failed journal is partial completion, not a failed note mutation.
Specifically, `verified: true` with `partial_completion: true` and
`journal.verified: false` means only journal recovery remains. Call
`silverbullet_journal_retry` with the exact `journal.retry` object as its arguments:
`space`, `journal_page`, `entry`, and `operation_id`. Do not wrap it in `retry` as
Pi requires. It must never replay the original note edit. Success returns
`verified: true`; `already_present: true` means its persisted marker was found.

The server does not provide atomic conditional writes for `/.fs`. Last-modified
checks, process-local serialization, and read-back verification reduce risk but
do not eliminate races with browser edits or another agent process.
