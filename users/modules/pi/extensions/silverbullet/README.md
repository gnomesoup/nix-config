# SilverBullet Pi extension

Native Pi tools for the SilverBullet 2.10 `/.fs` API, including path-bound MultiSpace deployments. The extension runs inside Pi and talks directly to the configured server; it does not start a daemon, MCP server, child process, or listening socket.

Search, read, and note-mutation tools accept an optional `space`. The immutable configuration supplies the allowed names, labels, and URL prefixes; omitting `space` uses `defaultSpace`. Journal retry takes its explicit space from the returned recovery payload. On ferrix the choices are `personal` (Personal at `/`, the default) and `ksp` (KSP at `/ksp`). Results, mutation confirmations, and result details identify the selected space.

Tools:

- `silverbullet_search`: list or search user notes, with an in-process, per-space content cache.
- `silverbullet_read`: read a page or line range.
- `silverbullet_create`: create without overwriting.
- `silverbullet_append`: append or create.
- `silverbullet_update`: approved whole-page replacement, exact-text replacement, or deletion.
- `silverbullet_journal_retry`: retry only the activity-journal append from a returned recovery payload, without touching the original note.

## Required activity journal

Every verified successful mutation of a non-journal note automatically appends a brief entry to **the same space's** `Journal/YYYY-MM-DD.md`. The date uses `America/New_York`, including daylight-saving time, independently of the host timezone. An entry links the changed note and records the caller's `change_summary`. Deletion entries explicitly say `Deleted`, name the former path, and include the summary instead of adding an unexplained broken link. Existing journal content and metadata are preserved; append results are read back for verification.

All three mutation tools accept:

- `change_summary`: **required by runtime validation** for non-journal targets; a trimmed, non-empty single line, at most 280 characters. Use a short description such as `Recorded deployment decision`, not the whole note or sensitive content. Schema-level optionality permits journal-target calls without a summary; it is not an opt-out for other notes.
- `operation_id`: optional unique caller-chosen logical operation ID, 1–128 ASCII letters, digits, dots, underscores, colons, or hyphens. An omitted ID is generated automatically. Reuse an ID only to identify the same logical journal operation; this is **not** note-write idempotency.

For example, create arguments can be:

```json
{
  "space": "ksp",
  "page": "Projects/Deployment",
  "content": "Deployment decision: use the existing service.",
  "change_summary": "Recorded deployment decision",
  "operation_id": "deployment-decision-1"
}
```

Only daily journal targets matching `Journal/YYYY-MM-DD.md` (or the same path with `.md` omitted) are exempt from summary validation and automatic journaling. They still obey all existing path, permission, size, and destructive-approval checks. Automatic appends use the underlying write helpers, not the public mutation tools, so they cannot recurse. Replacements whose resulting content is unchanged do not write, prompt, or journal; failed, denied, and unverified note mutations do not append journal entries.

### Partial success and recovery

Note mutation and journal append are separate HTTP operations, not a transaction. If the note succeeds but the journal fails, the tool **returns**, rather than throwing an ordinary note-write error:

- `details.status = "partial_success"`
- `details.note_status = "succeeded"`
- `details.journal.status = "failed"`, plus the journal `page`, `operation_id`, error, and self-contained `retry` payload.

The text output explicitly warns **not to replay the note mutation** and includes complete JSON arguments for `silverbullet_journal_retry`. Successful outcomes have `details.status = "success"` and journal status `recorded`, `already_recorded`, or `exempt`. No-op replacements return `details.changed = false` and `details.journal.status = "skipped_noop"`.

Call `silverbullet_journal_retry` with `{ "retry": <the exact returned payload> }`. The payload contains `space`, original `page`, `action`, `change_summary`, original `journal_page`, `operation_id`, and `marker_id`. Save it if recovery must survive a session restart. The retry tool does not read, recreate, update, or delete the original note, needs no destructive approval, and retains the original journal date even when retried on a different day. Repeated journal failure returns `details.status = "journal_failed"`, `details.note_status = "not_touched"`, and the same retry payload; success returns `recorded` or `already_recorded`.

