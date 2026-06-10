#!/usr/bin/env bash
# Shared wall-clock guard helpers — single source for the timeout-binary build,
# the no-binary BLOCKED:env gate, and the kill-after grace constant.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_TIMEOUT_GUARD_LOADED:-}" ]] && return 0
_TIMEOUT_GUARD_LOADED=1

# SIGTERM→SIGKILL grace (seconds) for every guarded site. Single definition.
TG_KILL_AFTER=30

# timeout_guard_init TIMEOUT_VALUE ENV_VAR_NAME LABEL PLAN_PATH PLAN_FILE_SH
# Sets global TIMEOUT_CMD. If no gtimeout/timeout binary AND TIMEOUT_VALUE!=0:
# append [BLOCKED:env] <label>: no-timeout-binary and exit 1. TIMEOUT_VALUE==0 → TIMEOUT_CMD="".
timeout_guard_init() {
  local _val="$1" _env="$2" _label="$3" _plan="$4" _pf="$5"
  TIMEOUT_CMD=$(command -v gtimeout || command -v timeout || true)
  if [[ -z "$TIMEOUT_CMD" && "$_val" != "0" ]]; then
    bash "$_pf" append-note "$_plan" "[BLOCKED:env] ${_label}: no-timeout-binary — install GNU coreutils (brew install coreutils) or set ${_env}=0 to disable the cap" 2>/dev/null || true
    echo "[BLOCKED:env] ${_label}: no-timeout-binary — install GNU coreutils or set ${_env}=0" >&2
    exit 1
  fi
  if [[ "$_val" == "0" ]]; then TIMEOUT_CMD=""; fi
}
