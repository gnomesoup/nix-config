---
name: silverbullet-journal-links
description: Use when verifying SilverBullet daily activity entries.
---

# SilverBullet journal compatibility

The authoritative journaling policy now lives in the shared `silverbullet` skill.
In Hermes, load `inigo-silverbullet:silverbullet`; in Pi, load `silverbullet`.

Native mutations require a brief `change_summary` for non-journal pages and
record activity automatically in the same space's `Journal/YYYY-MM-DD.md`, using
`America/New_York`. Do not manually append a duplicate entry after those calls.

Verify the changed note and the journal. If only journal recording failed, use
`silverbullet_journal_retry` with the exact returned retry payload, then read back
the journal. Do not repeat a successful note mutation to recover its journal.
Journal-only edits, no-op writes, failed writes, and reads do not log activity.

If running older tools without enforced journaling, follow the shared skill's
contract manually: determine the current New York date, read the journal, append
one concise link-and-summary entry per changed page with the tool's conflict
guards, and read it back. Never expose secrets or payment details in the entry.
