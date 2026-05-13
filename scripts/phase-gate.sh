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
# Fail-closed when PHASE_GATE_STRICT=1 (default): if no plan file exists at all, block writes to src/ and test paths (non-source paths remain permitted — see lib/active-plan.sh bootstrap_block_if_strict). A done-phase plan applies done-phase policy regardless of STRICT.
# Fail-open when PHASE_GATE_STRICT=0: if no plan file exists at all, allow unconditionally with a warning. A done-phase plan still applies done-phase policy.

PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"
BLOCKED_LABEL="phase-gate"
# shellcheck source=phase-policy.sh
source "$(dirname "$0")/phase-policy.sh"
# shellcheck source=lib/active-plan.sh
source "$(dirname "$0")/lib/active-plan.sh"
# shellcheck source=capability.sh (provides shared _RING_C_FILES constant)
source "$(dirname "$0")/capability.sh"

get_active_phase() {
  local _plan _phase
  if ! resolve_with_latest_fallback _plan _phase; then
    GATE_FAIL_REASON="none"
    return 1
  fi
  echo "$_phase"
}

# _guard_ring_c INPUT — blocks writes to Ring C files unless capability=human.
# _RING_C_FILES constant is defined in capability.sh (sourced above).
_guard_ring_c() {
  local _input="$1"
  [[ -z "${CLAUDE_PROJECT_DIR:-}" ]] && return 0
  [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "human" ]] && return 0
  local _file
  _file=$(extract_tool_input_path "$_input")
  [[ -z "$_file" ]] && return 0
  local _proj _file_norm _rel
  _proj=$(_canon_path "${CLAUDE_PROJECT_DIR}" 2>/dev/null) || _proj="${CLAUDE_PROJECT_DIR}"
  _file_norm=$(_canon_path "$_file" 2>/dev/null) || _file_norm="$_file"
  # Try canonical prefix strip first; fall back to raw paths to handle
  # symlinks in /tmp (e.g. macOS /tmp → /private/tmp) when target doesn't exist.
  _rel="${_file_norm#${_proj}/}"
  [[ "$_rel" == "$_file_norm" ]] && _rel="${_file#${CLAUDE_PROJECT_DIR}/}"
  [[ "$_rel" == "$_file" ]] && return 0
  if printf '%s' "$_rel" | grep -qE "^(${_RING_C_FILES})$"; then
    echo "BLOCKED [phase-gate]: Ring C file ($(basename "$_file")) is protected — only human edits accepted (set CLAUDE_PLAN_CAPABILITY=human to override)" >&2
    exit 2
  fi
}

# _guard_no_plan INPUT — handles the no-active-plan path; exits (allow or block).
_guard_no_plan() {
  local _input="$1"
  local _fp; _fp=$(extract_tool_input_path "$_input")
  bootstrap_block_if_strict "$_fp" || exit 2
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

# _guard_plan_phase_mutation INPUT FILE_PATH — blocks direct phase edits to plans/*.md.
# Phase transitions must go through plan-file.sh transition/set-phase (Ring B).
_guard_plan_phase_mutation() {
  local _input="$1" _file_path="$2"
  [[ "$_file_path" == */plans/*.md ]] || return 0
  [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "human" ]] && return 0
  [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "harness" ]] && return 0
  local _new _old
  _new=$(printf '%s' "$_input" | jq -r '.tool_input.content // .tool_input.new_string // ""' 2>/dev/null)
  _old=$(printf '%s' "$_input" | jq -r '.tool_input.old_string // ""' 2>/dev/null)
  if printf '%s\n%s' "$_old" "$_new" | grep -qE '(^|\n)## Phase($|\n)|(^|\n)phase:[[:space:]]+[a-z]+'; then
    echo "BLOCKED [phase-gate]: writes touching '## Phase' or frontmatter 'phase:' are reserved for 'plan-file.sh transition/set-phase' (Ring B). Use the harness command instead of editing plan.md directly." >&2
    exit 2
  fi
  if printf '%s' "$_new" | grep -qF '[CONVERGED]'; then
    echo "BLOCKED [phase-gate]: '[CONVERGED]' is not a valid plan-file marker — convergence state lives in the sidecar only (plans/{slug}.state/convergence/)" >&2
    exit 2
  fi
}

# _guard_human_must_clear — blocks all writes when any HUMAN_MUST_CLEAR_MARKERS entry is present.
_guard_human_must_clear() {
  local _plan _phase _found
  if resolve_with_latest_fallback _plan _phase 2>/dev/null; then
    if _found=$(marker_present_human_must_clear "$_plan"); then
      echo "BLOCKED: [$_found] present — write prohibited; human must resolve and clear the marker from terminal" >&2
      exit 2
    fi
  fi
}

mode_write() {
  local input; input=$(cat)

  # A5: validate CLAUDE_PLAN_FILE doesn't point outside plans/ (must run before $() subshell)
  _assert_plan_file_inside_plans

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
  _guard_human_must_clear
  _guard_plan_phase_mutation "$input" "$file_path"

  # Normalize to project-relative so is_source_path non-VSA fallback globs (lib/*, internal/*, etc.) match absolute paths.
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    local _proj _file_norm _rel
    _proj=$(_canon_path "${CLAUDE_PROJECT_DIR}" 2>/dev/null) || _proj="${CLAUDE_PROJECT_DIR}"
    _file_norm=$(_canon_path "$file_path" 2>/dev/null) || _file_norm="$file_path"
    _rel="${_file_norm#${_proj}/}"
    [[ "$_rel" == "$_file_norm" ]] && _rel="${file_path#${CLAUDE_PROJECT_DIR}/}"
    [[ "$_rel" != "$file_path" ]] && file_path="$_rel"
  fi

  apply_phase_block "$file_path" "$phase" "phase-gate" || exit 2

  exit 0
}

[ $# -ge 1 ] || { echo "Usage: phase-gate.sh <write>" >&2; exit 1; }

case "$1" in
  write)  mode_write ;;
  *) echo "Unknown mode: $1" >&2; exit 1 ;;
esac
