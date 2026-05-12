#!/usr/bin/env bash
# Sidecar JSONL append and rewrite helpers.
# Depends on: sc-lock.sh (_with_lock, _sc_mktemp from sidecar.sh).
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_SC_JSONL_LOADED:-}" ]] && return 0
_SC_JSONL_LOADED=1

# sc_append_jsonl PATH RECORD_JSON — append one JSON line (_with_lock-protected)
_sc_append_line() { printf '%s\n' "$1" >> "$2"; }
sc_append_jsonl() {
  _with_lock "${1}.lock" _sc_append_line "$2" "$1" || {
    echo "[sidecar] sc_append_jsonl failed for ${1}" >&2; return 1
  }
}

# sc_append_jsonl_unlocked PATH RECORD_JSON — append without locking (caller holds lock)
sc_append_jsonl_unlocked() {
  printf '%s\n' "$2" >> "$1"
}

# _sc_rewrite_jsonl JSONL_PATH JQ_FILTER LOG_TAG [JQ_ARGS...] — rewrite JSONL atomically via _with_lock+tmp+mv.
_sc_rewrite_jsonl_locked() {
  local _bpath="$1" _tmp="$2" _jq_filter="$3"; shift 3
  jq -c "$@" "$_jq_filter" "$_bpath" > "$_tmp" && mv "$_tmp" "$_bpath" || { rm -f "$_tmp"; return 1; }
}
_sc_rewrite_jsonl() {
  local _bpath="$1" _jq_filter="$2" _log_tag="$3"; shift 3
  [[ -f "$_bpath" ]] || return 0
  local _tmp _rc=0
  _tmp=$(_sc_mktemp "$_bpath") || return 1
  _with_lock "${_bpath}.lock" _sc_rewrite_jsonl_locked "$_bpath" "$_tmp" "$_jq_filter" "$@" || _rc=$?
  if [[ $_rc -ne 0 ]]; then
    rm -f "$_tmp" 2>/dev/null || true
    echo "[${_log_tag}] ERROR: failed to rewrite ${_bpath} — aborting to prevent state divergence" >&2
    return 1
  fi
}

# _sc_rotate_jsonl SRC ARCHIVE KEEP_FILTER ARCHIVE_FILTER LOG_TAG [JQ_ARGS...]
# Archive is written atomically: both keep and archive jq outputs succeed BEFORE either file is modified.
_sc_rotate_jsonl_body() {
  local _src="$1" _archive="$2" _keep_filter="$3" _archive_filter="$4" _tmp="$5" _atmp="$6"; shift 6
  if ! jq -c "$@" "$_keep_filter" "$_src" 2>/dev/null > "$_tmp"; then
    rm -f "$_tmp" "$_atmp"; return 1
  fi
  if ! jq -c "$@" "$_archive_filter" "$_src" 2>/dev/null > "$_atmp"; then
    rm -f "$_tmp" "$_atmp"; return 1
  fi
  # Commit order: replace source FIRST, then append to archive atomically (cp+cat+mv).
  # If interrupted after mv, source is clean — duplicates on next rotation are impossible.
  # Archive append uses cp+cat+mv so a SIGINT mid-write doesn't corrupt the existing archive.
  if ! mv "$_tmp" "$_src"; then
    rm -f "$_tmp" "$_atmp"; return 1
  fi
  if [[ -f "$_archive" ]]; then
    local _archmp
    _archmp=$(_sc_mktemp "$_archive") || { rm -f "$_atmp"; return 1; }
    if ! cp "$_archive" "$_archmp" || ! cat "$_atmp" >> "$_archmp"; then
      rm -f "$_atmp" "$_archmp"; return 1
    fi
    mv "$_archmp" "$_archive" || { rm -f "$_atmp" "$_archmp"; return 1; }
  else
    mv "$_atmp" "$_archive" || { rm -f "$_atmp"; return 1; }
    _atmp=""
  fi
  [[ -n "${_atmp:-}" ]] && rm -f "$_atmp"
  return 0
}
_sc_rotate_jsonl() {
  local _src="$1" _archive="$2" _keep_filter="$3" _archive_filter="$4" _log_tag="$5"
  shift 5
  local _tmp _atmp _rc=0
  _tmp=$(_sc_mktemp "$_src") || return 1
  _atmp=$(_sc_mktemp "${_src}.arch") || { rm -f "$_tmp"; return 1; }
  _with_lock "${_src}.lock" _sc_rotate_jsonl_body \
    "$_src" "$_archive" "$_keep_filter" "$_archive_filter" "$_tmp" "$_atmp" "$@" || _rc=$?
  if [[ $_rc -ne 0 ]]; then
    rm -f "$_tmp" "$_atmp" 2>/dev/null || true
    echo "[${_log_tag}] WARNING: rotation of ${_src} failed — skipping" >&2
    local _plan
    _plan="$(dirname "$(dirname "$_src")")/$(basename "$(dirname "$_src")" .state).md"
    _record_blocked "$_plan" "runtime" "harness" "gc-sidecars" \
      "rotation of $(basename "$_src") failed — manual gc-sidecars run required" 2>/dev/null || true
    return 1
  fi
  rm -f "$_tmp" "$_atmp" 2>/dev/null || true
  return 0
}
