#!/usr/bin/env bash
# Sidecar lock primitives — atomic mkdir-based lock with LIFO stack and trap guard.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_SC_LOCK_LOADED:-}" ]] && return 0
_SC_LOCK_LOADED=1

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
