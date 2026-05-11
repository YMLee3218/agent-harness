#!/usr/bin/env bash
# PreToolUse Bash hook — sidecar and critic-lock write blocking rules.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PRETOOLUSE_SIDECAR_BLOCKS_LOADED:-}" ]] && return 0
_PRETOOLUSE_SIDECAR_BLOCKS_LOADED=1

_cmd_targets_sidecar() {
  local _raw="$1" _decoded
  printf '%s' "$_raw" | grep -qE 'plans/[^[:space:]'"'"'"]*\.state' && return 0
  _decoded=$(_decode_ansi_c "$_raw")
  printf '%s' "$_decoded" | grep -qE 'plans/[^[:space:]'"'"'"]*\.state'
}

_cmd_targets_critic_lock() {
  local _raw="$1" _decoded
  printf '%s' "$_raw" | grep -qE 'plans/[^[:space:]'"'"'"]*\.critic\.lock' && return 0
  _decoded=$(_decode_ansi_c "$_raw")
  printf '%s' "$_decoded" | grep -qE 'plans/[^[:space:]'"'"'"]*\.critic\.lock'
}

block_git_sidecar_writes() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+(checkout|restore|apply)[[:space:]]' && \
     _cmd_targets_sidecar "$cmd"; then
    echo "BLOCKED: git write operation targeting plans/*.state/ — sidecar is harness-exclusive" >&2
    exit 2
  fi
}

block_ln_sidecar() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*ln[[:space:]]'; then
    if _cmd_targets_sidecar "$cmd"; then
      echo "BLOCKED: ln operation targeting plans/*.state/ — symlink redirect attacks are not permitted" >&2
      exit 2
    fi
  fi
}

block_rm_sidecar() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]'; then
    if _cmd_targets_sidecar "$cmd"; then
      echo "BLOCKED: rm targeting plans/*.state/ — sidecar is harness-exclusive" >&2
      exit 2
    fi
    if _cmd_targets_critic_lock "$cmd"; then
      echo "BLOCKED: rm targeting plans/*.critic.lock — critic loop lock is harness-exclusive" >&2
      exit 2
    fi
  fi
}

block_awk_inplace_sidecar() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE 'awk[[:space:]]+-i[[:space:]]*(inplace|in-place)' && \
     _cmd_targets_sidecar "$cmd"; then
    echo "BLOCKED: awk -i inplace targeting plans/*.state/ — sidecar is harness-exclusive" >&2
    exit 2
  fi
}

block_write_tools_sidecar() {
  local cmd="$1"
  if _cmd_targets_sidecar "$cmd"; then
    if printf '%s' "$cmd" | grep -iqE \
      '(^|[;|&[:space:]])[[:space:]]*(rsync[[:space:]]|install[[:space:]]|patch[[:space:]]|unzip[[:space:]]|tar[[:space:]]+-[[:alpha:]]*[xX]|cp[[:space:]]|mv[[:space:]])'; then
      echo "BLOCKED: write tool targeting plans/*.state/ — sidecar is harness-exclusive" >&2
      exit 2
    fi
  fi
}

block_interpreter_sidecar() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -qE 'plans/[^[:space:]'"'"'"]*\.state/'; then
    if printf '%s' "$cmd" | grep -qE \
      '(python3?|perl|ruby|node|php|lua|R)[[:space:]]+-[ceEr][^[:alpha:]]|>{1,2}[[:space:]]*[^[:space:]]*plans/[^[:space:]'"'"'"]*\.state/'; then
      echo "BLOCKED: write operation targeting plans/*.state/ — sidecar is harness-exclusive" >&2
      exit 2
    fi
  fi
}
