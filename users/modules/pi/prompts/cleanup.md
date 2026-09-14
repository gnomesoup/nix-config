---
description: Merge and safely remove the current Herdr feature worktree
argument-hint: "[target branch; defaults to main]"
---
Load and follow the `worktree-cleanup` skill to finish, merge, verify, and
remove the current Herdr-managed feature worktree. Use `${1:-main}` as the
target branch. Do not force removal or discard changes.
