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

  # Commands with no detected redirect/tee/cp/mv/sed-i/dd/awk-i destination
  # bypass phase checks — covers read-only commands (ls, echo, grep) and
  # write commands that don't use redirect syntax (git checkout/switch,
  # touch, mkdir, truncate, etc.). plans/*.md is additionally protected by
  # block_plan_revert above; sidecar dirs are NOT protected for no-destination
  # commands (mkdir/touch) — same accepted bypass gap as source/test paths.
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
    if [[ "$_dest_p" == "plans/__unexpanded__.state/__bypass__" ]]; then
      # Sentinel: actual write destination contained an unexpanded variable.
      # block_sidecar_writes already guarded sidecar/plan paths via raw-command checks.
      # Apply raw-command fallbacks here for Ring C and source/test phase protection.
      _raw_dest_tokens=$(
        # Shell redirects
        printf '%s' "$cmd" | grep -oE '>{1,2} *[^[:space:];|&)(<>]+' | sed 's/^>* *//' | tr -d '"'"'"
        # tee destinations
        printf '%s' "$cmd" | grep -oE '\btee( +[^[:space:]]+)+' | sed 's/^tee *//' | tr ' ' '\n' | grep -v '^-' | tr -d '"'"'" || true
        # sed -i destinations
        printf '%s' "$cmd" | grep -oE '\bsed +-i[^ ]*( +[^[:space:];|&]+)+' | awk '{print $NF}' | tr -d '"'"'" || true
        # dd of= destinations
        printf '%s' "$cmd" | grep -oE '\bdd\b[^|]*\bof=[^[:space:]]+' | grep -oE '\bof=[^[:space:]]+' | sed 's/^of=//' | tr -d '"'"'" || true
        # awk -i inplace destinations
        printf '%s' "$cmd" | grep -oE 'awk[[:space:]]+-i[[:space:]]*(in-?place)?[^|;&]*' | awk '{print $NF}' | tr -d '"'"'" || true
        # cp/mv destinations
        printf '%s' "$cmd" | grep -oE '(^|[;|&[:space:]])(cp|mv)([[:space:]]+(-[[:alpha:]]+|--[a-zA-Z-]+=?[^[:space:];|&]*|[^[:space:];|&]+))+' | while IFS= read -r _cpmv; do
          [[ -n "$_cpmv" ]] || continue
          _t2=$(printf '%s' "$_cpmv" | grep -oE '(-t[[:space:]]+|--target-directory[[:space:]]+|--target-directory=)[^[:space:];|&]+' \
            | sed 's/^-t[[:space:]]*//' | sed 's/^--target-directory[[:space:]][[:space:]]*//' | sed 's/^--target-directory=//' | tail -1 | tr -d '"'"'" 2>/dev/null || true)
          if [[ -n "$_t2" ]]; then
            printf '%s\n' "$_t2"
          else
            printf '%s' "$_cpmv" | tr ' ' '\n' | grep -vE '^-' | tail -1 | tr -d '"'"'" 2>/dev/null || true
          fi
        done || true
      )
      if [[ -n "${CLAUDE_PROJECT_DIR:-}" && "${CLAUDE_PLAN_CAPABILITY:-}" != "human" ]]; then
        if printf '%s' "$_raw_dest_tokens" \
             | grep -qE "/${_RING_C_INNER}"; then
          echo "BLOCKED [phase-gate/bash]: Ring C file (unexpanded path) is protected — only human edits accepted (set CLAUDE_PLAN_CAPABILITY=human to override)" >&2; exit 2
        fi
      fi
      if [ -n "$_current_phase" ]; then
        if printf '%s' "$_raw_dest_tokens" \
             | grep -qE '/(src/(domain|features|infrastructure)/|src/main/[^/]+/|internal/|cmd/|pkg/|app/|lib/|crates/[^/]+/src/|apps/[^/]+/src/|packages/[^/]+/src/)'; then
          apply_phase_block "src/domain/__guard__" "$_current_phase" "phase-gate/bash" || exit 2
        fi
        if printf '%s' "$_raw_dest_tokens" \
             | grep -E '(/tests/|_test\.|test_[^/]+\.|\.test\.|\.spec\.|_spec\.)' \
             | grep -qv '\.spec\.md$'; then
          apply_phase_block "tests/__guard__" "$_current_phase" "phase-gate/bash" || exit 2
        fi
      else
        # No active plan — apply strict-mode guard via raw patterns for unexpanded destinations.
        if printf '%s' "$_raw_dest_tokens" \
             | grep -qE '/(src/(domain|features|infrastructure)/|src/main/[^/]+/|internal/|cmd/|pkg/|app/|lib/|crates/[^/]+/src/|apps/[^/]+/src/|packages/[^/]+/src/)'; then
          bootstrap_block_if_strict "src/domain/__guard__" || exit 2
        fi
        if printf '%s' "$_raw_dest_tokens" \
             | grep -E '(/tests/|_test\.|test_[^/]+\.|\.test\.|\.spec\.|_spec\.)' \
             | grep -qv '\.spec\.md$'; then
          bootstrap_block_if_strict "tests/__guard__" || exit 2
        fi
      fi
      continue
    fi
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" && "${CLAUDE_PLAN_CAPABILITY:-}" != "human" ]]; then
      # Mirrors phase-gate.sh:42-52: canonicalize so symlinks don't bypass Ring C guard.
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
      # Mirrors phase-gate.sh:128-134 which performs identical normalization for Write/Edit paths.
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
