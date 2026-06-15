#!/usr/bin/env bash
# Worker sandbox helpers — initialize and apply macOS Seatbelt to leaf worker spawns.
# This is the Tier 1 (AUTHORITATIVE) enforcement layer per reference/enforcement-tiers.md.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_SANDBOX_LIB_LOADED:-}" ]] && return 0
_SANDBOX_LIB_LOADED=1

_WORKER_SANDBOX_ARGS=()
_SANDBOX_REQUIRED_FAIL=0

# _init_worker_sandbox PROJ_DIR — populate _WORKER_SANDBOX_ARGS for macOS Seatbelt.
# On success: _WORKER_SANDBOX_ARGS is set and _SANDBOX_REQUIRED_FAIL remains 0.
# On unavailability (non-Darwin, no sandbox-exec, worker.sb missing): sets
# _SANDBOX_REQUIRED_FAIL=1 unless CLAUDE_ALLOW_UNSANDBOXED=1 is set.
# Callers must check _SANDBOX_REQUIRED_FAIL after calling this function.
_init_worker_sandbox() {
  local _proj_dir="${1:-}"
  _WORKER_SANDBOX_ARGS=()
  _SANDBOX_REQUIRED_FAIL=0
  if [[ -z "$_proj_dir" ]]; then
    echo "[sandbox-lib] WARN: no PROJ_DIR supplied; Tier 1 inactive" >&2
    _sandbox_unavailable "no PROJ_DIR"; return 0
  fi
  # Resolve symlinks so Seatbelt deny rules match the kernel-resolved path.
  _proj_dir="$(cd "$_proj_dir" 2>/dev/null && pwd -P || printf '%s' "$_proj_dir")"
  if [[ "$(uname 2>/dev/null)" != "Darwin" ]]; then
    echo "[sandbox-lib] WARN: non-macOS platform; Tier 1 inactive (Linux bubblewrap not yet implemented)" >&2
    _sandbox_unavailable "non-Darwin"; return 0
  fi
  if ! command -v sandbox-exec >/dev/null 2>&1; then
    echo "[sandbox-lib] WARN: sandbox-exec not found; Tier 1 inactive" >&2
    _sandbox_unavailable "sandbox-exec-missing"; return 0
  fi
  local _sb; _sb="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../worker.sb"
  if [[ ! -f "$_sb" ]]; then
    echo "[sandbox-lib] WARN: worker.sb not found at ${_sb}; Tier 1 inactive" >&2
    _sandbox_unavailable "worker.sb-missing"; return 0
  fi
  local _phase_regex="^${_proj_dir}/plans/[^/]+\\.phase\$"
  local _state_regex="^${_proj_dir}/plans/[^/]+\\.state(/|\$)"
  _WORKER_SANDBOX_ARGS=(
    sandbox-exec -f "$_sb"
    -D "PROJ_ROOT=${_proj_dir}"
    -D "PROJ_HARNESS=${_proj_dir}/.claude-harness"
    -D "PLANS_PHASE_REGEX=${_phase_regex}"
    -D "PLANS_STATE_REGEX=${_state_regex}"
    -D "PROJ_CLAUDE_MD=${_proj_dir}/CLAUDE.md"
    -D "PROJ_GITFILE=${_proj_dir}/.git"
  )
}

# _sandbox_unavailable REASON — sets _SANDBOX_REQUIRED_FAIL unless CLAUDE_ALLOW_UNSANDBOXED=1.
_sandbox_unavailable() {
  local _reason="${1:-unknown}"
  if [[ "${CLAUDE_ALLOW_UNSANDBOXED:-0}" != "1" ]]; then
    _SANDBOX_REQUIRED_FAIL=1
    echo "[sandbox-lib] BLOCKED: Tier 1 sandbox unavailable (${_reason}); set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined" >&2
  else
    echo "[sandbox-lib] WARN: Tier 1 sandbox unavailable (${_reason}); CLAUDE_ALLOW_UNSANDBOXED=1 — running unconfined" >&2
  fi
}

# _sandbox_guard — fail-closed precheck for timeout-prefixed spawn sites that
# cannot use worker_exec (timeout execs a binary, not a shell function).
_sandbox_guard() {
  [[ ${#_WORKER_SANDBOX_ARGS[@]} -gt 0 ]] && return 0
  [[ "${_SANDBOX_REQUIRED_FAIL:-0}" == "1" ]] || return 0
  echo "[BLOCKED:env] sandbox: tier1-unavailable — set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined" >&2
  return 1
}

# worker_exec CMD [ARGS...] — run a command inside the worker sandbox when active.
# If sandbox is unavailable and CLAUDE_ALLOW_UNSANDBOXED=1 is not set, refuses to run.
worker_exec() {
  if [[ ${#_WORKER_SANDBOX_ARGS[@]} -gt 0 ]]; then
    "${_WORKER_SANDBOX_ARGS[@]}" "$@"
  elif [[ "${_SANDBOX_REQUIRED_FAIL:-0}" == "1" ]]; then
    echo "[BLOCKED:env] sandbox: tier1-unavailable — set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined" >&2
    return 1
  else
    "$@"
  fi
}
