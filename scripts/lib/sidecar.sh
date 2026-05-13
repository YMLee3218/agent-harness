#!/usr/bin/env bash
# Sidecar state library — atomic JSON/JSONL I/O for plans/{slug}.state/
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_SIDECAR_LOADED:-}" ]] && return 0
_SIDECAR_LOADED=1

SC_VERDICTS="verdicts.jsonl"
SC_BLOCKED="blocked.jsonl"
SC_IMPLEMENTED="implemented.json"
SC_VERDICTS_ARCHIVE="verdicts-archive.jsonl"
SC_BLOCKED_ARCHIVE="blocked-archive.jsonl"
MARK_BLOCKED="[BLOCKED]"
MARK_BLOCKED_CEILING="[BLOCKED-CEILING]"

# Defined here so sidecar helpers can use it without active-plan.sh dependency.
# active-plan.sh re-exports the same function if loaded first; both definitions are identical.
_iso_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S"
}

_scope_of() { printf '%s/%s\n' "$1" "$2"; }

# sc_conv_path PLAN PHASE AGENT → path to convergence JSON for the given scope
sc_conv_path() {
  sc_path "$1" "convergence/${2}__${3}.json"
}

# sc_dir PLAN → absolute path to plans/{slug}.state/
# Anchors check to $CLAUDE_PROJECT_DIR/plans/ to prevent path-traversal.
sc_dir() {
  local _plan="$1" _real _root _proj
  _proj=$(cd "${CLAUDE_PROJECT_DIR:?[sidecar] CLAUDE_PROJECT_DIR is required and must be set}" 2>/dev/null && pwd -P) || {
    echo "[sidecar] FATAL: CLAUDE_PROJECT_DIR not a valid directory: ${CLAUDE_PROJECT_DIR:-<unset>}" >&2; return 2
  }
  _root="${_proj}/plans"
  if command -v realpath >/dev/null 2>&1; then
    _real=$(realpath "$_plan" 2>/dev/null) || \
      _real=$(cd "$(dirname "$_plan")" 2>/dev/null && pwd -P)/$(basename "$_plan")
  else
    _real=$(cd "$(dirname "$_plan")" 2>/dev/null && pwd -P)/$(basename "$_plan")
  fi
  case "$_real" in
    "$_root"/*.md) ;;
    *) echo "[sidecar] FATAL: plan path outside \$CLAUDE_PROJECT_DIR/plans/: $_plan" >&2; return 2 ;;
  esac
  echo "$(dirname "$_real")/$(basename "$_real" .md).state"
}

# _sc_mktemp PATH — mktemp wrapper; refuses empty, relative, or dot PATH to prevent CWD stray files.
# Requires an absolute path (starting with /) to prevent stray temp file creation.
_sc_mktemp() {
  local _p="$1"
  [[ -n "$_p" ]] || { echo "ERROR: _sc_mktemp: empty mktemp template — refusing to create temp file in CWD" >&2; return 1; }
  [[ "$_p" == "." || "$_p" == ".." ]] && { echo "ERROR: _sc_mktemp: '.' or '..' path not allowed" >&2; return 1; }
  [[ "$_p" == /* ]] || { echo "ERROR: _sc_mktemp: non-absolute path not allowed: ${_p}" >&2; return 1; }
  mktemp "${_p}.XXXXXX"
}

# sc_path PLAN STATE_FILE → absolute path inside sidecar dir
sc_path() {
  local _d
  _d=$(sc_dir "$1") || return $?
  echo "$_d/$2"
}

# sc_ensure_dir PLAN — creates sidecar dir (and convergence/ subdir) if absent.
# Dies if the sidecar dir already exists as a symlink (symlink redirect attack prevention).
sc_ensure_dir() {
  local dir _tmp
  dir="$(sc_dir "$1")" || return $?
  if [[ -L "$dir" ]]; then
    echo "[sidecar] FATAL: sidecar dir ${dir} is a symlink — refusing to use redirected path" >&2
    exit 2
  fi
  if [[ ! -d "$dir" ]]; then
    _tmp=$(mktemp -d "${dir}.tmp.XXXXXX") || return 1
    mkdir -p "${_tmp}/convergence"
    if ! mv -n "$_tmp" "$dir" 2>/dev/null; then
      if [[ -L "$_tmp" ]]; then
        echo "[sidecar] FATAL: tmp dir became a symlink — refusing rm: $_tmp" >&2; return 1
      fi
      rm -rf "$_tmp" 2>/dev/null || true
    fi
  fi
  [[ ! -d "${dir}/convergence" ]] && mkdir -p "${dir}/convergence"
  if [[ -L "${dir}/convergence" ]]; then
    echo "[sidecar] FATAL: sidecar convergence subdir ${dir}/convergence is a symlink — refusing to use redirected path" >&2
    exit 2
  fi
}

# ── Lock primitives (inlined from sc-lock.sh) ─────────────────────────────────
# _with_lock lock stack: LIFO, depth via ${#_SC_LOCK_STACK[@]}, cleanup reads array (no path interpolation).
# Outer caller traps saved at depth 0; restored when stack empties.
declare -a _SC_LOCK_STACK=()
_SC_LOCK_CLEANED=0
_SC_LOCK_OUTER_INT=''
_SC_LOCK_OUTER_TERM=''
_SC_LOCK_OUTER_EXIT=''
_SC_LOCK_OUTER_INIT=0

# _sc_lock_cleanup — removes all lockdirs from stack; sets _SC_LOCK_CLEANED=1 for signal-return detection.
_sc_lock_cleanup() {
  local _i _d
  _d=${#_SC_LOCK_STACK[@]}
  for ((_i = _d - 1; _i >= 0; _i--)); do
    rmdir "${_SC_LOCK_STACK[$_i]}" 2>/dev/null || true
    unset "_SC_LOCK_STACK[$_i]"
  done
  _SC_LOCK_STACK=()
  _SC_LOCK_CLEANED=1
}

_sc_lock_restore_traps() {
  trap - INT TERM EXIT
  [ -n "$_SC_LOCK_OUTER_INT" ]  && eval "$_SC_LOCK_OUTER_INT"
  [ -n "$_SC_LOCK_OUTER_TERM" ] && eval "$_SC_LOCK_OUTER_TERM"
  [ -n "$_SC_LOCK_OUTER_EXIT" ] && eval "$_SC_LOCK_OUTER_EXIT"
  _SC_LOCK_OUTER_INIT=0
}

# _with_lock LOCK_BASE_PATH BODY_FN [ARGS...] — atomic mkdir-based lock; runs BODY_FN while held.
# mkdir is atomic and does not follow existing symlinks — eliminates the TOCTOU window.
# Symlink guard: refuses if lockdir path is already a symlink (fail-closed).
# Trap guard: uses stack array instead of path interpolation — no single-quote injection possible.
# Depth is derived from ${#_SC_LOCK_STACK[@]} — no separate counter that can go negative.
_with_lock() {
  local _lockdir="${1}.lockdir"; shift
  [ -L "$_lockdir" ] && { echo "ERROR: _with_lock: lockdir is symlink — refusing: ${_lockdir}" >&2; return 1; }
  local _s; _s=$(date +%s)
  while ! mkdir "$_lockdir" 2>/dev/null; do
    [ $(( $(date +%s) - _s )) -ge 30 ] && { echo "ERROR: _with_lock: timeout 30s on ${_lockdir}" >&2; return 1; }
    sleep 0.1
  done
  # Only save caller traps at depth 0; _SC_LOCK_OUTER_INIT guards against re-capture on nested entry.
  if [[ "${#_SC_LOCK_STACK[@]}" -eq 0 ]] && [[ "$_SC_LOCK_OUTER_INIT" -eq 0 ]]; then
    _SC_LOCK_OUTER_INT=$(trap -p INT 2>/dev/null)
    _SC_LOCK_OUTER_TERM=$(trap -p TERM 2>/dev/null)
    _SC_LOCK_OUTER_EXIT=$(trap -p EXIT 2>/dev/null)
    _SC_LOCK_OUTER_INIT=1
    trap '_sc_lock_cleanup' INT TERM EXIT  # no path interpolation: reads stack array
  fi
  _SC_LOCK_STACK+=("$_lockdir")
  _SC_LOCK_CLEANED=0
  local _rc=0
  "$@" || _rc=$?
  # Guard: if a non-exit signal fired _sc_lock_cleanup, restore traps and return.
  if [[ "${_SC_LOCK_CLEANED:-0}" -eq 1 ]]; then
    _SC_LOCK_CLEANED=0
    if [[ "${#_SC_LOCK_STACK[@]}" -eq 0 ]]; then
      _sc_lock_restore_traps
    fi
    return $_rc
  fi
  rmdir "$_lockdir" 2>/dev/null || true
  unset '_SC_LOCK_STACK[-1]'
  if [[ "${#_SC_LOCK_STACK[@]}" -eq 0 ]]; then
    _sc_lock_restore_traps
  fi
  return $_rc
}

sc_read_json() {
  local path="$1"
  local default="${2}"
  [[ -n "$default" ]] || default='{}'
  if [[ -f "$path" ]]; then
    cat "$path"
  else
    printf '%s' "$default"
  fi
}

# sc_update_json PATH JSON — atomic write via tmp+mv (_with_lock-protected)
sc_update_json() {
  local _path="$1" _json="$2" _tmp
  _tmp=$(_sc_mktemp "$_path") || return 1
  printf '%s\n' "$_json" > "$_tmp" || { rm -f "$_tmp"; return 1; }
  _with_lock "${_path}.lock" mv "$_tmp" "${_path}" || { rm -f "$_tmp"; return 1; }
}

# ── JSONL helpers (inlined from sc-jsonl.sh) ──────────────────────────────────
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
    echo "[${_log_tag}] WARNING: rotation of ${_src} failed — manual gc-sidecars run required" >&2
    return 1
  fi
  rm -f "$_tmp" "$_atmp" 2>/dev/null || true
  return 0
}

# Convergence JSON schema (convergence/{phase}__{agent}.json):
# {"phase":"implement","agent":"critic-code","first_turn":true,"streak":2,
#  "converged":true,"ceiling_blocked":false,"ordinal":2,"milestone_seq":0}
# milestone_seq increments on reset-milestone/clear-converged; isolates streak history between milestones.
# Blocked JSONL schema (blocked.jsonl, one record per line):
# {"ts":"2025-05-10T12:00:00Z","kind":"ceiling","agent":"critic-code",
#  "scope":"implement/critic-code","message":"exceeded 5 runs","cleared_at":null}
# kind enum: ceiling | parse | category | protocol-violation | preflight | integration | coder | ambiguous | runtime
# sc_make_conv_state PHASE AGENT [FT STREAK CONV CB ORD MS]
# Builds a convergence JSON object. All keys emitted in canonical order.
# Defaults: first_turn=false streak=0 converged=false ceiling_blocked=false ordinal=0 milestone_seq=0
sc_make_conv_state() {
  local _phase="$1" _agent="$2"
  local _ft="${3:-false}" _streak="${4:-0}" _conv="${5:-false}"
  local _cb="${6:-false}" _ord="${7:-0}" _ms="${8:-0}"
  jq -nc \
    --arg phase "$_phase" --arg agent "$_agent" \
    --argjson ft "$_ft" --argjson streak "$_streak" \
    --argjson conv "$_conv" --argjson cb "$_cb" \
    --argjson ord "$_ord" --argjson ms "$_ms" \
    '{"phase":$phase,"agent":$agent,"first_turn":$ft,"streak":$streak,"converged":$conv,"ceiling_blocked":$cb,"ordinal":$ord,"milestone_seq":$ms}'
}
