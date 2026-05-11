#!/usr/bin/env bash
# Capability ring gate and PPID-chain harness detection.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_CAPABILITY_LOADED:-}" ]] && return 0
_CAPABILITY_LOADED=1

declare -F die >/dev/null 2>&1 || die() { echo "ERROR: $*" >&2; exit 1; }

# D1: launcher token check — primary gate before ps-based check.
# Source launcher-token.sh if available; silently skip if not (backwards compat).
_LT_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/launcher-token.sh"
[[ -f "$_LT_SH" ]] && . "$_LT_SH" 2>/dev/null || true

# _check_parent_env PID → returns 0 if the process has CLAUDE_PLAN_CAPABILITY=harness in its environment.
# checks the parent process's environment rather than argv to prevent argv-injection bypass.
_check_parent_env() {
  local ppid="$1" env_str=""
  if [[ -r "/proc/${ppid}/environ" ]]; then
    # Linux: null-separated environment — convert to newline-separated and grep for exact var
    env_str=$(tr '\0' '\n' < "/proc/${ppid}/environ" 2>/dev/null) || env_str=""
    printf '%s\n' "$env_str" | grep -qE '^CLAUDE_PLAN_CAPABILITY=harness$' && return 0
    return 1
  fi
  # macOS/other: use set-difference between argv-only and argv+env to isolate env portion.
  # This prevents argv-mimic bypass where a process puts the env var literal in its argv.
  local ps_argv ps_full env_part
  ps_argv=$(ps -p "$ppid" -o args= 2>/dev/null) || return 1
  # Fail-closed if ps args output is near the OS truncation limit (~8KB on macOS).
  # An attacker can pad argv past the truncation point and append the env var after it.
  if [[ "${#ps_argv}" -ge 8190 ]]; then
    echo "BLOCKED-CAPABILITY: ps args truncated (${#ps_argv} bytes) — fail-closed for pid ${ppid}" >&2
    return 1
  fi
  ps_full=$(ps eww -p "$ppid" -o args= 2>/dev/null) || return 1
  # fail-closed if ps eww output is near the OS truncation limit (~8KB).
  # An attacker can pad the ENV section to push CLAUDE_PLAN_CAPABILITY past the cutoff.
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
  if printf '%s' "$env_part" | grep -qE '(^| )CLAUDE_PLAN_CAPABILITY=harness( |$)'; then
    return 0
  fi
  [[ -n "${CLAUDE_DEBUG_PPID:-}" ]] && \
    echo "[ppid-chain] CLAUDE_PLAN_CAPABILITY=harness not found in env of pid ${ppid}" >&2
  return 1
}

# Walk PPID chain checking for a harness script ancestor with CLAUDE_PLAN_CAPABILITY=harness.
# Depth is capped by CLAUDE_PPID_CHAIN_DEPTH (default 10) for testability.
# TOCTOU guard: captures comm before and after _check_parent_env; mismatch → fail-closed.
_ppid_chain_is_harness() {
  local pid="$$" depth=0
  local _max="${CLAUDE_PPID_CHAIN_DEPTH:-10}"
  while [[ $depth -lt $_max ]]; do
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 1
    [[ -z "$pid" ]] && return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ "$pid" -le 1 ]] && return 1
    local _args_before _args_after _lstart_before _lstart_after
    # Use full args= (not comm= which truncates at 15 bytes) for identity check.
    _args_before=$(ps -p "$pid" -o args= 2>/dev/null | awk '{print $1}') || { depth=$((depth + 1)); continue; }
    _lstart_before=$(ps -p "$pid" -o lstart= 2>/dev/null | tr -s ' ') || _lstart_before=""
    # Check env var of parent process rather than argv to prevent argv-inject bypass.
    if _check_parent_env "$pid"; then
      # TOCTOU guard: verify process identity (path + start time) didn't change during env check.
      _args_after=$(ps -p "$pid" -o args= 2>/dev/null | awk '{print $1}') || return 1
      _lstart_after=$(ps -p "$pid" -o lstart= 2>/dev/null | tr -s ' ') || _lstart_after=""
      if [[ "$_args_before" != "$_args_after" ]]; then
        [[ -n "${CLAUDE_DEBUG_PPID:-}" ]] && \
          echo "[ppid-chain] WARN: pid $pid changed args during env check (${_args_before} → ${_args_after}) — fail-closed" >&2
        return 1
      fi
      # fail-closed if lstart is empty (race condition) — empty == empty would be a false pass.
      if [[ -z "$_lstart_before" ]] || [[ -z "$_lstart_after" ]]; then
        [[ -n "${CLAUDE_DEBUG_PPID:-}" ]] && \
          echo "[ppid-chain] WARN: pid $pid lstart empty during env check — fail-closed" >&2
        return 1
      fi
      if [[ "$_lstart_before" != "$_lstart_after" ]]; then
        [[ -n "${CLAUDE_DEBUG_PPID:-}" ]] && \
          echo "[ppid-chain] WARN: pid $pid lstart changed during env check — fail-closed" >&2
        return 1
      fi
      return 0
    fi
    depth=$((depth + 1))
  done
  [[ -n "${CLAUDE_DEBUG_PPID:-}" ]] && echo "[ppid-chain] no harness ancestor in $_max levels" >&2
  return 1
}

# require_capability CMD [RING]
# RING=B (default): allow if (launcher token OR (env-var AND PPID chain)) OR TTY.
# RING=C: allow if CLAUDE_PLAN_CAPABILITY=human or stdin is TTY.
require_capability() {
  local cmd="$1" ring="${2:-B}"
  if [[ "$ring" == "C" ]]; then
    [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "human" ]] && return 0
    die "[$cmd] is human-only — set CLAUDE_PLAN_CAPABILITY=human in the calling shell"
  fi
  # D1: launcher token is the preferred primary gate.
  if declare -F launcher_token_verify >/dev/null 2>&1 && launcher_token_verify 2>/dev/null; then
    [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "harness" ]] && return 0
  fi
  # Ring B fallback: env-var AND PPID chain
  if [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "harness" ]] && _ppid_chain_is_harness; then
    return 0
  fi
  die "[$cmd] requires CLAUDE_PLAN_CAPABILITY=harness"
}
