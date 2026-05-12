#!/usr/bin/env bash
# Path canonicalization helpers — symlink resolution and safe-path validation.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PATH_CANON_LOADED:-}" ]] && return 0
_PATH_CANON_LOADED=1

# _canon_path PATH → resolves symlinks; returns canonical absolute path.
# Tries realpath, readlink -f, then python3 for macOS without GNU coreutils.
_canon_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath -- "$1" 2>/dev/null
  elif readlink -f /dev/null >/dev/null 2>&1; then
    readlink -f -- "$1" 2>/dev/null
  else
    python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null
  fi
}

# _is_safe_transcript_path PATH → prints canonical path and returns 0 if path resolves inside
# CLAUDE_PROJECT_DIR or ~/.claude/projects/. Returns 1 (no output) if unsafe or unresolvable.
# Callers must use the printed canonical path for all subsequent file opens (TOCTOU prevention).
_is_safe_transcript_path() {
  local _p="$1"
  [[ -z "$_p" ]] && return 1
  local canon home_canon proj_canon
  canon=$(_canon_path "$_p") || return 1
  [[ -z "$canon" ]] && return 1
  home_canon=$(_canon_path "${HOME}/.claude/projects") || home_canon="${HOME}/.claude/projects"
  case "$canon" in "${home_canon}/"*) printf '%s' "$canon"; return 0 ;; esac
  local _proj_dir="${CLAUDE_PROJECT_DIR:-}"
  if [[ -n "$_proj_dir" ]]; then
    proj_canon=$(_canon_path "$_proj_dir") || proj_canon="$_proj_dir"
    [[ -n "$proj_canon" ]] && case "$canon" in "${proj_canon}/"*) printf '%s' "$canon"; return 0 ;; esac
  fi
  return 1
}
