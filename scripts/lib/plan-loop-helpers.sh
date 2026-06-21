#!/usr/bin/env bash
# Verdict loop-state recorder. Convergence/ceiling are recomputed from the events log (events.sh).
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PLAN_LOOP_HELPERS_LOADED:-}" ]] && return 0
_PLAN_LOOP_HELPERS_LOADED=1

_PLAN_LOOP_STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_PLAN_LIB_LOADED:-}" ]] || . "$_PLAN_LOOP_STATE_DIR/plan-lib.sh"
[[ -n "${_EVENTS_LOADED:-}" ]] || . "$_PLAN_LOOP_STATE_DIR/events.sh"

# Convergence and ceiling are recomputed purely from the events log (events.sh):
# ev_is_converged / ev_ceiling_reached are authoritative. All the legacy sidecar machinery this
# file used to host — the reset helpers (_sc_reset_convergence_for_scope, _clear_ceiling_*) and
# the streak/ordinal/ceiling compute (_compute_streak, _get_run_ordinal, _ceiling_block,
# _validated_ceiling, sc_make_conv_state writes) — has been removed: it produced a derived
# convergence cache that no reader consults post-Block-C.
#
# _record_loop_state PLAN PHASE AGENT VERDICT [CATEGORY] [UNIT] [INPUT_HASH]
# Records two append-only facts (no read-modify-write, no sidecar):
#   1. verdicts.jsonl       — feeds _check_consecutive_and_block (PARSE_ERROR hard-block +
#                             same-category-FAIL feedforward). Unit-agnostic; milestone_seq is
#                             fixed at 0 (its only writer, the convergence sidecar, is retired).
#   2. events/{scope}.jsonl — the authoritative convergence/ceiling fact. Written only when the
#                             caller threads a unit + frozen input_hash; every run-critic-loop
#                             caller does (--unit fail-closed / CLAUDE_VERDICT_UNIT). A unit-less
#                             call is the unit-agnostic verdicts.jsonl-only path (consecutive-block).
# rc 0 = recorded; rc 4 = a fact append failed (caller maps it via _dispatch_rls_rc).
_record_loop_state() {
  local plan_file="$1" current_phase="$2" agent="$3" verdict="$4" category="${5:-}"
  local unit="${6:-}" input_hash="${7:-}"
  command -v jq >/dev/null 2>&1 || \
    die "_record_loop_state: jq is required — install jq (brew install jq or apt install jq)"
  local scope; scope=$(_scope_of "$current_phase" "$agent")
  sc_ensure_dir "$plan_file" || die "ERROR: sidecar dir setup failed for $plan_file"
  local verdicts_path; verdicts_path=$(sc_path "$plan_file" "$SC_VERDICTS")
  # 1. verdicts.jsonl fact — sc_append_jsonl is atomic (its own mkdir spinlock), so no
  #    surrounding read-modify-write lock is needed. milestone_seq fixed at 0 (see header).
  local ts; ts=$(_iso_timestamp)
  local _jsonl_rc=0
  sc_append_jsonl "$verdicts_path" "$(jq -nc \
    --arg ts "$ts" --arg phase "$current_phase" --arg agent "$agent" \
    --arg verdict "$verdict" --arg category "$category" \
    '{"ts":$ts,"phase":$phase,"agent":$agent,"verdict":$verdict,"category":$category,"milestone_seq":0}')" || _jsonl_rc=$?
  if [[ $_jsonl_rc -ne 0 ]]; then
    echo "[record-loop-state] ERROR: verdicts.jsonl append failed for ${scope} — verdict not persisted to jsonl" >&2
    return 4
  fi
  # 2. events verdict fact — the sole convergence signal post-Block-C, so a failed append is
  #    fatal (never silently drop it: a lost fact = lost convergence = ceiling loop). Skipped
  #    only for unit-less callers (the verdicts.jsonl-only path above).
  if [[ -n "$unit" && -n "$input_hash" ]]; then
    local _ev_stage; _ev_stage=$(_ev_stage_of_agent "$agent")
    if ! ev_record_verdict "$plan_file" "$unit" "$_ev_stage" "$input_hash" "$verdict" "$category"; then
      echo "[record-loop-state] ERROR: events verdict-fact append failed for ${unit}/${_ev_stage} — convergence is events-authoritative; halting" >&2
      return 4
    fi
  fi
}
