#!/usr/bin/env bash
# Launcher token — signed handshake between harness launcher and capability hook.
# Launcher generates a random token, writes it to a file, passes the path to children.
# Capability hook verifies token file exists, is owned by current uid, and is fresh (<60s).
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_LAUNCHER_TOKEN_LOADED:-}" ]] && return 0
_LAUNCHER_TOKEN_LOADED=1

_LAUNCHER_TOKEN_DIR="${HOME}/.cache/claude-harness"
_LAUNCHER_TOKEN_MAX_AGE=60

# launcher_token_issue — generate token file, export CLAUDE_LAUNCHER_TOKEN_FILE.
# Call once from launcher scripts (run-dev-cycle.sh, run-integration.sh) before spawning Claude.
launcher_token_issue() {
  mkdir -p "$_LAUNCHER_TOKEN_DIR" 2>/dev/null && chmod 0700 "$_LAUNCHER_TOKEN_DIR" || {
    echo "[launcher-token] ERROR: cannot create token dir ${_LAUNCHER_TOKEN_DIR}" >&2; return 1
  }
  local _tfile
  _tfile=$(mktemp "${_LAUNCHER_TOKEN_DIR}/launcher.token.XXXXXX") || return 1
  chmod 0600 "$_tfile"
  # 64 random bytes encoded as hex
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 64 > "$_tfile"
  else
    dd if=/dev/urandom bs=64 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' > "$_tfile"
  fi
  export CLAUDE_LAUNCHER_TOKEN_FILE="$_tfile"
  trap 'rm -f "${CLAUDE_LAUNCHER_TOKEN_FILE:-}" 2>/dev/null || true' EXIT
}

# launcher_token_verify — verify CLAUDE_LAUNCHER_TOKEN_FILE is valid.
# Returns 0 if valid, 1 if invalid/missing/expired/wrong-owner.
launcher_token_verify() {
  local _tfile="${CLAUDE_LAUNCHER_TOKEN_FILE:-}"
  [[ -n "$_tfile" ]] || return 1
  [[ -f "$_tfile" ]] || return 1
  # Ownership check: file must be owned by current user
  local _owner
  if command -v stat >/dev/null 2>&1; then
    if stat -f '%u' "$_tfile" >/dev/null 2>&1; then
      _owner=$(stat -f '%u' "$_tfile" 2>/dev/null) || return 1
    else
      _owner=$(stat -c '%u' "$_tfile" 2>/dev/null) || return 1
    fi
    [[ "$_owner" == "$(id -u)" ]] || return 1
  fi
  # Age check: mtime must be within _LAUNCHER_TOKEN_MAX_AGE seconds
  local _mtime _now _age
  _now=$(date +%s 2>/dev/null) || return 1
  if stat -f '%m' "$_tfile" >/dev/null 2>&1; then
    _mtime=$(stat -f '%m' "$_tfile" 2>/dev/null) || return 1
  else
    _mtime=$(stat -c '%Y' "$_tfile" 2>/dev/null) || return 1
  fi
  _age=$(( _now - _mtime ))
  [[ "$_age" -le "$_LAUNCHER_TOKEN_MAX_AGE" ]] || return 1
  # Content sanity: non-empty
  [[ -s "$_tfile" ]] || return 1
  return 0
}

# launcher_token_revoke — delete token file.
launcher_token_revoke() {
  rm -f "${CLAUDE_LAUNCHER_TOKEN_FILE:-}" 2>/dev/null || true
  unset CLAUDE_LAUNCHER_TOKEN_FILE 2>/dev/null || true
}
