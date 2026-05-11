#!/usr/bin/env bash
# Plan verdict commands: verdict streak/ceiling guard + audit append.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PLAN_CMD_VERDICTS_LOADED:-}" ]] && return 0
_PLAN_CMD_VERDICTS_LOADED=1

_PLAN_CMD_VERDICTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_PLAN_LOOP_STATE_LOADED:-}" ]] || . "$_PLAN_CMD_VERDICTS_DIR/plan-loop-state.sh"
[[ -n "${_PLAN_CMD_STATE_LOADED:-}" ]] || . "$_PLAN_CMD_VERDICTS_DIR/plan-cmd-state.sh"

# _dispatch_rls_rc PLAN LABEL RC — dispatches _record_loop_state failure codes; always exits 1.
_dispatch_rls_rc() {
  local _plan="$1" _label="$2" _rc="$3"
  case $_rc in
    1) echo "[record-verdict] BLOCKED-CEILING: ${_label}" >&2
       cmd_append_verdict "$_plan" "${MARK_BLOCKED_CEILING} ${_label}" ;;
    2) echo "[record-verdict] BLOCKED-CORRUPT: ordinal compute failed — ${_label} not persisted" >&2
       cmd_append_verdict "$_plan" "${MARK_NOT_PERSISTED_CORRUPT} ${_label}" ;;
    3) echo "[record-verdict] BLOCKED-STREAK: streak compute failed — ${_label} not persisted" >&2
       cmd_append_verdict "$_plan" "${MARK_NOT_PERSISTED_STREAK} ${_label}" ;;
    4) echo "[record-verdict] BLOCKED-WRITE: verdicts.jsonl append failed — plan.md NOT updated" >&2 ;;
    *) echo "[record-verdict] _record_loop_state rc=${_rc} — ${_label} not persisted" >&2
       cmd_append_verdict "$_plan" "$_label" ;;
  esac
  exit 1
}

# _check_consecutive_and_block PLAN PHASE AGENT JQ_PREV_QUERY MATCH_VAL KIND MSG LOG_LABEL
# Queries the previous verdict/category value from verdicts.jsonl using JQ_PREV_QUERY.
# If it equals MATCH_VAL, writes [BLOCKED] kind:agent: msg to plan.md and blocked.jsonl, returns 0.
# Returns 1 if no consecutive match (no block written). Returns 2 on corrupt verdicts.jsonl.
_check_consecutive_and_block() {
  local plan_file="$1" phase="$2" agent="$3"
  local jq_prev_query="$4" match_val="$5" kind="$6" msg="$7" log_label="$8"
  local _ms _prev_val _vpath _scope
  _scope=$(_scope_of "$phase" "$agent")
  _ms=$(jq -r '.milestone_seq // 0' "$(sc_conv_path "$plan_file" "$phase" "$agent")" 2>/dev/null || echo 0)
  _vpath=$(sc_path "$plan_file" "$SC_VERDICTS")
  _prev_val=""
  if [[ -f "$_vpath" ]]; then
    local _jq_rc=0
    _prev_val=$(jq -rs --arg p "$phase" --arg a "$agent" --argjson ms "$_ms" \
      "$jq_prev_query" "$_vpath" 2>/dev/null) || _jq_rc=$?
    if [[ $_jq_rc -ne 0 ]]; then
      _record_blocked_runtime "$plan_file" "$agent" "$_scope" \
        "corrupt verdicts.jsonl — jq failed in consecutive check; run gc-sidecars or fix manually"
      return 2
    fi
  fi
  if [[ -n "$_prev_val" ]] && [[ "$_prev_val" == "$match_val" ]]; then
    _append_to_open_questions "$plan_file" "[BLOCKED] ${kind}:${agent}: ${msg}"
    _record_blocked "$plan_file" "$kind" "$agent" "$_scope" "$msg" 2>/dev/null || true
    echo "[record-verdict] ${log_label}" >&2
    return 0
  fi
  return 1
}

cmd_append_verdict() {
  local plan_file="$1" label="$2"
  require_file "$plan_file"
  if grep -q "^## Critic Verdicts$" "$plan_file"; then
    _awk_inplace "$plan_file" -v label="- $label" '
      /^## Critic Verdicts$/ { print; in_section=1; next }
      in_section && /^## / { print label; print ""; print; in_section=0; next }
      { print }
      END { if (in_section) print label }
    '
  else
    echo "" >> "$plan_file"
    echo "## Critic Verdicts" >> "$plan_file"
    echo "- $label" >> "$plan_file"
  fi
}

cmd_append_audit() {
  local plan_file="$1" agent="$2" outcome="$3" summary="$4"
  require_file "$plan_file"
  case "$outcome" in
    ACCEPT|ACCEPT-OVERRIDE|REJECT-PASS) ;;
    *) die "append-audit: invalid outcome '${outcome}'. Must be ACCEPT, ACCEPT-OVERRIDE, or REJECT-PASS" ;;
  esac
  local ts
  ts=$(_iso_timestamp)
  _append_to_verdict_audits "$plan_file" "- ${ts} ${agent} ${outcome}: ${summary}"
}

cmd_append_review_verdict() {
  local plan_file="$1" agent="$2" verdict="$3"
  require_file "$plan_file"
  [ "$agent" = "pr-review" ] || die "append-review-verdict: agent must be 'pr-review', got: ${agent}"
  case "$verdict" in
    PASS|FAIL) ;;
    *) die "append-review-verdict: verdict must be PASS or FAIL, got: ${verdict}" ;;
  esac
  local current_phase
  current_phase=$(_require_phase "$plan_file" "append-review-verdict") || exit $?
  local verdict_label="${current_phase}/${agent}: ${verdict}"
  local _arv_rc=0
  _record_loop_state "$plan_file" "$current_phase" "$agent" "$verdict" || _arv_rc=$?
  [[ $_arv_rc -ne 0 ]] && _dispatch_rls_rc "$plan_file" "$verdict_label" "$_arv_rc"
  cmd_append_verdict "$plan_file" "$verdict_label"
  echo "[append-review-verdict] verdict appended: ${verdict_label}" >&2
}

