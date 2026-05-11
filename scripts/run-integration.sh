#!/usr/bin/env bash
set -euo pipefail
export CLAUDE_PLAN_CAPABILITY=harness
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# D1: issue launcher token before spawning Claude subprocess
. "$SCRIPTS_DIR/lib/launcher-token.sh" && launcher_token_issue 2>/dev/null || true
PF="$SCRIPTS_DIR/plan-file.sh"
PLAN="" UNIT_CMD="" INTEGRATION_CMD=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --plan)             PLAN="$2";             shift 2 ;;
    --unit-cmd)         UNIT_CMD="$2";         shift 2 ;;
    --integration-cmd)  INTEGRATION_CMD="$2";  shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -z "$PLAN" || -z "$INTEGRATION_CMD" ]] && {
  echo "Usage: run-integration.sh --plan PATH --integration-cmd CMD [--unit-cmd CMD]" >&2; exit 1; }
[[ -f "$PLAN" ]] || { echo "Plan file not found: $PLAN" >&2; exit 1; }
[[ "$UNIT_CMD" == _\(run* ]] && UNIT_CMD=""
[[ "$INTEGRATION_CMD" == _\(run* ]] && { echo "run-integration: integration-cmd is unfilled — run /initializing-project first" >&2; exit 1; }

# shellcheck source=lib/run-context.sh
source "$SCRIPTS_DIR/lib/run-context.sh"
setup_run_context

# shellcheck source=lib/integration-helpers.sh
source "$SCRIPTS_DIR/lib/integration-helpers.sh"

_plan_slug=$(basename "$PLAN" .md)
_req_file="${PROJECT_DIR}/docs/requirements/${_plan_slug}.md"
_feat_slug="$_plan_slug"
if [[ -f "$_req_file" ]]; then
  _first_feat=$(_features_block "$_req_file" | head -1)
  [[ -n "$_first_feat" ]] && _feat_slug=$(_slugify_feature "$_first_feat")
fi

_all_specs=""
if [[ -f "$_req_file" ]]; then
  while IFS= read -r _feat; do
    [[ -z "$_feat" ]] && continue
    _fslug=$(_slugify_feature "$_feat")
    _sp=$(find_spec_path "$_fslug")
    _all_specs="${_all_specs:+$_all_specs }${_sp}"
  done < <(_features_block "$_req_file")
fi
[[ -z "$_all_specs" ]] && _all_specs=$(find_spec_path "$_feat_slug")

# _validate_integration_preconditions — run unit tests before integration; block on failure.
_validate_integration_preconditions() {
  [[ -z "$UNIT_CMD" ]] && return 0
  bash -c "$UNIT_CMD" 2>&1 && return 0
  bash "$PF" transition "$PLAN" implement "unit tests failing at integration entry — clearing implement-phase markers"
  bash "$PF" reset-for-rollback "$PLAN" implement
  bash "$PF" transition "$PLAN" red "unit tests failing at integration entry — fresh task planning needed"
  bash "$PF" reset-milestone "$PLAN" critic-test
  bash "$PF" append-note "$PLAN" "[BLOCKED] unit tests failing before integration tests — resolve via /implementing before re-running"
  exit 1
}

_validate_integration_preconditions
bash "$PF" transition "$PLAN" integration "starting integration test run"

attempt=0
max_attempts=2

while true; do
  if test_output=$(bash -c "$INTEGRATION_CMD" 2>&1); then
    bash "$PF" transition "$PLAN" done "integration tests passed"
    exit 0
  fi

  attempt=$((attempt + 1))
  tail_output=$(printf '%s' "$test_output" | tail -50)
  today=$(date +%Y-%m-%d)

  if [[ $attempt -ge $max_attempts ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED] integration: tests failed after $((max_attempts - 1)) fix attempt(s) — manual review required"
    exit 1
  fi

  # categorizer uses nonce-anchored stdout marker
  _cat_nonce=$(uuidgen 2>/dev/null || openssl rand -hex 8 2>/dev/null || printf '%s%s' "$$" "$(date +%s%N)")
  _cat_out=$(mktemp)
  run_llm_capture "Integration test failure categorization. Plan file: $PLAN. Test output tail:
${tail_output}

Read the plan file, then under ## Integration Failures (create the section if absent) append:
### Run ${attempt} — ${today}
Then for each failing test:
#### {test name}
Category: {docs conflict | spec gap | implementation bug}
Description: {one sentence}
Log [AUTO-CATEGORIZED-INTEGRATION] {test name}: {category} for each.
If the categories across all failing tests are mixed (not all the same), append [BLOCKED] integration: mixed failure categories — manual review required to ## Open Questions and stop.
If ambiguous for any individual test, append [BLOCKED] integration:{test name}: cannot determine category automatically — manual review required to ## Open Questions and stop.

After completing the above, output as the very last line of your response exactly one of:
<!-- integration-result: ${_cat_nonce} docs conflict -->
<!-- integration-result: ${_cat_nonce} spec gap -->
<!-- integration-result: ${_cat_nonce} implementation bug -->
<!-- integration-result: ${_cat_nonce} blocked -->" "$_cat_out"
  cat "$_cat_out"

  _cat_marker=$(grep -o "<!-- integration-result: ${_cat_nonce} [a-z ]* -->" "$_cat_out" | tail -1 | \
                sed "s|<!-- integration-result: ${_cat_nonce} ||; s| -->||" | tr -d '\n' || true)
  rm -f "$_cat_out"

  if [[ "$_cat_marker" == "blocked" || -z "$_cat_marker" ]]; then
    [[ -z "$_cat_marker" ]] && bash "$PF" append-note "$PLAN" \
      "[BLOCKED] integration: categorizer produced no result marker — re-run or review manually" 2>/dev/null || true
    exit 1
  fi

  category="$_cat_marker"
  if [[ "$category" != "docs conflict" && "$category" != "spec gap" && "$category" != "implementation bug" ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED] integration: categorizer returned unrecognised category '${category}' — manual review required"
    exit 1
  fi

  case "$category" in
    "implementation bug")
      bash "$PF" transition "$PLAN" implement "integration failure: implementation bug"
      bash "$PF" reset-for-rollback "$PLAN" implement
      bash "$PF" inter-feature-reset "$PLAN"
      run_llm "Invoke the implementing skill to replan tasks for the integration failure. Plan: $PLAN"
      if [[ -n "$UNIT_CMD" ]]; then
        bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD"
      else
        bash "$PF" append-note "$PLAN" "[BLOCKED] integration: implementation bug requires unit test command — add '- Test: {cmd}' to CLAUDE.md and re-run"
        exit 1
      fi
      bash "$PF" reset-milestone "$PLAN" critic-code
      run_critic critic-code implement "Review integration bug fix implementation. Spec: ${_all_specs}. Docs: $(docs_paths "${_req_file:-}"). Plan: $PLAN. language: ${_lang}. domain_root: ${_domain_root}. infra_root: ${_infra_root}. features_root: ${_features_root}."
      bash "$PF" transition "$PLAN" integration "re-entering integration after implementation bug fix"
      ;;
    "spec gap"|"docs conflict")
      if [[ -z "$UNIT_CMD" ]]; then
        bash "$PF" append-note "$PLAN" "[BLOCKED] integration: ${category}-fix requires unit test command — add '- Test: {cmd}' to CLAUDE.md and re-run"
        exit 1
      fi
      _handle_spec_phase_rollback "$category"
      ;;
    *)
      bash "$PF" append-note "$PLAN" "[BLOCKED] integration: could not determine fix category — manual review required"
      exit 1
      ;;
  esac
done
