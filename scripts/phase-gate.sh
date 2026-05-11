#!/usr/bin/env bash
set -euo pipefail
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

# _guard_ring_c INPUT — blocks writes to CLAUDE.md (Ring C) unless capability=human.
_guard_ring_c() {
  local _input="$1"
  [[ -z "${CLAUDE_PROJECT_DIR:-}" ]] && return 0
  local _claudemd _file _cm_canon _file_canon
  _claudemd="${CLAUDE_PROJECT_DIR}/CLAUDE.md"
  _file=$(extract_tool_input_path "$_input")
  [[ -z "$_file" ]] && return 0
  _cm_canon=$(_canon_path "$_claudemd" 2>/dev/null) || _cm_canon="$_claudemd"
  _file_canon=$(_canon_path "$_file" 2>/dev/null) || _file_canon="$_file"
  if [[ "$_file_canon" == "$_cm_canon" ]] && [[ "${CLAUDE_PLAN_CAPABILITY:-}" != "human" ]]; then
    echo "BLOCKED [phase-gate]: CLAUDE.md is Ring C — only human edits accepted (set CLAUDE_PLAN_CAPABILITY=human to override)" >&2
    exit 2
  fi
}

# _guard_no_plan INPUT — handles the no-active-plan path; exits (allow or block).
_guard_no_plan() {
  local _input="$1"
  local _fp; _fp=$(extract_tool_input_path "$_input")
  bootstrap_block_if_strict "$_fp" || exit 2
  echo "[phase-gate] no active plan file; bootstrap write allowed for '$_fp'. Run /brainstorming to enable full phase gating." >&2
  exit 0
}

# _guard_sidecar FILE_PATH — blocks writes to sidecar state directories.
_guard_sidecar() {
  local _fp="$1"
  if is_sidecar_path "$_fp"; then
    echo "BLOCKED [phase-gate]: plans/{slug}.state/ is harness-exclusive — agent cannot edit control state" >&2
    exit 2
  fi
}

# _guard_ambiguous — blocks all writes when [BLOCKED-AMBIGUOUS] is present in the active plan.
_guard_ambiguous() {
  local _plan _phase
  if resolve_with_latest_fallback _plan _phase 2>/dev/null; then
    if grep -qF "[BLOCKED-AMBIGUOUS]" "$_plan"; then
      echo "BLOCKED: [BLOCKED-AMBIGUOUS] present — write prohibited; human must resolve the question and clear the marker from terminal" >&2
      exit 2
    fi
  fi
}

mode_write() {
  local input; input=$(cat)

  require_jq_or_block "phase-gate" "${PHASE_GATE_STRICT:-1}" || { echo "[phase-gate] warning: jq not found; write allowed (strict mode off)" >&2; exit 0; }

  _guard_ring_c "$input"

  local phase
  GATE_FAIL_REASON="none"
  if ! phase=$(get_active_phase); then
    _guard_no_plan "$input"
  fi

  local file_path; file_path=$(extract_tool_input_path "$input")
  [ -z "$file_path" ] && exit 0

  _guard_sidecar "$file_path"
  _guard_ambiguous

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
