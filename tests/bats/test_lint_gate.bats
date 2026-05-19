#!/usr/bin/env bats
# Tests for lint gate wiring: LINT_CMD extraction, make_prompt injection, _run_lint behavior.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

# ── make_prompt tests ─────────────────────────────────────────────────────────

@test "make_prompt: includes Lint command line when LINT_CMD is set" {
  local task_json; task_json='[{"id":"t1","layer":"domain","goal":"add thing","files":"src/domain/thing.py","spec":"domain/thing/spec.md","failing_test":"tests/test_thing.py::test_add","parallel":false}]'
  run bash -c '
    PLAN=/dev/null PF=/dev/null WORK_DIR=/tmp BASE_SHA=abc
    TASK_JSON='"'"''"$task_json"''"'"'
    TEST_CMD="pytest" LINT_CMD="codespell src/"
    source '"$SCRIPTS_DIR"'/lib/implement-helpers.sh
    make_prompt t1
  ' </dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Lint command: codespell src/"* ]]
}

@test "make_prompt: includes lint constraint in Hard constraints when LINT_CMD is set" {
  local task_json; task_json='[{"id":"t1","layer":"domain","goal":"add thing","files":"src/domain/thing.py","spec":"domain/thing/spec.md","failing_test":"tests/test_thing.py::test_add","parallel":false}]'
  run bash -c '
    PLAN=/dev/null PF=/dev/null WORK_DIR=/tmp BASE_SHA=abc
    TASK_JSON='"'"''"$task_json"''"'"'
    TEST_CMD="pytest" LINT_CMD="codespell src/"
    source '"$SCRIPTS_DIR"'/lib/implement-helpers.sh
    make_prompt t1
  ' </dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"run the lint command"* ]]
}

@test "make_prompt: no lint lines when LINT_CMD is empty" {
  local task_json; task_json='[{"id":"t1","layer":"domain","goal":"add thing","files":"src/domain/thing.py","spec":"domain/thing/spec.md","failing_test":"tests/test_thing.py::test_add","parallel":false}]'
  run bash -c '
    PLAN=/dev/null PF=/dev/null WORK_DIR=/tmp BASE_SHA=abc
    TASK_JSON='"'"''"$task_json"''"'"'
    TEST_CMD="pytest" LINT_CMD=""
    source '"$SCRIPTS_DIR"'/lib/implement-helpers.sh
    make_prompt t1
  ' </dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" != *"Lint command:"* ]]
  [[ "$output" != *"run the lint command"* ]]
}

# ── _run_lint tests ───────────────────────────────────────────────────────────

@test "_run_lint: returns 0 immediately when LINT_CMD is empty" {
  run bash -c '
    PLAN=/dev/null PF=/dev/null TASK_JSON="[]" WORK_DIR=/tmp BASE_SHA=abc TEST_CMD="true" LINT_CMD=""
    source '"$SCRIPTS_DIR"'/lib/implement-helpers.sh
    _run_lint t1 /tmp && echo "PASSED"
  ' </dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASSED"* ]]
}

@test "_run_lint: returns 0 when lint command succeeds" {
  run bash -c '
    PLAN=/dev/null PF=/dev/null TASK_JSON="[]" WORK_DIR=/tmp BASE_SHA=abc TEST_CMD="true" LINT_CMD="true"
    source '"$SCRIPTS_DIR"'/lib/implement-helpers.sh
    _run_lint t1 /tmp && echo "PASSED"
  ' </dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASSED"* ]]
}

@test "_run_lint: records lint-failing note and returns 1 when lint command fails" {
  setup_plan_dir
  # Add a task ledger entry for t1
  printf '\n## Task Ledger\n| id | layer | status |\n| t1 | domain | in_progress |\n' >> "$PLAN_FILE"

  local wt; wt=$(mktemp -d)
  run bash -c '
    export CLAUDE_PLAN_CAPABILITY=harness
    PLAN="'"$PLAN_FILE"'"
    PF="'"$SCRIPTS_DIR"'/plan-file.sh"
    TASK_JSON='"'"'[{"id":"t1","layer":"domain","goal":"g","files":"f","spec":"s","failing_test":"","parallel":false}]'"'"'
    WORK_DIR=/tmp BASE_SHA=abc TEST_CMD="true"
    LINT_CMD="false"
    source '"$SCRIPTS_DIR"'/lib/implement-helpers.sh
    _run_lint t1 "'"$wt"'" || echo "RETURNED_1"
  ' </dev/null 2>&1
  rm -rf "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RETURNED_1"* ]]
  grep -qF "[BLOCKED:code] coder:t1: lint-failing" "$PLAN_FILE"
  teardown_plan_dir
}
