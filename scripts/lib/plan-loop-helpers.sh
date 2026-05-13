#!/usr/bin/env bash
# Sidecar convergence loop-state helpers.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PLAN_LOOP_HELPERS_LOADED:-}" ]] && return 0
_PLAN_LOOP_HELPERS_LOADED=1

_PLAN_LOOP_STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_PLAN_LIB_LOADED:-}" ]] || . "$_PLAN_LOOP_STATE_DIR/plan-lib.sh"

# Reset the sidecar convergence JSON for a phase/agent scope (increment milestone_seq).
# Called by reset-milestone, reset-pr-review, clear-converged.
_sc_reset_convergence_for_scope() {
  local plan_file="$1" phase="$2" agent="$3"
  command -v jq >/dev/null 2>&1 || return 0
  sc_ensure_dir "$plan_file" || return 1
  local conv_path
  conv_path=$(sc_conv_path "$plan_file" "$phase" "$agent")
  local existing_ms=0
  if [[ -f "$conv_path" ]]; then
    existing_ms=$(jq -r '.milestone_seq // 0' "$conv_path" 2>/dev/null || echo 0)
  fi
  local new_ms=$((existing_ms + 1))
  sc_update_json "$conv_path" "$(sc_make_conv_state "$phase" "$agent" false 0 false false 0 "$new_ms")"
}

# _validated_ceiling RAW → prints validated ceiling integer (min 2, default 5)
_validated_ceiling() {
  local c="$1"
  case "$c" in
    ''|*[!0-9]*) c=5 ;;
  esac
  [ "$c" -lt 2 ] && c=5
  echo "$c"
}

# _get_run_ordinal PLAN VERDICTS PHASE AGENT MS → prints next ordinal (lenient: skips corrupt lines)
# PARSE_ERROR verdicts also consume an ordinal slot — repeated parse errors accelerate ceiling.
# Returns 2 on jq failure (propagates to caller's rc=2 [BLOCKED] kind=corrupt branch).
_get_run_ordinal() {
  local plan_file="$1" verdicts_path="$2" current_phase="$3" agent="$4" ms="$5"
  local prior_ordinal=0
  if [[ -f "$verdicts_path" ]]; then
    local _ord_out _jq_rc=0
    # fromjson? | objects skips scalar/array/null lines — prevents jq type-error on corrupt input
    _ord_out=$(jq -rR 'fromjson? | objects | select(.phase == $p and .agent == $a and .milestone_seq == $ms) | 1' \
      --arg p "$current_phase" --arg a "$agent" --argjson ms "$ms" \
      "$verdicts_path") || _jq_rc=$?
    if [[ $_jq_rc -ne 0 ]]; then
      echo "[get-run-ordinal] ERROR: jq failed on ${verdicts_path} (rc=${_jq_rc}) — possible file corruption or permission issue" >&2
      return 2
    fi
    prior_ordinal=$(printf '%s' "${_ord_out:-}" | awk 'END{print NR}')
  fi
  echo $((prior_ordinal + 1))
}

# _ceiling_block_body: runs inside _with_lock; dedup-checks then writes to blocked.jsonl.
_ceiling_block_body() {
  local _ceil_bpath="$1" plan_file="$2" agent="$3" scope="$4" ceiling="$5"
  local _cout=0
  if [[ -f "$_ceil_bpath" ]]; then
    local _co _cr=0
    _co=$(jq -r --arg s "${scope}" \
      'select(.cleared_at==null and .kind=="ceiling" and .scope==$s)|1' \
      "$_ceil_bpath" 2>/dev/null) || _cr=$?
    [[ $_cr -eq 0 ]] && _cout=$(printf '%s' "${_co:-}" | awk 'END{print NR}')
  fi
  [[ "$_cout" -eq 0 ]] && _record_blocked "$plan_file" "ceiling" "$agent" "${scope}" \
    "exceeded ${ceiling} runs" 1
}

