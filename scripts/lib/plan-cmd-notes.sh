#!/usr/bin/env bash
# Plan notes, stop-block, and context commands.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PLAN_CMD_NOTES_LOADED:-}" ]] && return 0
_PLAN_CMD_NOTES_LOADED=1

_PLAN_CMD_NOTES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_PLAN_CMD_STATE_LOADED:-}" ]] || . "$_PLAN_CMD_NOTES_DIR/plan-cmd-state.sh"

cmd_append_note() {
  local plan_file="$1" note="$2"
  if [[ "${CLAUDE_PLAN_CAPABILITY:-agent}" != "harness" && "${CLAUDE_PLAN_CAPABILITY:-agent}" != "human" ]]; then
    if printf '%s' "${note:-}" | grep -qE '\[[A-Z][A-Z0-9_:-]*\]'; then
      die "append-note: control marker tokens (e.g. [BLOCKED], [CONVERGED], [IMPLEMENTED: x]) are reserved for the harness — use free-form text for notes in ## Open Questions"
    fi
  fi
  require_file "$plan_file"
  _append_to_open_questions "$plan_file" "$note"
  if printf '%s' "${note:-}" | grep -qE '^\[BLOCKED'; then
    if command -v jq >/dev/null 2>&1; then
      sc_ensure_dir "$plan_file" || return 1
      local _kind="runtime"
      case "$note" in
        *'[BLOCKED-CEILING]'*) _kind="ceiling" ;;
        *'[BLOCKED] parse:'*)  _kind="parse" ;;
        *'[BLOCKED] category:'*) _kind="category" ;;
        *'[BLOCKED] protocol-violation:'*) _kind="protocol-violation" ;;
        *'[BLOCKED] preflight:'*) _kind="preflight" ;;
        *'[BLOCKED] integration:'*) _kind="integration" ;;
        *'[BLOCKED] coder:'*) _kind="coder" ;;
        *'[BLOCKED-AMBIGUOUS]'*) _kind="ambiguous" ;;
        *'[BLOCKED] script-failure:'*|*'[BLOCKED] session-timeout'*|*'[BLOCKED] no timeout'*|*'[BLOCKED] plan unchanged'*) _kind="runtime" ;;
      esac
      _record_blocked "$plan_file" "$_kind" "harness" "$(basename "$plan_file" .md)" "$note" 2>/dev/null || true
    fi
  fi
}

cmd_record_stop_block() {
  local plan_file="$1" phase="$2" reason="$3"
  require_file "$plan_file"
  local ts
  ts=$(_iso_timestamp)
  _append_to_open_questions "$plan_file" \
    "[STOP-BLOCKED @${ts}] phase=${phase} — ${reason}"
  echo "[record-stop-block] recorded stop block (phase=${phase}): ${reason}" >&2
}

cmd_context() {
  require_jq
  local plan_file
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0

  local phase
  phase=$(_require_phase "$plan_file" "cmd_context") || exit 0

  local verdicts
  verdicts=$(awk '/^## Critic Verdicts$/{found=1; next} found && /^## /{found=0} found && /^- /{print}' \
    "$plan_file" 2>/dev/null | tail -3 | sed 's/^- //' | tr '\n' '|' | sed 's/|$//' || echo "none")

  local blocked_items other_items questions
  blocked_items=$(awk '/^## Open Questions$/{found=1; next} found && /^## /{found=0} found && (/\[BLOCKED/ || /\[STOP-BLOCKED/){print}' \
    "$plan_file" 2>/dev/null | head -3 | tr '\n' '|' | sed 's/|$//' || true)
  other_items=$(awk '/^## Open Questions$/{found=1; next} found && /^## /{found=0} found && /[^[:space:]]/ && !/\[BLOCKED/ && !/\[STOP-BLOCKED/ && !/\[CONVERGED/ && !/\[FIRST-TURN/ && !/\[AUTO-DECIDED/{print}' \
    "$plan_file" 2>/dev/null | head -2 | tr '\n' '|' | sed 's/|$//' || true)

  if [ -n "$blocked_items" ] && [ -n "$other_items" ]; then
    questions="${blocked_items}|${other_items}"
  elif [ -n "$blocked_items" ]; then
    questions="$blocked_items"
  elif [ -n "$other_items" ]; then
    questions="$other_items"
  else
    questions="none"
  fi

  local line_count size_warning=""
  line_count=$(wc -l < "$plan_file" 2>/dev/null || echo 0)
  if [ "$line_count" -gt 500 ]; then
    size_warning=" | WARNING: plan file is ${line_count} lines (>500) — run gc-events or archive old sections"
  fi

  local path_phase verdicts_str questions_str
  path_phase="Active plan: ${plan_file} | Phase: ${phase}"
  verdicts_str="Recent verdicts: ${verdicts:-none}"
  if [ "${#verdicts_str}" -gt 300 ]; then verdicts_str="${verdicts_str:0:297}..."; fi
  questions_str="Open questions: ${questions}"
  if [ "${#questions_str}" -gt 400 ]; then questions_str="${questions_str:0:397}..."; fi

  local body_raw body
  body_raw="${path_phase} | ${verdicts_str} | ${questions_str}${size_warning}"
  if [ "${#body_raw}" -gt 800 ]; then
    body="${body_raw:0:797}..."
  else
    body="$body_raw"
  fi

  jq -nc --arg ctx "$body" \
    '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$ctx}}'
}
