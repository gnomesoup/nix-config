---
name: worktree-cleanup
description: Safely finishes the current Herdr-managed feature worktree by validating and committing its work, merging it into main, testing the integrated result, removing the Herdr worktree workspace, and deleting the merged feature branch. Use when the user says "cleanup this worktree", "finish this worktree", "merge and clean up", or invokes /cleanup or /skill:worktree-cleanup.
compatibility: Requires Git and a Herdr-managed pane with HERDR_ENV=1.
---

# Worktree Cleanup

Finish and remove the **current** Herdr-managed linked worktree without losing
work. The default target branch is `main`; use another target only when the user
explicitly names it.

## Safety invariants

- Start with `test "${HERDR_ENV:-}" = 1`. If it fails, stop: Herdr must not be
  controlled from outside a managed pane.
- Read the installed Herdr CLI syntax with `herdr --help`, `herdr worktree`,
  `herdr workspace`, `herdr pane`, and `herdr notification` before control
  operations.
- Resolve workspace IDs, checkout paths, and branch names from Herdr/Git output.
  Never guess IDs or derive them from sidebar positions. Store resolved values
  in shell variables and use quoted expansions such as `"$target_checkout"`;
  never splice raw values into shell command text.
- Operate only on the current linked feature worktree. Reject a detached HEAD,
  the primary checkout, and protected target branches such as `main` or
  `master` as the feature branch.
- Never use `--force`, `git reset --hard`, `git clean`, `git branch -D`, or
  discard/stash unknown changes.
- Never remove the worktree until the target branch contains the feature tip,
  required verification has passed, and both committed and untracked feature
  work have been handled.
- Do not push either branch unless the user separately requests it.
- Do not close or reuse an unrelated pane. Create a temporary pane in the
  surviving target workspace for the final destructive cleanup.

## 1. Discover the current and target worktrees

Inspect the current context:

```bash
git rev-parse --show-toplevel
git symbolic-ref --quiet --short HEAD
git status --short
herdr workspace get "$HERDR_WORKSPACE_ID"
herdr worktree list --workspace "$HERDR_WORKSPACE_ID"
```

From the JSON results, identify:

- the current feature workspace ID, checkout path, and branch;
- the checkout that has the target branch (`main` by default);
- the target checkout's open Herdr workspace ID, if any.

Require the current Git top-level path to exactly match the selected Herdr
worktree path. Do not add `--trust-repository` unless the user explicitly
approves trusting an untrusted repository.

If the target checkout has no open Herdr workspace, open it without stealing
focus and read its returned workspace/root-pane IDs:

```bash
herdr worktree open --path "$target_checkout" --no-focus
```

## 2. Finish and verify feature work

Review the feature status and diff. Follow the repository's `AGENTS.md` and run
its required relevant tests/builds.

If changes are uncommitted:

- When they were produced as part of the current agent's known task, stage only
  the exact relevant paths and create a descriptive commit.
- When ownership or intent is unclear, summarize the changes and ask before
  staging or committing them.
- Never sweep unrelated files into the commit with an indiscriminate
  `git add -A`.

Require `git status --short` in the feature worktree to be empty before
continuing.

## 3. Merge into the target checkout

First determine whether cleanup is already merged:

```bash
feature_tip=$(git rev-parse HEAD)
target_tip=$(git -C "$target_checkout" rev-parse --verify \
  "refs/heads/${target_branch}^{commit}")
git -C "$target_checkout" merge-base --is-ancestor \
  "$feature_tip" "$target_tip"
```

If this succeeds, skip the merge. This makes repeated cleanup requests safe.

If a merge is required:

1. Require the target checkout to be on the expected target branch and clean.
   Do not disturb target-side user changes.
2. Merge from the target checkout, preserving feature history:

   ```bash
   git -C "$target_checkout" merge --no-ff \
     "refs/heads/$feature_branch"
   ```

3. If conflicts occur, stop without removing the worktree or branch. Report the
   conflicts for resolution. Do not guess at conflict resolutions merely to
   complete cleanup.
4. Run the repository-required relevant tests/builds against the merged target
   checkout.
5. Prove again that the feature tip is an ancestor of the target branch.

If post-merge verification fails, keep the feature worktree and branch and
report the failure.

## 4. Remove the worktree and branch from a surviving pane

Deleting the current Herdr workspace can terminate this agent before a
following branch-delete command runs. Therefore, perform the final actions in a
**temporary shell pane in the target workspace**.

Do not pass a compound command through `herdr pane run`, `sh -c`, or `sh -lc`.
Herdr's command transport does not preserve nested shell quoting as an argv
boundary, so an inline `if ...; then ...; fi` can be reparsed incorrectly.
Instead use the bundled `scripts/remove-worktree.sh`, which takes all dynamic
values from its environment and quotes them at their point of use.

Resolve the helper relative to this `SKILL.md`, store its absolute path in
`cleanup_helper`, then copy it to a unique, space-free launcher path that
remains available after the feature worktree is removed:

```bash
cleanup_dir=$(mktemp -d /tmp/herdr-worktree-cleanup.XXXXXX)
cleanup_script="$cleanup_dir/run"
cp -- "$cleanup_helper" "$cleanup_script"
chmod 700 "$cleanup_script"
```

List target panes and select an explicit live pane only as a split anchor. Pass
each dynamic value as one `--env` argument; do not concatenate it into command
text:

```bash
herdr pane list --workspace "$target_workspace_id"
herdr pane split --pane "$anchor_pane_id" --direction down --ratio 0.20 \
  --cwd "$target_checkout" \
  --env "WORKTREE_CLEANUP_FEATURE_WORKSPACE_ID=$feature_workspace_id" \
  --env "WORKTREE_CLEANUP_TARGET_CHECKOUT=$target_checkout" \
  --env "WORKTREE_CLEANUP_TARGET_BRANCH=$target_branch" \
  --env "WORKTREE_CLEANUP_FEATURE_BRANCH=$feature_branch" \
  --no-focus
```

Read the new pane ID from `.result.pane.pane_id`. Before launching the final
script, tell the user that the merge is complete and this workspace is about to
close. Then run only the space-free launcher path, with no shell wrapper and no
additional command arguments:

```bash
herdr pane run "$new_pane_id" "$cleanup_script"
```

The helper rechecks that the target checkout is clean, remains on the expected
target branch, and contains the feature tip. It then uses
`herdr worktree remove` to remove the linked checkout and close its workspace,
followed by `git branch -d --` to safely delete only a merged branch. On success
it removes its temporary launcher and exits the temporary pane. On failure it
leaves the pane and launcher in place so diagnostics remain visible.

Do not attempt further tool calls after launching the final script: successful
cleanup intentionally closes the workspace hosting this agent.
