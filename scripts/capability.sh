#!/usr/bin/env bash
# Capability ring gate and PPID-chain harness detection.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_CAPABILITY_LOADED:-}" ]] && return 0
_CAPABILITY_LOADED=1

declare -F die >/dev/null 2>&1 || die() { echo "ERROR: $*" >&2; exit 1; }

# Shared Ring C file pattern — used by phase-gate.sh (_guard_ring_c).
# One definition sourced by both to prevent divergence.
_RING_C_FILES='(\.claude(-harness)?/)?(CLAUDE\.md|settings\.json|reference/(markers|critics|phase-gate-config|layers|effort|anti-hallucination|language|severity|phase-ops|ultrathink|pr-review-loop)\.md|scripts/[^/]+\.sh|scripts/lib/[^/]+\.sh)'

# _check_parent_env PID [CAPABILITY] → returns 0 if the process has CLAUDE_PLAN_CAPABILITY=CAPABILITY in its environment.
# CAPABILITY defaults to "harness". Checks the parent process's environment rather than argv to prevent argv-injection bypass.
_check_parent_env() {
  local ppid="$1" capability="${2:-harness}" env_str=""
  if [[ -r "/proc/${ppid}/environ" ]]; then
    # Linux: null-separated environment — convert to newline-separated and grep for exact var
    env_str=$(tr '\0' '\n' < "/proc/${ppid}/environ" 2>/dev/null) || env_str=""
    printf '%s\n' "$env_str" | grep -qE "^CLAUDE_PLAN_CAPABILITY=${capability}$" && return 0
    return 1
  fi
  # macOS/other: use set-difference between argv-only and argv+env to isolate env portion.
  # This prevents argv-mimic bypass where a process puts the env var literal in its argv.
  local ps_argv ps_full env_part
  ps_argv=$(ps -p "$ppid" -o args= 2>/dev/null) || return 1
  ps_full=$(ps eww -p "$ppid" -o args= 2>/dev/null) || return 1
  # Fail-closed if ps eww output is near the OS truncation limit (~8KB on macOS).
  if [[ "${#ps_full}" -ge 8190 ]]; then
    echo "BLOCKED-CAPABILITY: ps eww output truncated (${#ps_full} bytes) — fail-closed for pid ${ppid}" >&2
    return 1
  fi
  # env portion = full output minus the leading argv portion
  env_part="${ps_full#"$ps_argv"}"
  if [[ -z "$env_part" ]] || [[ "$env_part" == "$ps_full" ]]; then
    # Cannot separate argv from env — fail-closed
    [[ -n "${CLAUDE_DEBUG_PPID:-}" ]] && \
      echo "[ppid-chain] WARN: cannot separate argv from env on this platform for pid ${ppid} — fail-closed" >&2
    return 1
  fi
  # Search only the env portion for the exact variable
  if printf '%s' "$env_part" | grep -qE "(^| )CLAUDE_PLAN_CAPABILITY=${capability}( |$)"; then
    return 0
  fi
  [[ -n "${CLAUDE_DEBUG_PPID:-}" ]] && \
    echo "[ppid-chain] CLAUDE_PLAN_CAPABILITY=${capability} not found in env of pid ${ppid}" >&2
  return 1
}

# Walk PPID chain checking for a harness script ancestor with CLAUDE_PLAN_CAPABILITY=harness.
# Depth is capped by CLAUDE_PPID_CHAIN_DEPTH (default 10) for testability.
_ppid_chain_is_harness() {
  local pid="$$" depth=0
  local _max="${CLAUDE_PPID_CHAIN_DEPTH:-10}"
  while [[ $depth -lt $_max ]]; do
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 1
    [[ -z "$pid" ]] && return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ "$pid" -le 1 ]] && return 1
    # Check env var of parent process rather than argv to prevent argv-inject bypass.
    if _check_parent_env "$pid"; then
      return 0
    fi
    depth=$((depth + 1))
  done
  [[ -n "${CLAUDE_DEBUG_PPID:-}" ]] && echo "[ppid-chain] no harness ancestor in $_max levels" >&2
  return 1
}

# Walk PPID chain checking for a human-capability ancestor with CLAUDE_PLAN_CAPABILITY=human.
_ppid_chain_is_human() {
  local pid="$$" depth=0
  local _max="${CLAUDE_PPID_CHAIN_DEPTH:-10}"
  while [[ $depth -lt $_max ]]; do
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 1
    [[ -z "$pid" ]] && return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ "$pid" -le 1 ]] && return 1
    _check_parent_env "$pid" "human" && return 0
    depth=$((depth + 1))
  done
  return 1
}

# require_capability CMD [RING]
# RING=B (default): allow if env-var=harness AND PPID chain has harness ancestor.
# RING=C: allow if env-var=human AND PPID chain has human ancestor (export CLAUDE_PLAN_CAPABILITY=human first).
require_capability() {
  local cmd="$1" ring="${2:-B}"
  if [[ "$ring" == "C" ]]; then
    if [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "human" ]]; then
      _ppid_chain_is_human && return 0
    fi
    die "[$cmd] is human-only — export CLAUDE_PLAN_CAPABILITY=human in the calling shell, then re-run"
  fi
  # Ring B: require CLAUDE_PLAN_CAPABILITY=harness AND PPID chain
  if [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "harness" ]]; then
    _ppid_chain_is_harness && return 0
  fi
  die "[$cmd] requires CLAUDE_PLAN_CAPABILITY=harness"
}
