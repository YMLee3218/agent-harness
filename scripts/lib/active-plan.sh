#!/usr/bin/env bash
set -euo pipefail
# Shared helpers: stdin-JSON hook utilities and active-plan resolution.
# Source this file; do not execute directly.
#
# Callers must set PLAN_FILE_SH before sourcing this file (required by plan-resolution functions).
# Optional: set BLOCKED_LABEL to a context string for error messages (default: "active-plan").
#
# Hook utilities:
#   require_jq_or_block <label> [strict]          — exits 2 (strict) or warns when jq absent
#   extract_tool_input_path <json>                — prints file_path or notebook_path
#   extract_tool_input_command <json>             — prints .tool_input.command
#
# Plan-resolution functions:
#   die_with_reason <rc>                          — exits 2 on rc=3/4 with BLOCKED message
#   resolve_active_plan_and_phase <pvar> <phvar>  — sets plan path + phase; returns 1 if none found
#   resolve_with_latest_fallback  <pvar> <phvar>  — like above but falls back to find-latest
#   bootstrap_block_if_strict <path>              — returns 2+BLOCKED when STRICT=1 and path is src/test
[[ -n "${_ACTIVE_PLAN_LOADED:-}" ]] && return 0
_ACTIVE_PLAN_LOADED=1

# ── Hook utilities ───────────────────────────────────────────────────────────

# require_jq_or_block <label> [strict=1]
#   strict=1 → exit 2 with "BLOCKED [label]: jq is required but not found"
#   strict=0 → return 1 with advisory message; caller decides
require_jq_or_block() {
  local label="$1" strict="${2:-1}"
  command -v jq >/dev/null 2>&1 && return 0
  if [ "$strict" = "1" ]; then
    echo "BLOCKED [$label]: jq is required but not found" >&2
    exit 2
  fi
  echo "[$label] warning: jq not found" >&2
  return 1
}

# extract_tool_input_field <field> <json> → prints .tool_input[field] (empty if absent)
extract_tool_input_field() {
  printf '%s' "$2" | jq -r --arg f "$1" '.tool_input[$f] // empty' 2>/dev/null
}

# extract_tool_input_path <json>   → prints file_path or notebook_path (empty if absent)
extract_tool_input_path() {
  printf '%s' "$1" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null
}

# extract_tool_input_command <json> → prints .tool_input.command (empty if absent)
extract_tool_input_command() { extract_tool_input_field command "$1"; }

# ── Plan-resolution functions ─────────────────────────────────────────────────

# die_with_reason <rc>
# Exits 2 with a BLOCKED message when rc indicates ambiguous (3) or malformed (4) plan state.
# Does nothing for all other rc values.
die_with_reason() {
  local _label="${BLOCKED_LABEL:-active-plan}"
  case "$1" in
    3) echo "BLOCKED [${_label}]: multiple active plan files — set CLAUDE_PLAN_FILE=plans/{slug}.md to disambiguate" >&2; exit 2 ;;
    4) echo "BLOCKED [${_label}]: plan file exists but phase is unreadable — repair the plan file or state JSON" >&2; exit 2 ;;
  esac
}

# _resolve_plan_core <plan_var> <phase_var> <latest_fallback>
# Shared implementation. latest_fallback=1: try find-latest when find-active finds nothing.
# latest_fallback=0: return 1 immediately when find-active finds nothing.
_resolve_plan_core() {
  local _pv="$1" _phv="$2" _with_latest_fallback="$3" _plan _rc _phase
  if [ -n "${CLAUDE_PLAN_FILE:-}" ] && [ -f "$CLAUDE_PLAN_FILE" ]; then
    _plan="$CLAUDE_PLAN_FILE"
  else
    _plan=$(bash "$PLAN_FILE_SH" find-active 2>/dev/null)
    _rc=$?
    die_with_reason "$_rc"
    if [ $_rc -ne 0 ]; then
      if [ "$_with_latest_fallback" = "1" ]; then
        # Fallback: try find-latest (best-effort for status display or no-plan bootstrap)
        _plan=$(bash "$PLAN_FILE_SH" find-latest 2>/dev/null) || {
          printf -v "$_pv" '%s' ''
          printf -v "$_phv" '%s' ''
          return 1
        }
      else
        printf -v "$_pv" '%s' ''
        printf -v "$_phv" '%s' ''
        return 1
      fi
    fi
  fi
  _phase=$(bash "$PLAN_FILE_SH" get-phase "$_plan" 2>/dev/null) || {
    printf -v "$_pv" '%s' ''
    printf -v "$_phv" '%s' ''
    return 1
  }
  printf -v "$_pv" '%s' "$_plan"
  printf -v "$_phv" '%s' "$_phase"
  return 0
}

# resolve_active_plan_and_phase <plan_var> <phase_var>
# Resolves the active plan file (honoring CLAUDE_PLAN_FILE env) and its current phase.
# Returns 1 when no active plan is found. Exits 2 on rc=3/4 (ambiguous/malformed).
resolve_active_plan_and_phase() { _resolve_plan_core "$1" "$2" 0; }

# resolve_with_latest_fallback <plan_var> <phase_var>
# Like resolve_active_plan_and_phase but falls back to find-latest when no active plan is found.
# Used by phase-gate.sh which allows the latest plan as a fallback for the no-active-plan case.
resolve_with_latest_fallback() { _resolve_plan_core "$1" "$2" 1; }

# bootstrap_block_if_strict <path>
# When PHASE_GATE_STRICT=1 and no active plan exists, blocks writes to src/test paths.
# Returns 0 (allowed) when STRICT is unset/0, or when path is neither source nor test.
# Returns 2 (blocked) and prints a BLOCKED message when the path is src/test.
# Callers in phase-gate.sh and pretooluse-bash.sh use this to eliminate duplicated bootstrap logic.
bootstrap_block_if_strict() {
  local path="$1"
  [ "${PHASE_GATE_STRICT:-1}" = "1" ] || return 0
  [ -n "$path" ] || return 0
  # Source phase-policy.sh if functions are not yet available (standalone invocation guard).
  if ! declare -f is_source_path >/dev/null 2>&1; then
    local _lib_dir
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=../phase-policy.sh
    source "$_lib_dir/../phase-policy.sh"
  fi
  if is_source_path "$path" || is_test_path "$path"; then
    echo "BLOCKED [phase-gate]: PHASE_GATE_STRICT=1, no active plan file, and '$path' is a source/test path. Run /brainstorming first to create a plan, then advance to the appropriate phase." >&2
    return 2
  fi
  return 0
}

# ── Path helpers ──────────────────────────────────────────────────────────────

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