A deterministic SHA-256 marker is persisted in the journal as an HTML comment. It binds the configured space URL/name, note path, action, summary, journal date, and operation ID. Retry reads the journal first and skips a marker already present, including when the previous append committed but its verification request failed. Recovery needs no in-memory operation registry and is tested in a separate Node process. Markers must not be removed while their saved retry payloads might still be used. The payload hash detects accidental changes and cross-space reuse; it is not a signature or a substitute for server authorization.

Journal appends serialize per space/page inside one extension instance. The server's lack of atomic conditional writes still means simultaneous independent processes/browser edits can overwrite or duplicate entries; persisted markers make **sequential** retries restart-safe, not globally exactly-once. A process crash after the note commits but before a recovery payload is returned also cannot be recovered automatically. If a note's own verification fails after a possible commit, inspect the note before retrying; no journal entry is emitted for an unverified mutation.

## Tests

The package derivation runs TypeScript checking and `tsx --test test.ts` with the packaged Pi dependencies. The mock HTTP-server suite covers summary/ID validation, space isolation, journal exceptions, no-ops, denied/failed writes, deletion verification, winter/summer New York midnight boundaries, read-only journals, all mutation kinds' partial failures, journal-only recovery in a fresh process, persisted-marker deduplication after uncertain journal verification, retry path/payload validation, escaping, concurrency, and existing destructive-approval/session safety.

## Configuration

```json
{
  "baseUrl": "http://127.0.0.1:3000",
  "allowInsecureHttp": true,
  "tokenFile": "/run/secrets/silverbullet/pi-api-token",
  "defaultSpace": "personal",
  "spaces": {
    "personal": { "label": "Personal", "path": "/" },
    "ksp": { "label": "KSP", "path": "/ksp" }
  }
}
```

`baseUrl` must be an HTTP(S) origin without credentials or a path. Space paths must be canonical, literal URL prefixes. Tool arguments can select only configured space names and can never provide an endpoint or URL prefix.

## Authentication

SilverBullet 2.10 MultiSpace does not use `SB_AUTH_TOKEN`. Create a per-account API token in the authenticated Space Manager at `/.spaces`; the account must be authorized for every selected space. Store the token only in the sops secret `silverbullet/pi-api-token`. The Nix-generated configuration contains only the runtime secret path. SilverBullet expects the token as `Authorization: Bearer …` and the extension never includes it in output or errors.

The token file must be absolute, regular, non-empty, and inaccessible to group/other users. Restart Pi after rotating it because configuration and credentials are read once per extension load.

## Security and safety properties

- The immutable Nix-generated configuration determines the origin, space prefixes, default space, and token-file path.
- Projects and tool arguments cannot override endpoints, prefixes, or credentials.
- Redirects are rejected, response and note sizes are bounded, and model-visible output is truncated.
- The bearer token is read directly by the Pi process and is never returned in tool output.
- `Library/`, `Repositories/`, `.client/`, and other dot-prefixed roots cannot be mutated.
- Whole-page replacement, exact-text replacement, and deletion require interactive approval that names the target space, and fail closed without UI support.
- The approval selector offers **Allow once**, **Allow all SilverBullet replacements/deletions for this session**, and **Deny**. The session grant is held only in memory and resets on session start or extension reload.
- While an approval selector is open, the extension emits Herdr's semantic `blocked` state and clears it in a `finally` block on approval, denial, cancellation, or UI failure.
- Create and append operations are serialized per page and per space within each Pi process, and writes are read back from the same space for verification.

SilverBullet 2.10.0 does not return `ETag` headers or implement `If-Match` for `/.fs` writes. Therefore neither this extension nor a sidecar can guarantee atomic conflict detection against a simultaneous browser edit or another Pi process. The extension preserves metadata, serializes in-process changes, and verifies writes, but concurrent external edits remain a last-writer-wins risk.

Authoritative references are pinned to the 2.10.0 tag:

- [`docs/Authentication.md`](https://github.com/silverbulletmd/silverbullet/blob/2.10.0/docs/Authentication.md)
- [`docs/Space Manager.md`](https://github.com/silverbulletmd/silverbullet/blob/2.10.0/docs/Space%20Manager.md)
- [`server/src/multi/dispatch.rs`](https://github.com/silverbulletmd/silverbullet/blob/2.10.0/server/src/multi/dispatch.rs)
- [`server/src/handlers/fs.rs`](https://github.com/silverbulletmd/silverbullet/blob/2.10.0/server/src/handlers/fs.rs)
