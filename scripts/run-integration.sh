#!/usr/bin/env bash
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

run_llm() {
  local prompt="$1"
  CLAUDE_NONINTERACTIVE=1 CLAUDE_PLAN_FILE="$PLAN" \
    claude --model opus --permission-mode auto --dangerously-skip-permissions -p "$prompt"
}

run_critic() {
  local agent="$1" phase="$2" prompt="$3"
  bash "$SCRIPTS_DIR/run-critic-loop.sh" --agent "$agent" --phase "$phase" --plan "$PLAN" --prompt "$prompt"
  return $?
}

# Step 1.5 — unit test pre-check (skipped when UNIT_CMD not configured)
if [[ -n "$UNIT_CMD" ]] && ! bash -c "$UNIT_CMD" 2>&1; then
  bash "$PF" transition "$PLAN" implement "unit tests failing at integration entry — clearing implement-phase markers"
  bash "$PF" reset-for-rollback "$PLAN" implement
  bash "$PF" transition "$PLAN" red "unit tests failing at integration entry — fresh task planning needed"
  bash "$PF" reset-milestone "$PLAN" critic-test
  bash "$PF" append-note "$PLAN" "[BLOCKED] unit tests failing before integration tests — resolve via /implementing before re-running"
  exit 1
fi

bash "$PF" transition "$PLAN" integration "starting integration test run"

attempt=0
max_attempts=2

while true; do
  if bash -c "$INTEGRATION_CMD" 2>&1; then
    bash "$PF" transition "$PLAN" done "integration tests passed"
    exit 0
  fi

  attempt=$((attempt + 1))

  # Capture test output for categorization
  test_output=$(bash -c "$INTEGRATION_CMD" 2>&1 || true)
  tail_output=$(printf '%s' "$test_output" | tail -50)

  # Count prior run blocks in plan
  run_count=$(awk '/^## Integration Failures$/{s=1;next} s&&/^## /{exit} s&&/^### Run /{c++} END{print c+0}' "$PLAN")

  # Append failure block header
  today=$(date +%Y-%m-%d)
  bash "$PF" append-note "$PLAN" "### Run $((run_count + 1)) — ${today}"

  if [[ $attempt -ge $max_attempts ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED] integration tests failed after ${max_attempts} fix attempts — manual review required"
    exit 1
  fi

  # Invoke LLM to categorize failure and write fix into plan
  run_llm "Integration test failure categorization. Plan file: $PLAN. Test output tail:
${tail_output}

Read the plan file, then under ## Integration Failures append each failing test as:
#### {test name}
Category: {docs conflict | spec gap | implementation bug}
Description: {one sentence}
Log [AUTO-CATEGORIZED-INTEGRATION] {test name}: {category} for each.
If ambiguous, append [BLOCKED] integration:{test name}: cannot determine category automatically — manual review required to ## Open Questions and stop."

  # Check for blocked marker from LLM categorization
  blocked=$(awk '/^## Open Questions/{f=1} f&&/\[BLOCKED\] integration:/{print;exit}' "$PLAN" || true)
  if [[ -n "$blocked" ]]; then exit 1; fi

  # Read category from last auto-categorized entry
  category=$(awk '/^## Integration Failures$/{f=1;next} f&&/\[AUTO-CATEGORIZED-INTEGRATION\]/{last=$0} END{print last}' "$PLAN" \
    | grep -oE 'docs conflict|spec gap|implementation bug' | tail -1 || true)

  case "$category" in
    "implementation bug")
      bash "$PF" transition "$PLAN" implement "integration failure: implementation bug"
      bash "$PF" reset-for-rollback "$PLAN" implement
      run_llm "Invoke the implementing skill to replan tasks for the integration failure. Plan: $PLAN"
      [[ -n "$UNIT_CMD" ]] && bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD"
      ;;
    "spec gap")
      bash "$PF" transition "$PLAN" spec "integration failure: spec gap"
      bash "$PF" reset-for-rollback "$PLAN" spec
      bash "$PF" reset-milestone "$PLAN" critic-spec
      bash "$PF" transition "$PLAN" red "clearing stale red/critic-test marker before restoring spec"
      bash "$PF" reset-milestone "$PLAN" critic-test
      bash "$PF" transition "$PLAN" spec "restoring spec phase for writing-spec invocation"
      run_llm "Invoke the writing-spec skill to fix the spec gap. Plan: $PLAN"
      bash "$PF" reset-milestone "$PLAN" critic-spec
      run_critic critic-spec spec "Review updated spec for integration fix. Plan: $PLAN."
      bash "$PF" transition "$PLAN" red "spec updated for integration fix — updating tests"
      bash "$PF" reset-milestone "$PLAN" critic-test
      run_llm "Invoke the writing-tests skill for the updated spec. Plan: $PLAN"
      run_critic critic-test red "Review updated tests for integration fix. Plan: $PLAN. Test command: ${UNIT_CMD}."
      bash "$PF" transition "$PLAN" implement "tests updated for integration fix — implementing"
      run_llm "Invoke the implementing skill for updated spec. Plan: $PLAN"
      [[ -n "$UNIT_CMD" ]] && bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD"
      ;;
    "docs conflict")
      bash "$PF" transition "$PLAN" spec "integration failure: docs conflict"
      bash "$PF" reset-for-rollback "$PLAN" spec
      bash "$PF" reset-milestone "$PLAN" critic-spec
      bash "$PF" transition "$PLAN" red "clearing stale red/critic-test marker before restoring spec"
      bash "$PF" reset-milestone "$PLAN" critic-test
      bash "$PF" transition "$PLAN" spec "restoring spec phase for writing-spec invocation"
      run_llm "Invoke the writing-spec skill to fix the docs conflict. Plan: $PLAN"
      bash "$PF" reset-milestone "$PLAN" critic-spec
      run_critic critic-spec spec "Review updated spec for integration fix. Plan: $PLAN."
      bash "$PF" transition "$PLAN" red "spec updated for integration fix — updating tests"
      bash "$PF" reset-milestone "$PLAN" critic-test
      run_llm "Invoke the writing-tests skill for the updated spec. Plan: $PLAN"
      run_critic critic-test red "Review updated tests for integration fix. Plan: $PLAN. Test command: ${UNIT_CMD}."
      bash "$PF" transition "$PLAN" implement "tests updated for integration fix — implementing"
      run_llm "Invoke the implementing skill for updated spec. Plan: $PLAN"
      [[ -n "$UNIT_CMD" ]] && bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD"
      ;;
    *)
      bash "$PF" append-note "$PLAN" "[BLOCKED] integration: could not determine fix category — manual review required"
      exit 1
      ;;
  esac
done
