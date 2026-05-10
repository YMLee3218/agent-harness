#!/usr/bin/env bash
# Sidecar state library — atomic JSON/JSONL I/O for plans/{slug}.state/
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_SIDECAR_LOADED:-}" ]] && return 0
_SIDECAR_LOADED=1

# sc_dir PLAN → absolute path to plans/{slug}.state/
sc_dir() {
  echo "$(dirname "$1")/$(basename "$1" .md).state"
}

# sc_path PLAN STATE_FILE → absolute path inside sidecar dir
sc_path() {
  echo "$(sc_dir "$1")/$2"
}

# sc_ensure_dir PLAN — creates sidecar dir (and convergence/ subdir) if absent.
# Dies if the sidecar dir already exists as a symlink (C1-5th: symlink redirect attack prevention).
sc_ensure_dir() {
  local dir
  dir="$(sc_dir "$1")"
  if [[ -L "$dir" ]]; then
    echo "[sidecar] FATAL: sidecar dir ${dir} is a symlink — refusing to use redirected path" >&2
    exit 2
  fi
  mkdir -p "${dir}/convergence"
  # C1-5th extended: also check convergence/ subdir, which an agent could symlink after top-level
  # dir is created (e.g. `ln -s /tmp/fake plans/foo.state/convergence`).
  if [[ -L "${dir}/convergence" ]]; then
    echo "[sidecar] FATAL: sidecar convergence subdir ${dir}/convergence is a symlink — refusing to use redirected path" >&2
    exit 2
  fi
}

# sc_read_json PATH [DEFAULT_JSON] — cat file or emit default
sc_read_json() {
  local path="$1" default="${2:-{}}"
  if [[ -f "$path" ]]; then
    cat "$path"
  else
    printf '%s' "$default"
  fi
}

# sc_update_json PATH JSON — atomic write via tmp+mv (flock-protected to guard read-modify-write)
sc_update_json() {
  local path="$1" json="$2"
  local tmp
  tmp=$(mktemp "${path}.XXXXXX")
  printf '%s\n' "$json" > "$tmp"
  if command -v flock >/dev/null 2>&1; then
    local _rc=0
    (
      flock -w 5 200 || { rm -f "$tmp"; echo "[sidecar] lock timeout for ${path}" >&2; exit 1; }
      mv "$tmp" "$path"
    ) 200>"${path}.lock" || _rc=$?
    if [[ $_rc -ne 0 ]]; then
      rm -f "$tmp"
      echo "[sidecar] sc_update_json failed for ${path} (rc=${_rc})" >&2
      return 1
    fi
  else
    mv "$tmp" "$path"
  fi
}

# sc_append_jsonl PATH RECORD_JSON — append one JSON line to JSONL file (flock-protected)
sc_append_jsonl() {
  local path="$1" record="$2"
  if command -v flock >/dev/null 2>&1; then
    local _rc=0
    (
      flock -w 5 200 || { echo "[sidecar] lock timeout for ${path}" >&2; exit 1; }
      printf '%s\n' "$record" >> "$path"
    ) 200>"${path}.lock" || _rc=$?
    if [[ $_rc -ne 0 ]]; then
      echo "[sidecar] sc_append_jsonl failed for ${path} (rc=${_rc})" >&2
      return 1
    fi
  else
    printf '%s\n' "$record" >> "$path"
  fi
}

# sc_append_jsonl_unlocked PATH RECORD_JSON — append one JSON line without locking (caller holds lock)
sc_append_jsonl_unlocked() {
  printf '%s\n' "$2" >> "$1"
}

# _sc_rewrite_jsonl JSONL_PATH JQ_FILTER LOG_TAG [JQ_ARGS...] — rewrite JSONL atomically via flock+tmp+mv.
# Used to update cleared_at fields. Returns 0 on success; 1 on failure (logs error).
_sc_rewrite_jsonl() {
  local _bpath="$1" _jq_filter="$2" _log_tag="$3"
  shift 3
  [[ -f "$_bpath" ]] || return 0
  local _tmp _rc=0
  _tmp=$(mktemp "${_bpath}.XXXXXX")
  if command -v flock >/dev/null 2>&1; then
    (
      flock -w 5 200 || { rm -f "$_tmp"; echo "[sidecar] lock timeout for ${_bpath}" >&2; exit 1; }
      jq -c "$@" "$_jq_filter" "$_bpath" > "$_tmp" && mv "$_tmp" "$_bpath" || { rm -f "$_tmp"; exit 1; }
    ) 200>"${_bpath}.lock" || _rc=$?
  else
    jq -c "$@" "$_jq_filter" "$_bpath" > "$_tmp" && mv "$_tmp" "$_bpath" || { rm -f "$_tmp"; _rc=1; }
  fi
  if [[ $_rc -ne 0 ]]; then
    rm -f "$_tmp" 2>/dev/null || true
    echo "[${_log_tag}] ERROR: failed to rewrite ${_bpath} — aborting to prevent state divergence" >&2
    return 1
  fi
}

# _sc_rotate_jsonl SRC ARCHIVE KEEP_FILTER ARCHIVE_FILTER LOG_TAG [JQ_ARGS...]
# Keep-first rotation: write keep set to tmp, then archive the rest, then mv.
# Returns 0 on success; 1 on lock timeout or jq failure (logs warning).
_sc_rotate_jsonl() {
  local _src="$1" _archive="$2" _keep_filter="$3" _archive_filter="$4" _log_tag="$5"
  shift 5
  local _tmp _rc=0
  _tmp=$(mktemp "${_src}.XXXXXX")
  (
    if command -v flock >/dev/null 2>&1; then
      flock -w 5 200 || { rm -f "$_tmp"; echo "[sidecar] lock timeout for ${_src}" >&2; exit 1; }
    fi
    jq -c "$@" "$_keep_filter" "$_src" 2>/dev/null > "$_tmp" || { rm -f "$_tmp"; exit 1; }
    jq -c "$@" "$_archive_filter" "$_src" 2>/dev/null >> "$_archive" || { rm -f "$_tmp"; exit 1; }
    mv "$_tmp" "$_src"
  ) 200>"${_src}.lock" || _rc=$?
  if [[ $_rc -ne 0 ]]; then
    rm -f "$_tmp" 2>/dev/null || true
    echo "[${_log_tag}] WARNING: rotation of ${_src} failed — skipping" >&2
    return 1
  fi
  return 0
}
