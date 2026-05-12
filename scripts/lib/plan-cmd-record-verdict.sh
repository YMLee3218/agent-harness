#!/usr/bin/env bash
# Plan record-verdict commands: record-verdict, record-verdict-guarded, append-review-verdict.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PLAN_CMD_RECORD_VERDICT_LOADED:-}" ]] && return 0
_PLAN_CMD_RECORD_VERDICT_LOADED=1

_PLAN_CMD_RV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_PLAN_CMD_VERDICTS_LOADED:-}" ]] || . "$_PLAN_CMD_RV_DIR/plan-cmd-verdicts.sh"
[[ -n "${_PLAN_CMD_NOTES_LOADED:-}" ]] || . "$_PLAN_CMD_RV_DIR/plan-cmd-notes.sh"

# _parse_verdict_message OUTPUT → prints "<verdict>|<category>" extracted from HTML comment markers.
# verdict  ← <!-- verdict: PASS --> or <!-- verdict: FAIL -->
# category ← <!-- category: SOME_CAT -->
# Either field may be empty; output is always "<verdict>|<category>".
_parse_verdict_message() {
  local _msg="$1" _v _c
  _v=$(printf '%s' "$_msg" | grep -oE '<!--[[:space:]]*verdict:[[:space:]]*[A-Z]+[[:space:]]*-->' | tail -1 \
       | sed -E 's/<!--[[:space:]]*verdict:[[:space:]]*//; s/[[:space:]]*-->//' || true)
  _c=$(printf '%s' "$_msg" | grep -oE '<!--[[:space:]]*category:[[:space:]]*[A-Z_]+[[:space:]]*-->' | tail -1 \
       | sed -E 's/<!--[[:space:]]*category:[[:space:]]*//; s/[[:space:]]*-->//' || true)
  printf '%s|%s\n' "${_v:-}" "${_c:-}"
}

# _handle_parse_error PLAN PHASE AGENT LOG_MSG BLOCK_MSG RETRY_MSG
# Records PARSE_ERROR loop state, checks consecutive errors, appends verdict.
_handle_parse_error() {
  local plan_file="$1" current_phase="$2" agent="$3" log_msg="$4" block_msg="$5" retry_msg="$6"
  echo "[record-verdict] ${log_msg}" >&2
  local _hpe_rc=0
  _record_loop_state "$plan_file" "$current_phase" "$agent" "PARSE_ERROR" || _hpe_rc=$?
  [[ $_hpe_rc -ne 0 ]] && _dispatch_rls_rc "$plan_file" "${current_phase}/${agent}: PARSE_ERROR" "$_hpe_rc"
  # When _check_consecutive_and_block fires (rc=0/BLOCKED), skip the final cmd_append_verdict
  # to avoid plan.md↔jsonl asymmetry (the block marker was already written by the function).
  # rc=2 (corrupt) uses [NOT-PERSISTED:CORRUPT-CHECK] prefix.
  local _ccb_parse_rc=0
  _check_consecutive_and_block "$plan_file" "$current_phase" "$agent" \
      '[.[] | select(.phase == $p and .agent == $a and .milestone_seq == $ms)] | .[-2].verdict // ""' \
      "PARSE_ERROR" "parse" "$block_msg" \
      "BLOCKED parse: ${agent} two consecutive PARSE_ERRORs" || _ccb_parse_rc=$?
  case $_ccb_parse_rc in
    0) : ;;  # blocked — block marker already written to plan.md
    1) echo "[record-verdict] ${retry_msg}" >&2
       cmd_append_verdict "$plan_file" "${current_phase}/${agent}: PARSE_ERROR" ;;
    2) cmd_append_verdict "$plan_file" "${MARK_NOT_PERSISTED_CORRUPT_CHECK} ${current_phase}/${agent}: PARSE_ERROR" ;;
    *) echo "[record-verdict] _check_consecutive_and_block rc=${_ccb_parse_rc} unknown" >&2; exit 1 ;;
  esac
  exit 1
}

