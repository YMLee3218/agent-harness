#!/usr/bin/env bash
# Integration phase helpers — extracted from run-integration.sh to keep it under 200 lines.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_INTEGRATION_HELPERS_LOADED:-}" ]] && return 0
_INTEGRATION_HELPERS_LOADED=1

# All functions use globals set by run-integration.sh:
#   PF PLAN PROJECT_DIR SCRIPTS_DIR UNIT_CMD _lang _domain_root _infra_root _features_root
#   _all_specs _req_file

_INTEGRATION_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=llm-runner.sh
source "$_INTEGRATION_HELPERS_DIR/llm-runner.sh"

# capture variant for categorizer — parent reads nonce-anchored stdout, not plan.md awk
run_llm_capture() {
  local prompt="$1" outfile="$2"
  CLAUDE_NONINTERACTIVE=1 CLAUDE_PLAN_FILE="$PLAN" \
    env -u CLAUDE_PLAN_CAPABILITY claude --model opus --permission-mode auto --dangerously-skip-permissions -p "$prompt" \
    > "$outfile" 2>&1 || true
}

# _handle_spec_phase_rollback CATEGORY — full spec/test/implement rollback for spec-gap or docs-conflict
_handle_spec_phase_rollback() {
  local _cat="$1" _sp _test_files
  bash "$PF" transition "$PLAN" spec "integration failure: ${_cat}"
  bash "$PF" reset-for-rollback "$PLAN" spec
  bash "$PF" reset-milestone "$PLAN" critic-spec
  rm -f "${PLAN%.md}.state"/spec-reviewed-* 2>/dev/null || true
  bash "$PF" transition "$PLAN" red "clearing stale red/critic-test marker before restoring spec"
  bash "$PF" reset-milestone "$PLAN" critic-test
  bash "$PF" transition "$PLAN" spec "restoring spec phase for writing-spec invocation"
  run_llm "Invoke the writing-spec skill to fix the ${_cat}. Plan: $PLAN"
  llm_exit "writing-spec"
  while IFS= read -r _sp; do
    [[ -n "$_sp" ]] && git add "$_sp"
  done < <(git status --porcelain 2>/dev/null | grep 'spec\.md' | awk '{print $2}')
  git diff --cached --quiet || git commit -m "fix(spec): update scenarios for integration ${_cat//' '/-} fix ($(basename "$PLAN" .md))"
  bash "$PF" reset-milestone "$PLAN" critic-spec
  rm -f "${PLAN%.md}.state"/spec-reviewed-* 2>/dev/null || true
  run_critic critic-spec spec "Review updated spec for integration fix. Spec: ${_all_specs}. Docs: $(docs_paths "${_req_file:-}"). Plan: $PLAN."
  llm_exit "critic-spec"
  bash "$PF" transition "$PLAN" red "spec updated for integration fix — updating tests"
  bash "$PF" reset-milestone "$PLAN" critic-test
  run_llm "Invoke the writing-tests skill for the updated spec. Plan: $PLAN"
  llm_exit "writing-tests"
  _test_files=$(_recent_test_files)
  run_critic critic-test red "Review updated tests for integration fix. Spec: ${_all_specs}. Test files: ${_test_files:-tests/}. Plan: $PLAN. Test command: ${UNIT_CMD}."
  llm_exit "critic-test"
  bash "$PF" transition "$PLAN" implement "tests updated for integration fix — implementing"
  bash "$PF" inter-feature-reset "$PLAN"
  run_llm "Invoke the implementing skill for updated spec. Plan: $PLAN"
  llm_exit "implementing"
  bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD"
  bash "$PF" reset-milestone "$PLAN" critic-code
  run_critic critic-code implement "Review integration ${_cat} fix implementation. Spec: ${_all_specs}. Docs: $(docs_paths "${_req_file:-}"). Plan: $PLAN. language: ${_lang}. domain_root: ${_domain_root}. infra_root: ${_infra_root}. features_root: ${_features_root}."
  llm_exit "critic-code"
  bash "$PF" transition "$PLAN" integration "re-entering integration after ${_cat} fix"
}
