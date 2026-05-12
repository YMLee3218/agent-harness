#!/usr/bin/env bash
# Shared pattern-dispatch helper for PreToolUse hooks.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_HOOK_DISPATCH_LOADED:-}" ]] && return 0
_HOOK_DISPATCH_LOADED=1

# _dispatch_patterns CMD PATTERN... — test CMD against "regex|||message" patterns.
# Exits 2 with "BLOCKED: <message>" on first match. Each entry must contain exactly one '|||'.
_dispatch_patterns() {
  local cmd="$1" entry pat msg
  for entry in "${@:2}"; do
    pat="${entry%|||*}"; msg="${entry##*|||}"
    if printf '%s' "$cmd" | grep -iqE "$pat"; then
      echo "BLOCKED: ${msg}" >&2; exit 2
    fi
  done
}