# _resolve_output INPUT AGENT_TRANSCRIPT TRANSCRIPT → prints transcript text to use for verdict extraction
# reads at most 1MB tail of transcript to prevent memory exhaustion on large files.
_resolve_output() {
  local input="$1" agent_transcript="$2" transcript="$3"
  local out="" _safe_path _transcript_size _size_warn=1048576
  if [ -n "$agent_transcript" ]; then
    _safe_path=$(_is_safe_transcript_path "$agent_transcript") && [ -f "$_safe_path" ] && {
      _transcript_size=$(wc -c < "$_safe_path" 2>/dev/null || echo 0)
      [ "$_transcript_size" -gt "$_size_warn" ] && \
        echo "[record-verdict] WARN: agent_transcript size ${_transcript_size} bytes — reading last 1MB only" >&2
      out=$(tail -c 1048576 "$_safe_path" | \
        jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="text")|.text//empty' \
        2>/dev/null || true)
    }
  fi
  if [ -z "$out" ] && [ -n "$transcript" ]; then
    _safe_path=$(_is_safe_transcript_path "$transcript") && [ -f "$_safe_path" ] && {
      _transcript_size=$(wc -c < "$_safe_path" 2>/dev/null || echo 0)
      [ "$_transcript_size" -gt "$_size_warn" ] && \
        echo "[record-verdict] WARN: transcript size ${_transcript_size} bytes — reading last 1MB only" >&2
      out=$(tail -c 1048576 "$_safe_path" | \
        jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="text")|.text//empty' \
        2>/dev/null | tail -200 || true)
    }
  fi
  [ -z "$out" ] && out=$(printf '%s' "$input" | jq -r '.last_assistant_message // ""' 2>/dev/null || echo "")
  printf '%s' "$out"
}

# _resolve_plan_for_verdict AGENT → sets plan_file, current_phase; exits 0 on skip, returns 0 on success.
_resolve_plan_for_verdict() {
  local _agent="$1" _find_rc=0
  plan_file=$(cmd_find_active) || _find_rc=$?
  if [ "$_find_rc" -ne 0 ]; then
    case "$_find_rc" in
      2) echo "[record-verdict] no active plan file — verdict for ${_agent} dropped" >&2 ;;
      3) echo "[record-verdict] ambiguous: multiple active plan files — pin CLAUDE_PLAN_FILE for ${_agent}" >&2 ;;
      4) echo "[record-verdict] unreadable plan phase — verdict for ${_agent} dropped" >&2 ;;
      *) echo "[record-verdict] cmd_find_active failed (exit ${_find_rc}) — verdict for ${_agent} dropped" >&2 ;;
    esac
    exit 0
  fi
  current_phase=$(_require_phase "$plan_file" "record-verdict") || exit $?
}

# _extract_or_handle_missing_verdict OUTPUT INPUT PLAN PHASE AGENT → sets verdict, category; exits on error.
_extract_or_handle_missing_verdict() {
  local _output="$1" _input="$2" _plan="$3" _phase="$4" _agent="$5" _pvm_out
  _pvm_out=$(_parse_verdict_message "$_output")
  IFS='|' read -r verdict category <<< "$_pvm_out"
  if [ -z "$verdict" ]; then
    printf '%s' "$_output" | grep -qE 'Verdict:\s*(PASS|FAIL)|\*\*Verdict:\s*(PASS|FAIL)\*\*' && {
      echo "[record-verdict] textual-verdict-only transcript for ${_agent} — skipping" >&2; exit 0; }
    printf '%s' "$_output" | grep -qE '### Verdict|<!-- verdict:' || {
      echo "[record-verdict] no verdict section in transcript for ${_agent} — skipping" >&2; exit 0; }
    local _keys; _keys=$(printf '%s' "$_input" | jq -r 'keys | join(", ")' 2>/dev/null || echo "unknown")
    _handle_parse_error "$_plan" "$_phase" "$_agent" \
      "missing verdict marker from ${_agent} (payload keys: ${_keys})" \
      "verdict marker missing (two consecutive parse errors) — check agent output format before retrying" \
      "first PARSE_ERROR for ${_agent} — will retry automatically"
  fi
  [ "$verdict" = "FAIL" ] && [ -z "$category" ] && \
    _handle_parse_error "$_plan" "$_phase" "$_agent" \
      "FAIL without category from ${_agent} — treating as PARSE_ERROR" \
      "FAIL without category (two consecutive parse errors) — check agent output format" \
      "first FAIL-without-category for ${_agent} — will retry automatically"
  return 0
}