# _ceiling_block PLAN PHASE AGENT SCOPE RUN_ORDINAL CEILING CONV_STATE CONV_PATH
# Applies ceiling block when run_ordinal > ceiling. Returns 1 if blocked, 0 if OK.
# dedup-write BEFORE setting ceiling_blocked=true; re-reads conv_state AFTER lock.
_ceiling_block() {
  local plan_file="$1" current_phase="$2" agent="$3" scope="$4"
  local run_ordinal="$5" ceiling="$6" conv_state="$7" convergence_path="$8"
  [ "$run_ordinal" -gt "$ceiling" ] || return 0
  local _ceil_bpath; _ceil_bpath=$(sc_path "$plan_file" "$SC_BLOCKED")
  _with_lock "${_ceil_bpath}.lock" \
    _ceiling_block_body "$_ceil_bpath" "$plan_file" "$agent" "$scope" "$ceiling" || true
  grep -qF "[BLOCKED-CEILING] ${scope}" "$plan_file" 2>/dev/null || \
    _append_to_open_questions "$plan_file" \
      "[BLOCKED-CEILING] ${scope}: exceeded ${ceiling} runs — manual review required"
  conv_state=$(sc_read_json "$convergence_path" \
    '{"first_turn":false,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":0,"milestone_seq":0}')
  sc_update_json "$convergence_path" "$(printf '%s' "$conv_state" | jq '.ceiling_blocked = true')"
  echo "[record-loop-state] BLOCKED-CEILING: ${scope} run #${run_ordinal} exceeds ceiling ${ceiling}" >&2
  return 1
}

# _compute_streak PLAN VERDICTS VERDICT PHASE AGENT MS → prints streak count; returns 3 on compute failure
_compute_streak() {
  local plan_file="$1" verdicts_path="$2" verdict="$3" current_phase="$4" agent="$5" ms="$6"
  if [[ "$verdict" != "PASS" ]]; then echo 0; return 0; fi
  local _sout="" _src=0
  if [[ -f "$verdicts_path" ]]; then
    _sout=$(_jq_compute_or_fail "$plan_file" "$verdicts_path" "streak" \
      'select(.phase==$p and .agent==$a and .milestone_seq==$ms)|.verdict' \
      --arg p "$current_phase" --arg a "$agent" --argjson ms "$ms") || _src=$?
  fi
  if [[ $_src -ne 0 ]]; then
    local scope; scope=$(_scope_of "$current_phase" "$agent")
    echo "[record-loop-state] streak compute failed for ${scope} — verdict withheld" >&2
    _record_blocked_runtime "$plan_file" "harness" "verdicts" \
      "corrupt verdicts.jsonl — streak computation failed; manual inspection required"
    return 3
  fi
  local _prior
  _prior=$(printf '%s' "${_sout:-}" | \
    awk '{l[NR]=$0}END{c=0;for(i=NR;i>=1;i--){if(l[i]=="PASS")c++;else break};print c}' || echo 0)
  echo $((_prior + 1))
}

