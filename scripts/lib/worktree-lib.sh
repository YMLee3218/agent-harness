#!/usr/bin/env bash
# Worktree lifecycle helpers for plan isolation.
# Each plan lives in its own git worktree (feature/<slug>) branched from main.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_WORKTREE_LIB_LOADED:-}" ]] && return 0
_WORKTREE_LIB_LOADED=1

# main_checkout_root [PATH]
# Prints the path of the worktree whose HEAD is on refs/heads/main.
# Falls back to the common git dir's parent (single-checkout compat).
# Read-only — no side effects.
main_checkout_root() {
  local _wt="" _line
  while IFS= read -r _line; do
    case "$_line" in
      "worktree "*)  _wt="${_line#worktree }" ;;
      "branch refs/heads/main") echo "$_wt"; return 0 ;;
    esac
  done < <(git -C "${1:-.}" worktree list --porcelain 2>/dev/null)
  # Fallback: derive from git common dir (works for single checkout)
  local _common
  _common=$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  # common-dir is <root>/.git (absolute); strip the /.git suffix
  echo "${_common%/.git}"
}

# ensure_plan_worktree SLUG ROOT
# Creates a worktree at <ROOT>/.claude/worktrees/<SLUG> on branch feature/<SLUG>,
# branched from main. Idempotent — no-op if the worktree already exists.
# Prints the worktree path.
ensure_plan_worktree() {
  local _slug="$1" _root="$2"
  local _wt_path="${_root}/.claude/worktrees/${_slug}"
  local _branch="feature/${_slug}"
  if git -C "$_root" worktree list --porcelain 2>/dev/null \
      | grep -qF "worktree ${_wt_path}"; then
    echo "$_wt_path"
    return 0
  fi
  mkdir -p "$(dirname "$_wt_path")"
  if git -C "$_root" show-ref --verify "refs/heads/${_branch}" >/dev/null 2>&1; then
    git -C "$_root" worktree add "$_wt_path" "$_branch" 2>/dev/null \
      || { echo "[worktree-lib] ERROR: failed to add worktree for existing branch ${_branch}" >&2; return 1; }
  else
    git -C "$_root" worktree add "$_wt_path" -b "$_branch" main 2>/dev/null \
      || { echo "[worktree-lib] ERROR: failed to create worktree for ${_branch} from main" >&2; return 1; }
  fi
  echo "$_wt_path"
}

# remove_plan_worktree SLUG ROOT
# Removes the plan worktree for SLUG. Safe to call when the worktree does not exist.
remove_plan_worktree() {
  local _slug="$1" _root="$2"
  local _wt_path="${_root}/.claude/worktrees/${_slug}"
  local _branch="feature/${_slug}"
  git -C "$_root" worktree remove --force "$_wt_path" 2>/dev/null || true
  git -C "$_root" branch -d "$_branch" 2>/dev/null || true
}

# merge_plan_worktree SLUG ROOT
# Merges feature/<SLUG> into main (--no-ff) from the main checkout.
# Removes the plan worktree after successful merge.
merge_plan_worktree() {
  local _slug="$1" _root="$2"
  local _branch="feature/${_slug}"
  local _current
  _current=$(git -C "$_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ "$_current" != "main" ]]; then
    echo "[worktree-lib] ERROR: merge_plan_worktree must be called from the main checkout (currently on ${_current})" >&2
    return 1
  fi
  git -C "$_root" merge --no-ff "$_branch" -m "chore(merge): integrate plan ${_slug} into main"
  remove_plan_worktree "$_slug" "$_root"
}

# plan_worktree_path SLUG ROOT
# Prints the expected path; does not check existence.
plan_worktree_path() {
  echo "${2}/.claude/worktrees/${1}"
}
