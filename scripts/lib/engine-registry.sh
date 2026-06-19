#!/usr/bin/env bash
# engine-registry.sh — single source of truth for role → (engine, model) routing.
# Source this file; do not execute directly.
#
# Implemented as a sourceable `case` FUNCTION rather than an associative array on
# purpose: run-critic-loop.sh re-execs itself (CLAUDE_PLAN_CAPABILITY=harness) and an
# associative array would not survive the exec — a case function is re-source/re-exec
# safe because it is redefined every time the file is sourced.
set -euo pipefail
[[ -n "${_ENGINE_REGISTRY_LOADED:-}" ]] && return 0
_ENGINE_REGISTRY_LOADED=1

# _ENGINE_REGISTRY ROLE → prints "ENGINE MODEL" (MODEL empty = engine default).
# Returns 1 for an unknown role.
_ENGINE_REGISTRY() {
  case "$1" in
    brainstorm|spec-author|implement-planner|critic-feature)
      printf 'claude opus' ;;
    test-author|critic-decision|critic-pass-audit|integration-categorizer|merge-gate)
      printf 'claude sonnet' ;;
    coder|critic-fix|critic-spec|critic-test|critic-code|critic-cross|critic-quality)
      printf 'codex %s' "${HARNESS_CODEX_MODEL:-}" ;;
    *) return 1 ;;
  esac
}

# _role_env_name PREFIX ROLE → prints the override env var name (ROLE uppercased, - → _).
# e.g. _role_env_name HARNESS_MODEL test-author → HARNESS_MODEL_TEST_AUTHOR
_role_env_name() {
  local _key
  _key=$(printf '%s' "$2" | tr '[:lower:]-' '[:upper:]_')
  printf '%s_%s' "$1" "$_key"
}

# engine_for ROLE → prints the resolved engine. HARNESS_ENGINE_<ROLE> overrides the table.
# Returns 1 for an unknown role with no override.
engine_for() {
  local _ovr _val
  _ovr=$(_role_env_name HARNESS_ENGINE "$1")
  if [[ -n "${!_ovr:-}" ]]; then printf '%s' "${!_ovr}"; return 0; fi
  _val=$(_ENGINE_REGISTRY "$1") || return 1
  printf '%s' "${_val%% *}"
}

# model_for ROLE → prints the resolved model ("" = engine default).
# Override precedence: HARNESS_MODEL_<ROLE> > role-specific back-compat > registry default.
# Back-compat: critic-feature honours CLAUDE_CRITIC_LOOP_MODEL (default opus) so existing
# deployments that pin the B-session model keep working.
model_for() {
  local _ovr _val _model
  _ovr=$(_role_env_name HARNESS_MODEL "$1")
  if [[ -n "${!_ovr:-}" ]]; then printf '%s' "${!_ovr}"; return 0; fi
  if [[ "$1" == "critic-feature" ]]; then printf '%s' "${CLAUDE_CRITIC_LOOP_MODEL:-opus}"; return 0; fi
  _val=$(_ENGINE_REGISTRY "$1") || return 1
  if [[ "$_val" == *" "* ]]; then _model="${_val#* }"; else _model=""; fi
  printf '%s' "$_model"
}
