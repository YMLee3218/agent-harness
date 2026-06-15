#!/usr/bin/env bash
# Worker sandbox helpers — initialize and apply macOS Seatbelt to leaf worker spawns.
# This is the Tier 1 (AUTHORITATIVE) enforcement layer per reference/enforcement-tiers.md.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_SANDBOX_LIB_LOADED:-}" ]] && return 0
_SANDBOX_LIB_LOADED=1

_WORKER_SANDBOX_ARGS=()

# _init_worker_sandbox PROJ_DIR — populate _WORKER_SANDBOX_ARGS for macOS Seatbelt.
# No-ops silently on non-macOS, when sandbox-exec is absent, or when PROJ_DIR is empty.
_init_worker_sandbox() {
  local _proj_dir="${1:-}"
  _WORKER_SANDBOX_ARGS=()
  [[ -z "$_proj_dir" ]] && return 0
  [[ "$(uname 2>/dev/null)" != "Darwin" ]] && return 0
  command -v sandbox-exec >/dev/null 2>&1 || return 0
  local _sb; _sb="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../worker.sb"
  [[ -f "$_sb" ]] || { echo "[sandbox-lib] WARN: worker.sb not found at ${_sb}; Tier 1 inactive" >&2; return 0; }
  local _plans_regex="^${_proj_dir}/plans/[^/]+\\.md\$"
  _WORKER_SANDBOX_ARGS=(
    sandbox-exec -f "$_sb"
    -D "PROJ_SRC=${_proj_dir}/src"
    -D "PROJ_TESTS=${_proj_dir}/tests"
    -D "PROJ_DOCS=${_proj_dir}/docs"
    -D "PLANS_MD_REGEX=${_plans_regex}"
  )
}

# worker_exec CMD [ARGS...] — run a command inside the worker sandbox when active.
worker_exec() {
  if [[ ${#_WORKER_SANDBOX_ARGS[@]} -gt 0 ]]; then
    "${_WORKER_SANDBOX_ARGS[@]}" "$@"
  else
    "$@"
  fi
}
