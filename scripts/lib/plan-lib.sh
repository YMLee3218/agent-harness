#!/usr/bin/env bash
# Plan-file library — core helpers. All cmd_* functions live in plan-cmd.sh.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PLAN_LIB_LOADED:-}" ]] && return 0
_PLAN_LIB_LOADED=1

_PLAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_ACTIVE_PLAN_LOADED:-}" ]] || . "$_PLAN_LIB_DIR/active-plan.sh"
[[ -n "${_PHASE_POLICY_LOADED:-}" ]] || . "${_PLAN_LIB_DIR}/../phase-policy.sh"
[[ -n "${_SIDECAR_LOADED:-}" ]] || . "$_PLAN_LIB_DIR/sidecar.sh"
VALID_PHASES="$(list_phases)"

# ── Blocked-record helpers (inlined from blocked-record.sh) ───────────────────
if [[ -z "${_BLOCKED_RECORD_LOADED:-}" ]]; then
_BLOCKED_RECORD_LOADED=1

# _record_blocked PLAN KIND AGENT SCOPE MSG [NOLCK] [UNIT] [STAGE]
# The single block writer. Block-channel cutover (step 5): the events log is the SOLE read
# authority for the 6 real block kinds (envelope|docs|spec|code|env|harness), so the events block
# fact is now the FATAL durable record that gates plan.md marking — written to the (UNIT,STAGE)
# scope when a unit is threaded (so stage_is_satisfied sees it per-unit), else the reserved
# __harness__ scope (plan-level harness/env/runtime blocks) so ev_any_blocked still catches it.
# No redundant blocked.jsonl write for these kinds — it was a synced belt nobody reads.
# ceiling (a count predicate, invariant 10) and transient (sidecar circuit breaker, written by
# _record_transient) are NOT events blocks; they keep the legacy blocked.jsonl belt unchanged.
_record_blocked() {
  local _plan="$1" _kind="$2" _agent="$3" _scope="$4" _msg="$5" _nolck="${6:-}" _unit="${7:-}" _stage="${8:-}"
  local _safe_msg
  [[ -z "$_nolck" ]] && { sc_ensure_dir "$_plan" || return 1; }
  _safe_msg=$(printf '%s' "$_msg" | sed 's/^\[BLOCKED:[a-z]*\][[:space:]]*//')
  if [[ "$_kind" != "ceiling" && "$_kind" != "transient" ]]; then
    # Events is the durable authority — propagate its failure so the caller leaves plan.md unmarked.
    if [[ -n "$_unit" && -n "$_stage" ]]; then
      ev_record_block "$_plan" "$_unit" "$_stage" "$_kind" "$_safe_msg"
    else
      ev_record_block "$_plan" "__harness__" "harness" "$_kind" "$_safe_msg"
    fi
    return $?
  fi
  # Legacy blocked.jsonl belt for ceiling/transient (no events fact).
  local _bpath _ts _rec
  _bpath=$(sc_path "$_plan" "$SC_BLOCKED") || return 1
  _ts=$(_iso_timestamp)
  _rec=$(jq -nc --arg ts "$_ts" --arg kind "$_kind" --arg agent "$_agent" \
    --arg scope "$_scope" --arg msg "$_safe_msg" \
    '{ts:$ts,kind:$kind,agent:$agent,scope:$scope,message:$msg,cleared_at:null}')
  if [[ -z "$_nolck" ]]; then sc_append_jsonl "$_bpath" "$_rec"; else sc_append_jsonl_unlocked "$_bpath" "$_rec"; fi
}
fi

VALID_CRITIC_AGENTS="critic-feature critic-spec critic-test critic-code critic-cross critic-quality"

# ── Core helpers ──────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

_validate_critic_agent() {
  local agent="$1" cmd="$2"
  case " $VALID_CRITIC_AGENTS " in
    *" $agent "*) ;;
    *) die "${cmd}: unknown agent '${agent}'. Valid values: ${VALID_CRITIC_AGENTS}" ;;
  esac
}

