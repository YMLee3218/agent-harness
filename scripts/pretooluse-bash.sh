#!/usr/bin/env bash
# PreToolUse hook for Bash tool.
# Reads JSON from stdin, extracts .tool_input.command, blocks destructive patterns.
# Exit 2 = blocked; exit 0 = allowed.
# Mistake-prevention layer; the capability gate is require_capability in capability.sh.
set -euo pipefail
# shellcheck source=lib/active-plan.sh
source "$(dirname "$0")/lib/active-plan.sh"
# shellcheck source=phase-policy.sh
source "$(dirname "$0")/phase-policy.sh"
# shellcheck source=pretooluse-blocks.sh
source "$(dirname "$0")/pretooluse-blocks.sh"
# shellcheck source=capability.sh (provides _RING_C_FILES for Ring C protection)
source "$(dirname "$0")/capability.sh"

input=$(cat)

require_jq_or_block "pretooluse-bash"

cmd=$(extract_tool_input_command "$input")

# ── Static blocking rules (unconditional pattern match) ──────────────────────
block_capability "$cmd"
block_destructive "$cmd"
block_execution "$cmd"
_dest_list=$(_bash_dest_paths "$cmd")
block_sidecar_writes "$cmd" "$_dest_list"

# ── Phase-aware bash write detection ─────────────────────────────────────────
PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"

block_plan_revert "$cmd"

if [ -f "$PLAN_FILE_SH" ]; then
  BLOCKED_LABEL="phase-gate/bash"

  # Read-only / no-write commands have no phase-gated destination — bypass
  # plan resolution so ambiguous-plan state does not block status checks,
  # ls, echo, grep, pipes that only read, and also git checkout/switch
  # (which mutate the working tree but produce no redirect/tee/cp/mv dest;
  # plans/*.state/ and plans/*.md remain protected by block_sidecar_writes
  # and block_plan_revert above).
  if [ -z "$_dest_list" ]; then
    exit 0
  fi

  _active_plan=""; _current_phase=""
  resolve_active_plan_and_phase _active_plan _current_phase || _active_plan=""
  _hmc_marker=""
  if [ -n "$_active_plan" ]; then
    _hmc_marker=$(marker_present_human_must_clear "$_active_plan" 2>/dev/null) || _hmc_marker=""
  fi
  while IFS= read -r _dest_p; do
    [ -z "$_dest_p" ] && continue
    if [ -n "$_hmc_marker" ]; then
      echo "BLOCKED [phase-gate/bash]: $_hmc_marker present — write prohibited; human must resolve and clear the marker from terminal" >&2; exit 2
    fi
    if [[ "$_dest_p" == */plans/*.md || "$_dest_p" == plans/*.md ]] && [[ "${CLAUDE_PLAN_CAPABILITY:-}" != "human" ]] && [[ "${CLAUDE_PLAN_CAPABILITY:-}" != "harness" ]]; then
      echo "BLOCKED [phase-gate/bash]: agent bash writes to plans/*.md are reserved for plan-file.sh harness commands" >&2; exit 2
    fi
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" && "${CLAUDE_PLAN_CAPABILITY:-}" != "human" ]]; then
      # Mirrors phase-gate.sh:42-47: canonicalize so symlinks don't bypass Ring C guard.
      _ring_proj=$(_canon_path "${CLAUDE_PROJECT_DIR}" 2>/dev/null) || _ring_proj="${CLAUDE_PROJECT_DIR}"
      _ring_dest=$(_canon_path "$_dest_p" 2>/dev/null) || _ring_dest="$_dest_p"
      _ring_rel="${_ring_dest#${_ring_proj}/}"
      [[ "$_ring_rel" == "$_ring_dest" ]] && _ring_rel="${_dest_p#${CLAUDE_PROJECT_DIR}/}"
      if printf '%s' "$_ring_rel" | grep -qE "^(${_RING_C_FILES})$"; then
        echo "BLOCKED [phase-gate/bash]: Ring C file ($(basename "$_dest_p")) is protected — only human edits accepted (set CLAUDE_PLAN_CAPABILITY=human to override)" >&2; exit 2
      fi
    fi
    if [ -n "$_current_phase" ]; then
      # Normalize to project-relative so is_source_path non-VSA fallback globs (lib/*, internal/*, etc.) match absolute paths.
      # Mirrors phase-gate.sh:124-131 which performs identical normalization for Write/Edit paths.
      _phase_dest="$_dest_p"
      if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
        _proj_abs="$(_canon_path "${CLAUDE_PROJECT_DIR}" 2>/dev/null)" || _proj_abs="${CLAUDE_PROJECT_DIR}"
        _dest_abs="$(_canon_path "$_dest_p" 2>/dev/null)" || _dest_abs="$_dest_p"
        _dest_rel="${_dest_abs#${_proj_abs}/}"
        [[ "$_dest_rel" == "$_dest_abs" ]] && _dest_rel="${_dest_p#${CLAUDE_PROJECT_DIR}/}"
        [[ "$_dest_rel" != "$_dest_p" ]] && _phase_dest="$_dest_rel"
      fi
      apply_phase_block "$_phase_dest" "$_current_phase" "phase-gate/bash" || exit 2
    else
      bootstrap_block_if_strict "$_dest_p" || exit 2
    fi
  done <<< "$_dest_list"
fi

exit 0
