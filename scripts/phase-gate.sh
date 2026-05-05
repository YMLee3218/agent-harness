#!/usr/bin/env bash
# Phase-gate hook — enforces plan-file phase rules via PreToolUse hooks.
#
# Usage:
#   phase-gate.sh write    (PreToolUse Write|Edit — reads tool JSON from stdin)
#
# Exit 2 = block the tool call
# Exit 0 = allow
#
# Fail-closed when PHASE_GATE_STRICT=1 (default): if no active plan file exists, block writes to src/ and test paths (non-source paths remain permitted — see lib/active-plan.sh bootstrap_block_if_strict).
# Fail-open when PHASE_GATE_STRICT=0: if no active plan file, allow unconditionally with a warning.

PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"
BLOCKED_LABEL="phase-gate"
# shellcheck source=phase-policy.sh
source "$(dirname "$0")/phase-policy.sh"
# shellcheck source=lib/active-plan.sh
source "$(dirname "$0")/lib/active-plan.sh"

get_active_phase() {
  local _plan _phase
  if ! resolve_with_latest_fallback _plan _phase; then
    GATE_FAIL_REASON="none"
    return 1
  fi
  echo "$_phase"
}

mode_write() {
  local input
  input=$(cat)

  require_jq_or_block "phase-gate" "${PHASE_GATE_STRICT:-1}" || { echo "[phase-gate] warning: jq not found; write allowed (strict mode off)" >&2; exit 0; }

  local phase
  GATE_FAIL_REASON="none"
  if ! phase=$(get_active_phase); then
    local file_path_early
    file_path_early=$(extract_tool_input_path "$input")
    bootstrap_block_if_strict "$file_path_early" || exit 2
    echo "[phase-gate] no active plan file; bootstrap write allowed for '$file_path_early'. Run /brainstorming to enable full phase gating." >&2
    exit 0
  fi

  local file_path
  file_path=$(extract_tool_input_path "$input")
  [ -z "$file_path" ] && exit 0

  # [BLOCKED-AMBIGUOUS] → block all writes regardless of mode
  local _ba_plan _ba_phase
  if resolve_with_latest_fallback _ba_plan _ba_phase 2>/dev/null; then
    if grep -qF "[BLOCKED-AMBIGUOUS]" "$_ba_plan"; then
      echo "BLOCKED: [BLOCKED-AMBIGUOUS] present — write prohibited; human must resolve the question and clear the marker from terminal" >&2
      exit 2
    fi
  fi

  apply_phase_block "$file_path" "$phase" "phase-gate" || exit 2

  if [ "$phase" = "done" ] && ! is_source_path "$file_path" && ! is_test_path "$file_path"; then
    echo "[phase-gate] warning: most recent plan is 'done' but '$file_path' is not a source/test file — allowing. To start a new feature, run /brainstorming." >&2
    exit 0
  fi

  exit 0
}

[ $# -ge 1 ] || { echo "Usage: phase-gate.sh <write>" >&2; exit 1; }

case "$1" in
  write)  mode_write ;;
  *) echo "Unknown mode: $1" >&2; exit 1 ;;
esac
