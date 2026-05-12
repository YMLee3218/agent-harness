#!/usr/bin/env bash
# PreToolUse hook for Bash tool.
# Reads JSON from stdin, extracts .tool_input.command, blocks destructive patterns.
# Exit 2 = blocked; exit 0 = allowed.
#
# NOTE: This is a *mistake-prevention* gate, not a security boundary.
# bash quote-removal/backslash-escape can defeat any text-pattern match here.
# Real enforcement requires process isolation (uid separation) or seccomp.
set -euo pipefail
# shellcheck source=lib/active-plan.sh
source "$(dirname "$0")/lib/active-plan.sh"
# shellcheck source=phase-policy.sh
source "$(dirname "$0")/phase-policy.sh"
# shellcheck source=pretooluse-blocks.sh
source "$(dirname "$0")/pretooluse-blocks.sh"

input=$(cat)

require_jq_or_block "pretooluse-bash"

cmd=$(extract_tool_input_command "$input")

# ── Static blocking rules (unconditional pattern match) ──────────────────────
block_capability "$cmd"
block_destructive "$cmd"
block_execution "$cmd"
block_sidecar_writes "$cmd"

# ── Phase-aware bash write detection ─────────────────────────────────────────
PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"

block_plan_revert "$cmd"

if [ -f "$PLAN_FILE_SH" ]; then
  BLOCKED_LABEL="phase-gate/bash"
  _active_plan=""; _current_phase=""
  resolve_active_plan_and_phase _active_plan _current_phase || _active_plan=""
  if [ -n "$_active_plan" ]; then
    if _hmc_marker=$(marker_present_human_must_clear "$_active_plan" 2>/dev/null); then
      _ba_write=0
      while IFS= read -r _ba_p; do [ -n "$_ba_p" ] && _ba_write=1 && break; done < <(_bash_dest_paths "$cmd")
      [ "$_ba_write" -eq 1 ] && { echo "BLOCKED [phase-gate/bash]: [$_hmc_marker] present — write prohibited; human must resolve and clear the marker from terminal" >&2; exit 2; }
    fi
  fi
  while IFS= read -r _dest_p; do
    [ -z "$_dest_p" ] && continue
    if is_sidecar_path "$_dest_p"; then
      echo "BLOCKED [phase-gate/bash]: plans/{slug}.state/ is harness-exclusive — write denied" >&2; exit 2
    fi
    if [[ "$_dest_p" == */plans/*.md ]] && [[ "${CLAUDE_PLAN_CAPABILITY:-}" != "human" ]] && [[ "${CLAUDE_PLAN_CAPABILITY:-}" != "harness" ]]; then
      echo "BLOCKED [phase-gate/bash]: agent bash writes to plans/*.md are reserved for plan-file.sh harness commands" >&2; exit 2
    fi
    if [ -n "$_current_phase" ]; then
      apply_phase_block "$_dest_p" "$_current_phase" "phase-gate/bash" || exit 2
    else
      bootstrap_block_if_strict "$_dest_p" || exit 2
    fi
  done < <(_bash_dest_paths "$cmd")
fi

exit 0
