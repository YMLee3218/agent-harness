#!/usr/bin/env bash
# Blocked-record helpers — write entries to blocked.jsonl.
# Depends on: sidecar.sh (sc_ensure_dir, sc_path, SC_BLOCKED, sc_append_jsonl,
#   sc_append_jsonl_unlocked, _iso_timestamp).
# _record_blocked_runtime (needs _append_to_open_questions) lives in plan-lib.sh.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_BLOCKED_RECORD_LOADED:-}" ]] && return 0
_BLOCKED_RECORD_LOADED=1

# _record_blocked PLAN KIND AGENT SCOPE MSG [NOLCK]
# Appends to blocked.jsonl. NOLCK=1 skips locking (use only inside a lock body).
# Strips all [BLOCKED*] markers from msg to prevent cmd_unblock false-match injection.
_record_blocked() {
  local _plan="$1" _kind="$2" _agent="$3" _scope="$4" _msg="$5" _nolck="${6:-}"
  local _bpath _ts _safe_msg _rec
  [[ -z "$_nolck" ]] && { sc_ensure_dir "$_plan" || return 1; }
  _bpath=$(sc_path "$_plan" "$SC_BLOCKED") || return 1
  _ts=$(_iso_timestamp)
  _safe_msg=$(printf '%s' "$_msg" | sed 's/\[BLOCKED[A-Z0-9_:-]*\][[:space:]]*//')
  _rec=$(jq -nc --arg ts "$_ts" --arg kind "$_kind" --arg agent "$_agent" \
    --arg scope "$_scope" --arg msg "$_safe_msg" \
    '{ts:$ts,kind:$kind,agent:$agent,scope:$scope,message:$msg,cleared_at:null}')
  [[ -z "$_nolck" ]] && sc_append_jsonl "$_bpath" "$_rec" || sc_append_jsonl_unlocked "$_bpath" "$_rec"
}