# _resolve_verdict_payload INPUT → sets plan_file, agent_name, current_phase, verdict, category
# Exits 0 (silent skip), 1 (parse error handled), or returns normally with vars populated.
_resolve_verdict_payload() {
  local _input="$1"
  agent_name=$(printf '%s' "$_input" | jq -r '.agent_type // "unknown"' 2>/dev/null) || {
    echo "[record-verdict] WARN: jq parse failed on input — agent_type unknown, verdict may be dropped" >&2
    agent_name="unknown"
    local _plan_file_fallback _rc_fallback=0
    _plan_file_fallback=$(cmd_find_active 2>/dev/null) || _rc_fallback=$?
    [ "$_rc_fallback" -eq 0 ] && [ -n "$_plan_file_fallback" ] && \
      _record_blocked_runtime "$_plan_file_fallback" "harness" "transcript-parse-failure" \
        "jq failed to extract agent_type" 2>/dev/null || true
  }
  _is_subagent_critic "$agent_name" || exit 0
  local _agent_transcript _transcript
  _agent_transcript=$(printf '%s' "$_input" | jq -r '.agent_transcript_path // empty' 2>/dev/null || true)
  _transcript=$(printf '%s' "$_input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
  _resolve_plan_for_verdict "$agent_name"
  local _output
  _output=$(_resolve_output "$_input" "$_agent_transcript" "$_transcript")
  _extract_or_handle_missing_verdict "$_output" "$_input" "$plan_file" "$current_phase" "$agent_name"
}

# _persist_verdict PLAN PHASE AGENT VERDICT CATEGORY → writes loop state + appends to plan.md
_persist_verdict() {
  local _plan="$1" _phase="$2" _agent="$3" _verdict="$4" _category="$5"
  local _label="${_phase}/${_agent}: ${_verdict}"
  [ -n "$_category" ] && _label="${_label} [category: ${_category}]"
  local _rls_rc=0
  _record_loop_state "$_plan" "$_phase" "$_agent" "$_verdict" "$_category" || _rls_rc=$?
  [[ $_rls_rc -ne 0 ]] && _dispatch_rls_rc "$_plan" "$_label" "$_rls_rc"
  if [ "$_verdict" = "FAIL" ] && [ -n "$_category" ]; then
    local _ccb_rc=0
    _check_consecutive_and_block "$_plan" "$_phase" "$_agent" \
      '[.[] | select(.phase == $p and .agent == $a and .milestone_seq == $ms and .verdict == "FAIL")] | .[-2].category // ""' \
      "$_category" "category" "${_category} failed twice — fix root cause before retrying" \
      "consecutive same-category FAIL (${_category}) from ${_agent} — blocked" || _ccb_rc=$?
    case $_ccb_rc in
      0) cmd_append_verdict "$_plan" "$_label"; exit 1 ;;
      1) : ;;
      2) cmd_append_verdict "$_plan" "${MARK_NOT_PERSISTED_CORRUPT_CHECK} ${_label}"; exit 1 ;;
      *) echo "[record-verdict] _check_consecutive_and_block rc=${_ccb_rc} unknown" >&2; exit 1 ;;
    esac
  fi
  cmd_append_verdict "$_plan" "$_label"
  echo "[record-verdict] verdict appended: ${_label}" >&2
  [ "$_verdict" = "FAIL" ] && exit 1 || exit 0
}

cmd_record_verdict() {
  require_jq
  local input; input=$(cat)
  local plan_file agent_name current_phase verdict category
  _resolve_verdict_payload "$input"
  _persist_verdict "$plan_file" "$current_phase" "$agent_name" "$verdict" "$category"
}

cmd_record_verdict_guarded() {
  local _input _agent _plan _find_rc _lock
  _input=$(cat)
  _agent="unknown"
  if command -v jq >/dev/null 2>&1; then
    _agent=$(printf '%s' "$_input" | jq -r 'if (.agent_type // "") == "" then "unknown" else .agent_type end' 2>/dev/null || echo "unknown")
  fi
  if ! _is_subagent_critic "$_agent"; then
    exit 0
  fi
  _find_rc=0
  _plan=$(cmd_find_active) || _find_rc=$?
  _lock=""
  [ "$_find_rc" -eq 0 ] && _lock="${_plan}.critic.lock"
  if [ -z "$_lock" ] || [ ! -f "$_lock" ]; then
    if [ "$_find_rc" -eq 0 ]; then
      sc_ensure_dir "$_plan" || { echo "ERROR: [record-verdict-guarded] sc_ensure_dir failed: $_plan" >&2; exit 2; }
      _record_blocked_runtime "$_plan" "$_agent" "protocol-violation" \
        "invoked outside run-critic-loop.sh context"
    fi
    echo "[record-verdict-guarded] BLOCKED: ${_agent} ran outside run-critic-loop.sh" >&2
    exit 2
  fi
  printf '%s' "$_input" | cmd_record_verdict
}