_is_subagent_critic() {
  case " ${VALID_CRITIC_AGENTS} " in
    *" ${1:-} "*) return 0 ;;
    *) return 1 ;;
  esac
}

_awk_inplace_body() {
  local _file="$1" _tmp="$2"; shift 2
  if awk "$@" "$_file" > "$_tmp"; then
    mv "$_tmp" "$_file"
  else
    rm -f "$_tmp"
    return 1
  fi
}

_awk_inplace() {
  local _file="$1"; shift
  local _tmp; _tmp=$(_sc_mktemp "$_file") || return 1
  if ! _with_lock "$_file" _awk_inplace_body "$_file" "$_tmp" "$@"; then
    rm -f "$_tmp"
    return 1
  fi
}

# ── Schema validation ─────────────────────────────────────────────────────────

_check_schema() {
  local plan_file="$1"
  local schema_ver
  schema_ver=$(awk '/^---$/{in_fm=!in_fm; next} in_fm && /^schema:/{print $2; exit}' "$plan_file" 2>/dev/null \
              | tr -d '[:space:]' || echo "")
  [ "${schema_ver}" = "2" ] || die "unsupported plan file schema version: '${schema_ver:-missing}' (required: 2)"
}

require_jq() {
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not found" >&2; exit 2; }
}

require_file() {
  [ -f "$1" ] || { echo "ERROR: plan file not found: $1" >&2; exit 2; }
}

# ── Section-append helpers ────────────────────────────────────────────────────

_append_to_section() {
  local plan_file="$1" section="$2" entry="$3"
  [ "${4:-}" = "--bullet" ] && entry="- $entry"
  _awk_inplace "$plan_file" -v section="$section" -v entry="$entry" '
    $0 == "## " section { print; in_section=1; found=1; next }
    in_section && /^## / { print entry; print ""; print; in_section=0; next }
    { print }
    END {
      if (in_section) print entry
      else if (!found) { print ""; print "## " section; print entry }
    }
  '
}

_append_to_open_questions()    { _append_to_section "$1" "Open Questions"   "$2"; }
_append_to_phase_transitions() { _append_to_section "$1" "Phase Transitions" "$2"; }
_append_to_critic_verdicts()   { _append_to_section "$1" "Critic Verdicts"  "$2" --bullet; }
_append_to_verdict_audits()    { _append_to_section "$1" "Verdict Audits"   "$2"; }

_awk_replace_phase_body() {
  local plan_file="$1" phase="$2"
  _awk_inplace "$plan_file" -v phase="$phase" '
    BEGIN { in_fm=0; fm_done=0; in_phase_section=0 }
    /^---$/ && !fm_done { in_fm = !in_fm; if (!in_fm) fm_done=1; print; next }
    in_fm && /^phase:/ { print "phase: " phase; next }
    /^## Phase$/ { print; print ""; in_phase_section=1; next }
    in_phase_section && /^[[:space:]]*$/ { next }
    in_phase_section && /^[A-Za-z]/ { print phase; in_phase_section=0; next }
    in_phase_section && !/^[A-Za-z]/ { print phase; print; in_phase_section=0; next }
    { print }
    END { if (in_phase_section) { print phase } }
  '
}

# ── Blocked-record helpers ───────────────────────────────────────────────────

# _record_blocked_runtime PLAN_FILE AGENT SCOPE MESSAGE
# Appends a kind=harness events block fact (to __harness__, the FATAL durable record) AND the
# open-questions marker simultaneously.
_record_blocked_runtime() {
  local _plan="$1" _agent="$2" _scope="$3" _msg="$4"
  local _rc=0
  _record_blocked "$_plan" "harness" "$_agent" "$_scope" "$_msg" || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    echo "[record-blocked-runtime] FATAL: block fact write failed — plan.md NOT marked" >&2
    return "$_rc"
  fi
  _append_to_open_questions "$_plan" "[BLOCKED:harness] ${_agent}: runtime — ${_msg}"
}

