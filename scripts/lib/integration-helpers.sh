#!/usr/bin/env bash
# Integration phase helpers — extracted from run-integration.sh to keep it under 200 lines.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_INTEGRATION_HELPERS_LOADED:-}" ]] && return 0
_INTEGRATION_HELPERS_LOADED=1

# All functions use globals set by run-integration.sh:
#   PF PLAN PROJECT_DIR SCRIPTS_DIR UNIT_CMD LINT_CMD _lang _domain_root _infra_root _features_root
#   _all_specs _feature_specs _req_file

_INTEGRATION_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=llm-runner.sh
source "$_INTEGRATION_HELPERS_DIR/llm-runner.sh"

# capture variant for categorizer — parent reads nonce-anchored stdout, not plan.md awk
run_llm_capture() {
  local prompt="$1" outfile="$2" _ec=0
  _sandbox_guard || { echo "[BLOCKED:env] run_llm_capture: sandbox-unavailable" > "$outfile"; return 1; }
  CLAUDE_NONINTERACTIVE=1 CLAUDE_PLAN_FILE="$PLAN" \
    ${TIMEOUT_CMD:+$TIMEOUT_CMD --kill-after=$TG_KILL_AFTER $INTEGRATION_TIMEOUT} \
    "${_WORKER_SANDBOX_ARGS[@]}" env -u CLAUDE_PLAN_CAPABILITY claude --model sonnet --permission-mode auto --dangerously-skip-permissions -p "$prompt" \
    > "$outfile" 2>&1 || _ec=$?
  return "$_ec"
}

