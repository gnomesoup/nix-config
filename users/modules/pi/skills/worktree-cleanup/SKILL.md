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
  `herdr workspace`, and `herdr pane` before control operations.
- Resolve workspace IDs, checkout paths, and branch names from Herdr/Git output.
  Never guess IDs or derive them from sidebar positions.
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
herdr worktree open --path <target-checkout> --no-focus
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
git merge-base --is-ancestor <feature-tip> <target-branch>
```

If this succeeds, skip the merge. This makes repeated cleanup requests safe.

If a merge is required:

1. Require the target checkout to be on the expected target branch and clean.
   Do not disturb target-side user changes.
2. Merge from the target checkout, preserving feature history:

   ```bash
   git -C <target-checkout> merge --no-ff <feature-branch>
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
following branch-delete command runs. Therefore, perform the final two actions
as one command in a **temporary shell pane in the target workspace**.

List target panes and select an explicit live pane only as a split anchor:

```bash
herdr pane list --workspace <target-workspace-id>
herdr pane split --pane <anchor-pane-id> --direction down --ratio 0.20 \
  --cwd <target-checkout> --no-focus
```

Read the new pane ID from `.result.pane.pane_id`. Before launching the final
command, tell the user that the merge is complete and this workspace is about
to close.

Run a carefully shell-quoted equivalent of the following in the new pane:

```bash
if herdr worktree remove --workspace <feature-workspace-id> && \
   git -C <target-checkout> branch -d -- <feature-branch>; then
    herdr notification show "Worktree cleaned" \
      --body "Merged and removed <feature-branch>" --sound done
    exit
else
    herdr notification show "Worktree cleanup needs attention" \
      --body "Inspect the temporary cleanup pane" --sound request
fi
```

Use `herdr pane run <new-pane-id> <command>` to start it. Shell-quote every
substituted ID, path, and branch name; do not paste placeholders literally.

`herdr worktree remove` removes the linked checkout and closes its Herdr
workspace, but does not delete the branch. `git branch -d` then safely deletes
only a branch Git recognizes as merged. The temporary pane exits on success and
stays open on failure so its diagnostics remain visible.

Do not attempt further tool calls after launching the final command: successful
cleanup intentionally closes the workspace hosting this agent.
