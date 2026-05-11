#!/usr/bin/env bash
# Plan task ledger + gc-events/gc-verdicts/gc-sidecars.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PLAN_CMD_TASKS_GC_LOADED:-}" ]] && return 0
_PLAN_CMD_TASKS_GC_LOADED=1

_PLAN_CMD_TASKS_GC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_PLAN_LIB_LOADED:-}" ]] || . "$_PLAN_CMD_TASKS_GC_DIR/plan-lib.sh"
[[ -n "${_PLAN_CMD_STATE_LOADED:-}" ]] || . "$_PLAN_CMD_TASKS_GC_DIR/plan-cmd-state.sh"

cmd_add_task() {
  local plan_file="$1" task_id="$2" layer="$3"
  require_file "$plan_file"
  grep -qF "| ${task_id} |" "$plan_file" 2>/dev/null && return 0
  local row="| ${task_id} | ${layer} | pending | - |"
  if grep -q "^## Task Ledger$" "$plan_file"; then
    _awk_inplace "$plan_file" -v row="$row" '
      /^## Task Ledger$/ { print; in_section=1; next }
      in_section && /^\| task-id/ { print; next }
      in_section && /^\|---/ { print; next }
      in_section && /^## / { print row; print ""; print; in_section=0; next }
      { print }
      END { if (in_section) print row }
    '
  else
    {
      echo ""
      echo "## Task Ledger"
      echo "| task-id | layer | status | commit-sha |"
      echo "|---------|-------|--------|------------|"
      echo "$row"
    } >> "$plan_file"
  fi
}

cmd_update_task() {
  local plan_file="$1" task_id="$2" status="$3" commit_sha="${4:--}"
  require_file "$plan_file"
  local valid_statuses="pending in_progress completed blocked"
  local valid=0
  for s in $valid_statuses; do [ "$s" = "$status" ] && valid=1 && break; done
  [ "$valid" -eq 1 ] || die "invalid status: $status (must be one of: $valid_statuses)"
  _awk_inplace "$plan_file" -v tid="$task_id" -v status="$status" -v sha="$commit_sha" '
    /^\| / {
      n = split($0, fields, "|")
      if (n >= 5) {
        id = fields[2]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
        if (id == tid) {
          layer = fields[3]
          printf "| %s |%s| %s | %s |\n", tid, layer, status, sha
          matched++
          next
        }
      }
    }
    { print }
    END { exit (matched == 0) ? 1 : 0 }
  ' || { echo "ERROR: task id '$task_id' not found in $plan_file" >&2; exit 1; }
}

cmd_tier_safe() {
  local plan_file="$1"; shift
  require_file "$plan_file"
  [ $# -ge 1 ] || die "tier-safe requires at least one task-id"
  local blocked_tasks="" task_id status
  for task_id in "$@"; do
    status=$(awk -v tid="$task_id" '
      /^## Task Ledger$/ { in_section=1; next }
      in_section && /^## / { in_section=0 }
      in_section && /^\| / {
        n = split($0, f, "|")
        if (n >= 5) {
          id = f[2]; sub(/^[[:space:]]+/, "", id); sub(/[[:space:]]+$/, "", id)
          st = f[4]; sub(/^[[:space:]]+/, "", st); sub(/[[:space:]]+$/, "", st)
          if (id == tid) { print st; exit }
        }
      }
    ' "$plan_file" 2>/dev/null || true)
    if [ "$status" = "blocked" ]; then
      blocked_tasks="${blocked_tasks} ${task_id}(ledger:blocked)"
      continue
    fi
    if grep -qF "[BLOCKED] coder:${task_id}" "$plan_file" 2>/dev/null; then
      blocked_tasks="${blocked_tasks} ${task_id}([BLOCKED] coder)"
    fi
  done
  if [ -n "$blocked_tasks" ]; then
    echo "BLOCKED [tier-safe]: the following tasks are blocked — cannot merge tier:${blocked_tasks}" >&2
    exit 2
  fi
  exit 0
}

cmd_record_task_completed() {
  require_jq
  local input task_id plan_file
  input=$(cat)
  task_id=$(printf '%s' "$input" | jq -r '.task_id // "unknown"' 2>/dev/null || echo "unknown")
  [[ "$task_id" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "[record-task-completed] invalid task_id: ${task_id}" >&2; exit 0; }
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0
  cmd_update_task "$plan_file" "$task_id" "completed" || true
  echo "[record-task-completed] marked task (${task_id}) completed in ${plan_file}" >&2
}

cmd_gc_events() {
  local plan_file
  plan_file=$(cmd_find_active 2>/dev/null) || { echo "[gc-events] no active plan file" >&2; exit 0; }
  if ! grep -q "^## Open Questions$" "$plan_file"; then
    echo "[gc-events] no Open Questions section in ${plan_file}" >&2
    exit 0
  fi
  _awk_inplace "$plan_file" '
    /^## Open Questions$/ { in_section=1; print; next }
    in_section && /^## / { print ""; print; in_section=0; next }
    in_section && /\[AUTO-DECIDED\]/ { next }
    in_section && /^[[:space:]]*$/ { next }
    { print }
  '
  echo "[gc-events] compacted Open Questions in ${plan_file}" >&2
}

cmd_gc_verdicts() {
  local plan_file="$1"
  require_file "$plan_file"
  if ! grep -q "^## Critic Verdicts$" "$plan_file"; then
    echo "[gc-verdicts] no Critic Verdicts section in ${plan_file}" >&2; return 0
  fi
  _awk_inplace "$plan_file" '
    /^## Critic Verdicts$/ { in_section=1; print; next }
    in_section && /^## / {
      if (n > 0) {
        start = (last_boundary > 0) ? last_boundary : 1
        dropped = start - 1
        for (i = start; i <= n; i++) print lines[i]
        if (dropped > 0)
          print "[gc-verdicts] dropped " dropped " pre-boundary verdict lines" > "/dev/stderr"
      }
      in_section=0; print; next
    }
    in_section {
      lines[++n] = $0
      if (index($0, "[MILESTONE-BOUNDARY @") > 0) last_boundary = n
      next
    }
    { print }
    END {
      if (in_section && n > 0) {
        start = (last_boundary > 0) ? last_boundary : 1
        dropped = start - 1
        for (i = start; i <= n; i++) print lines[i]
        if (dropped > 0)
          print "[gc-verdicts] dropped " dropped " pre-boundary verdict lines" > "/dev/stderr"
      }
    }
  '
}