# _handle_spec_phase_rollback CATEGORY — full spec/test/implement rollback for spec-gap
_handle_spec_phase_rollback() {
  local _cat="$1" _sp _test_files
  bash "$PF" transition "$PLAN" spec "integration failure: ${_cat}"
  bash "$PF" reset-for-rollback "$PLAN" spec
  bash "$PF" inter-feature-reset "$PLAN"
  bash "$PF" reset-milestone "$PLAN" critic-cross 2>/dev/null || true
  bash "$PF" reset-milestone "$PLAN" critic-spec
  rm -f "${PLAN%.md}.state"/spec-reviewed-* 2>/dev/null || true
  bash "$PF" transition "$PLAN" red "clearing stale red/critic-test marker before restoring spec"
  bash "$PF" reset-milestone "$PLAN" critic-test
  bash "$PF" transition "$PLAN" spec "restoring spec phase for writing-spec invocation"
  run_llm "Invoke the writing-spec skill to fix the ${_cat}. Plan: $PLAN" opus
  llm_exit "writing-spec"
  while IFS= read -r _sp; do
    [[ -n "$_sp" ]] && git -C "$PROJECT_DIR" add "$_sp"
  done < <(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | awk '{print $NF}' \
           | grep -E '(^|/)spec\.md$|\.spec\.md$')
  git -C "$PROJECT_DIR" diff --cached --quiet || \
    git -C "$PROJECT_DIR" commit -m "fix(spec): update scenarios for integration ${_cat//' '/-} fix ($(basename "$PLAN" .md))"
  bash "$PF" reset-milestone "$PLAN" critic-spec
  rm -f "${PLAN%.md}.state"/spec-reviewed-* 2>/dev/null || true
  CRITIC_SPEC_PATH="${_feature_specs}" \
  CRITIC_DOCS_PATHS="$(docs_paths "${_req_file:-}")" \
  CRITIC_PLAN_PATH="${PLAN}" \
  run_critic critic-spec spec "Review updated spec for integration fix. Spec: ${_feature_specs}. Docs: $(docs_paths "${_req_file:-}"). Plan: $PLAN."
  llm_exit "critic-spec"
  CRITIC_ALL_SPEC_PATHS="${_all_specs}" \
  CRITIC_DOCS_PATHS="$(docs_paths "${_req_file:-}")" \
  CRITIC_PLAN_PATH="${PLAN}" \
  run_critic critic-cross spec "Cross-feature consistency review after integration spec fix. All specs: ${_all_specs}. Docs: $(docs_paths "${_req_file:-}"). Plan: $PLAN."
  llm_exit "critic-cross"
  bash "$PF" transition "$PLAN" red "spec updated for integration fix — updating tests"
  bash "$PF" reset-milestone "$PLAN" critic-test
  local _pre_test_sha; _pre_test_sha=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "")
  WRITING_TESTS_SPEC_PATH="${_feature_specs}" \
  WRITING_TESTS_PLAN_PATH="${PLAN}" \
  WRITING_TESTS_COMMAND="${UNIT_CMD}" \
  run_llm "Invoke the writing-tests skill for the updated spec. Plan: $PLAN" sonnet
  llm_exit "writing-tests"
  while IFS= read -r _tf_file; do
    [[ -n "$_tf_file" ]] && git -C "$PROJECT_DIR" add "$_tf_file"
  done < <(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | awk '{print $NF}' \
           | grep -E '(^|/)tests/|(^|/)conftest\.|_test\.|(^|/)test_|\.test\.|\.spec\.|_spec\.' | grep -v '\.spec\.md$')
  git -C "$PROJECT_DIR" diff --cached --quiet || \
    git -C "$PROJECT_DIR" commit -m "test(red): add failing tests for integration ${_cat//' '/-} fix"
  _test_files=$(_recent_test_files "$_pre_test_sha")
  if [[ -z "$_test_files" ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED:env] critic-test: cannot-derive-test-files — integration fix: no test(red): commit found; re-run writing-tests"
    exit 1
  fi
  _green_preexisting_integrity_gate "$_pre_test_sha"
  CRITIC_SPEC_PATH="${_feature_specs}" \
  CRITIC_TEST_FILES="${_test_files}" \
  CRITIC_PLAN_PATH="${PLAN}" \
  CRITIC_TEST_COMMAND="${UNIT_CMD}" \
  run_critic critic-test red "Review updated tests for integration fix. Spec: ${_feature_specs}. Test files: ${_test_files}. Plan: $PLAN. Test command: ${UNIT_CMD}."
  llm_exit "critic-test"
  while IFS= read -r _tf_file; do
    [[ -n "$_tf_file" ]] && git -C "$PROJECT_DIR" add "$_tf_file"
  done < <(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | awk '{print $NF}' \
           | grep -E '(^|/)tests/|(^|/)conftest\.|_test\.|(^|/)test_|\.test\.|\.spec\.|_spec\.' | grep -v '\.spec\.md$')
  git -C "$PROJECT_DIR" diff --cached --quiet || \
    git -C "$PROJECT_DIR" commit -m "test(red): apply critic-test fixes for integration ${_cat//' '/-} fix"
  bash "$PF" transition "$PLAN" implement "tests updated for integration fix — implementing"
  bash "$PF" inter-feature-reset "$PLAN"
  run_llm "Invoke the implementing skill for updated spec. Plan: $PLAN" opus
  llm_exit "implementing"
  bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD" --lint-cmd "$LINT_CMD"
  bash "$PF" reset-milestone "$PLAN" critic-code
  CRITIC_SPEC_PATH="${_feature_specs}" \
  CRITIC_DOCS_PATHS="$(docs_paths "${_req_file:-}")" \
  CRITIC_PLAN_PATH="${PLAN}" \
  CRITIC_LANGUAGE="${_lang}" \
  CRITIC_DOMAIN_ROOT="${_domain_root}" \
  CRITIC_INFRA_ROOT="${_infra_root}" \
  CRITIC_FEATURES_ROOT="${_features_root}" \
  run_critic critic-code implement "Review integration ${_cat} fix implementation. Spec: ${_feature_specs}. Docs: $(docs_paths "${_req_file:-}"). Plan: $PLAN. language: ${_lang}. domain_root: ${_domain_root}. infra_root: ${_infra_root}. features_root: ${_features_root}."
  llm_exit "critic-code"
  bash "$PF" transition "$PLAN" integration "re-entering integration after ${_cat} fix"
}
