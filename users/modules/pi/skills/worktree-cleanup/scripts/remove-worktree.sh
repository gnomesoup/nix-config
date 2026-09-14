#!/bin/sh

notify_attention() {
  herdr notification show "Worktree cleanup needs attention" \
    --body "Inspect the temporary cleanup pane" --sound request >/dev/null 2>&1 || true
}

fail() {
  printf 'worktree cleanup: %s\n' "$1" >&2
  notify_attention
  exit 1
}

[ "${HERDR_ENV:-}" = 1 ] || fail "the cleanup script is not running inside Herdr"
[ -n "${WORKTREE_CLEANUP_FEATURE_WORKSPACE_ID:-}" ] || fail "missing feature workspace ID"
[ -n "${WORKTREE_CLEANUP_TARGET_CHECKOUT:-}" ] || fail "missing target checkout"
[ -n "${WORKTREE_CLEANUP_TARGET_BRANCH:-}" ] || fail "missing target branch"
[ -n "${WORKTREE_CLEANUP_FEATURE_BRANCH:-}" ] || fail "missing feature branch"

feature_workspace_id=$WORKTREE_CLEANUP_FEATURE_WORKSPACE_ID
target_checkout=$WORKTREE_CLEANUP_TARGET_CHECKOUT
target_branch=$WORKTREE_CLEANUP_TARGET_BRANCH
feature_branch=$WORKTREE_CLEANUP_FEATURE_BRANCH

case "$feature_branch" in
  main | master) fail "refusing to delete protected branch $feature_branch" ;;
esac
[ "$feature_branch" != "$target_branch" ] || fail "feature branch is the target branch"

actual_target_branch=$(git -C "$target_checkout" symbolic-ref --quiet --short HEAD) ||
  fail "target checkout is not on a branch"
[ "$actual_target_branch" = "$target_branch" ] ||
  fail "target checkout moved from $target_branch to $actual_target_branch"
[ -z "$(git -C "$target_checkout" status --porcelain)" ] ||
  fail "target checkout is no longer clean"

feature_tip=$(git -C "$target_checkout" rev-parse --verify \
  "refs/heads/${feature_branch}^{commit}") ||
  fail "cannot resolve feature branch $feature_branch"
target_tip=$(git -C "$target_checkout" rev-parse --verify \
  "refs/heads/${target_branch}^{commit}") ||
  fail "cannot resolve target branch $target_branch"
git -C "$target_checkout" merge-base --is-ancestor "$feature_tip" "$target_tip" ||
  fail "$feature_branch is not contained in $target_branch"

if herdr worktree remove --workspace "$feature_workspace_id" &&
  git -C "$target_checkout" branch -d -- "$feature_branch"
then
  herdr notification show "Worktree cleaned" \
    --body "Merged and removed $feature_branch" --sound done >/dev/null 2>&1 || true
  script_path=$0
  script_dir=$(dirname -- "$script_path")
  rm -- "$script_path" || true
  rmdir -- "$script_dir" >/dev/null 2>&1 || true
  exit 0
fi

notify_attention
exit 1
