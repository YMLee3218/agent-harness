#!/usr/bin/env bash
# PreToolUse Bash hook — BLOCKED-AMBIGUOUS phase-gate blocking rules.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PRETOOLUSE_AMBIGUOUS_BLOCKS_LOADED:-}" ]] && return 0
_PRETOOLUSE_AMBIGUOUS_BLOCKS_LOADED=1

block_ambiguous_interpreter_inline() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -qE \
    '(python3?|perl|ruby|node|php|lua|R)[[:space:]]+-[ceEr][^[:alpha:]]'; then
    echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — interpreter inline execution prohibited" >&2; exit 2
  fi
}

block_ambiguous_interpreter_heredoc() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -qE \
    '(python3?|perl|ruby|node|php|lua|R)[[:space:]]*(<<|<<-)'; then
    echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — interpreter heredoc execution prohibited" >&2; exit 2
  fi
}

block_ambiguous_shell_inline() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -qE \
    '(bash|sh|zsh|ksh|dash)[[:space:]]+-c[^[:alpha:]]'; then
    echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — shell inline execution prohibited" >&2; exit 2
  fi
}

block_ambiguous_file_install() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -qE \
    '(^|[;|&[:space:]])[[:space:]]*(rsync|git[[:space:]]+apply|patch[[:space:]]|unzip[[:space:]]|install[[:space:]])'; then
    echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — file-install command prohibited" >&2; exit 2
  fi
}

block_ambiguous_tar_extract() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -qE \
    '(^|[;|&[:space:]])[[:space:]]*tar[[:space:]]+-[[:alpha:]]*[xX]'; then
    echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — tar extraction prohibited" >&2; exit 2
  fi
}
