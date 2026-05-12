#!/usr/bin/env bash
# Sidecar state library — atomic JSON/JSONL I/O for plans/{slug}.state/
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_SIDECAR_LOADED:-}" ]] && return 0
_SIDECAR_LOADED=1

SC_VERDICTS="verdicts.jsonl"
SC_BLOCKED="blocked.jsonl"
SC_IMPLEMENTED="implemented.json"
# use consistent hyphen spelling for archive constants across all callers
SC_VERDICTS_ARCHIVE="verdicts-archive.jsonl"
SC_BLOCKED_ARCHIVE="blocked-archive.jsonl"
MARK_BLOCKED="[BLOCKED]"
MARK_BLOCKED_CEILING="[BLOCKED-CEILING]"
MARK_NOT_PERSISTED_CORRUPT="[NOT-PERSISTED:CORRUPT]"
MARK_NOT_PERSISTED_CORRUPT_CHECK="[NOT-PERSISTED:CORRUPT-CHECK]"
MARK_NOT_PERSISTED_STREAK="[NOT-PERSISTED:STREAK]"

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
    if [ -e "$dir" ] || [ -L "$dir" ]; then
      echo "[sidecar] FATAL: $dir appeared (or is symlink) during ensure — refusing mv" >&2
      rm -rf "$_tmp" 2>/dev/null || true
      return 1
    fi
    # mv is atomic at the rename(2) level; the pre-check above is for diagnostics only.
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

# Lock primitives sourced from sc-lock.sh
_SC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SC_LIB_DIR}/sc-lock.sh"

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

# JSONL helpers sourced from sc-jsonl.sh
source "${_SC_LIB_DIR}/sc-jsonl.sh"

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
