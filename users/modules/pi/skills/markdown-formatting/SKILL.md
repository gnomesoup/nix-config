---
name: markdown-formatting
description: Formats every Markdown file Pi creates or edits to 88 columns.
compatibility: Requires Prettier and a POSIX shell with awk.
---

# Markdown formatting

Keep every Markdown file created or edited during the task at a maximum of 88 characters
per line.

## Procedure

1. Read repository-local instructions and the existing file before editing. Preserve its
   structure and meaning; do not reformat unrelated Markdown files.
2. Write concise Markdown that naturally fits within 88 columns. Prefer short sentences,
   reference-style links, and lists instead of wide tables.
3. After the content is complete, run Prettier on every Markdown file created or edited
   in the task:

   ```bash
   prettier --write --prose-wrap always --print-width 88 -- <file...>
   ```

4. Check the same explicit file list for lines over 88 characters:

   ```bash
   awk 'length($0) > 88 {
     printf "%s:%d:%d\n", FILENAME, FNR, length($0)
     failed = 1
   } END { exit failed }' <file...>
   ```

5. Fix every reported line without changing its meaning, then repeat Prettier and the
   width check until the check exits successfully.

## Special cases

- Reformat authored fenced code according to its language rather than inserting
  arbitrary line breaks that change behavior.
- Replace wide Markdown tables with lists when a readable table cannot fit.
- Avoid raw URLs. Use descriptive links and shorter canonical targets where available.
- Do not split an unbreakable token or URL in a way that changes it. If a required token
  alone exceeds 88 characters and no equivalent representation preserves semantics, stop
  and report the exact line instead of claiming compliance.
- Skip generated or vendored Markdown unless the task explicitly changes it.

## Verification

The task is complete only when Prettier has run on every Markdown file created or edited
and the final `awk` command exits with status 0 for that exact file list.