# inner body runs inside _with_lock to prevent concurrent read-modify-write race.
_record_loop_state_body() {
  local plan_file="$1" current_phase="$2" agent="$3" verdict="$4" category="$5"
  local scope="$6" ceiling="$7" verdicts_path="$8" convergence_path="$9"
  local conv_state; conv_state=$(sc_read_json "$convergence_path" \
    '{"first_turn":false,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":0,"milestone_seq":0}')
  # if already ceiling-blocked, return immediately.
  local prior_cb; prior_cb=$(printf '%s' "$conv_state" | jq -r '.ceiling_blocked // false')
  if [[ "$prior_cb" == "true" ]]; then
    echo "[record-loop-state] BLOCKED-CEILING: ${scope} already ceiling-blocked — run reset-milestone or unblock to resume" >&2
    return 1
  fi
  local ms; ms=$(printf '%s' "$conv_state" | jq -r '.milestone_seq // 0')
  local run_ordinal; run_ordinal=$(_get_run_ordinal "$plan_file" "$verdicts_path" \
    "$current_phase" "$agent" "$ms") || return 2
  # Compute streak BEFORE ceiling_block: rc=3 failure returns with no sidecar mutation.
  local streak; streak=$(_compute_streak "$plan_file" "$verdicts_path" "$verdict" \
    "$current_phase" "$agent" "$ms") || return 3
  _ceiling_block "$plan_file" "$current_phase" "$agent" "$scope" \
    "$run_ordinal" "$ceiling" "$conv_state" "$convergence_path" || return 1
  # Re-read conv_state after _ceiling_block (which may have updated ceiling_blocked — L3)
  conv_state=$(sc_read_json "$convergence_path" \
    '{"first_turn":false,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":0,"milestone_seq":0}')
  # refresh prior_cb from the freshly-read conv_state to preserve any concurrent ceiling flip
  prior_cb=$(printf '%s' "$conv_state" | jq -r '.ceiling_blocked // false')
  local was_first_turn; was_first_turn=$(printf '%s' "$conv_state" | jq -r '.first_turn')
  local new_first_turn; [[ "$verdict" != "PARSE_ERROR" ]] && new_first_turn="true" || new_first_turn="$was_first_turn"
  local was_converged; was_converged=$(printf '%s' "$conv_state" | jq -r '.converged')
  local new_converged; new_converged="$was_converged"
  [[ "$streak" -ge 2 ]] && [[ "$was_converged" != "true" ]] && new_converged="true"
  # append to verdicts.jsonl FIRST — only update convergence if the append succeeds.
  local ts; ts=$(_iso_timestamp)
  local _jsonl_rc=0
  sc_append_jsonl "$verdicts_path" "$(jq -nc \
    --arg ts "$ts" --arg phase "$current_phase" --arg agent "$agent" \
    --arg verdict "$verdict" --arg category "$category" \
    --argjson ord "$run_ordinal" --argjson ms "$ms" \
    '{"ts":$ts,"phase":$phase,"agent":$agent,"verdict":$verdict,"category":$category,"ordinal":$ord,"milestone_seq":$ms}')" || _jsonl_rc=$?
  if [[ $_jsonl_rc -ne 0 ]]; then
    echo "[record-loop-state] ERROR: verdicts.jsonl append failed for ${scope} — verdict not persisted to jsonl" >&2
    return 4
  fi
  sc_update_json "$convergence_path" \
    "$(sc_make_conv_state "$current_phase" "$agent" \
      "$([ "$new_first_turn" = "true" ] && echo true || echo false)" \
      "$streak" \
      "$([ "$new_converged" = "true" ] && echo true || echo false)" \
      "$([ "$prior_cb" = "true" ] && echo true || echo false)" \
      "$run_ordinal" "$ms" \
    | jq --arg cat "$category" '. + {last_verdict_category: $cat}')"
  if [[ "$verdict" != "PARSE_ERROR" ]] && [[ "$was_first_turn" != "true" ]]; then
    _append_to_open_questions "$plan_file" "[FIRST-TURN] ${scope}"
    echo "[record-loop-state] FIRST-TURN: ${scope} first real verdict" >&2
  fi
  if [[ "$new_converged" == "true" ]] && [[ "$was_converged" != "true" ]]; then
    echo "[record-loop-state] CONVERGED: ${scope} with ${streak} consecutive PASSes" >&2
  fi
}
_record_loop_state() {
  local plan_file="$1" current_phase="$2" agent="$3" verdict="$4" category="${5:-}"
  command -v jq >/dev/null 2>&1 || \
    die "_record_loop_state: jq is required — install jq (brew install jq or apt install jq)"
  local scope; scope=$(_scope_of "$current_phase" "$agent")
  local ceiling; ceiling=$(_validated_ceiling "${CLAUDE_CRITIC_LOOP_CEILING:-5}")
  sc_ensure_dir "$plan_file" || die "ERROR: sidecar dir setup failed for $plan_file"
  local verdicts_path; verdicts_path=$(sc_path "$plan_file" "$SC_VERDICTS")
  local convergence_path; convergence_path=$(sc_conv_path "$plan_file" "$current_phase" "$agent")
  # wrap entire read-modify-write in a lock to prevent lost-update race.
  # Use .rls.lock suffix to avoid deadlock with sc_update_json's .lock suffix.
  _with_lock "${convergence_path}.rls.lock" _record_loop_state_body \
    "$plan_file" "$current_phase" "$agent" "$verdict" "$category" \
    "$scope" "$ceiling" "$verdicts_path" "$convergence_path"
}
