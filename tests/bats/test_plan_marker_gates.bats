#!/usr/bin/env bats
# Regression tests for G3 (substring bypass) and G7 (agent validation).

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
  # Add a HUMAN_MUST line to the plan Open Questions
  printf '\n[BLOCKED] parse:critic-code: verdict marker missing\n' >> "$PLAN_FILE"
}

teardown() {
  teardown_plan_dir
}

@test "G3: short-marker (missing '[') does not prefix-match — HUMAN_MUST line is preserved" {
  # "BLOCKED] pars" is missing the leading '[' — with prefix matching it does not match
  # "[BLOCKED] parse:..." so the HUMAN_MUST line is preserved intact (not cleared).
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    cmd_clear_marker "'"$PLAN_FILE"'" "BLOCKED] pars"
  ' </dev/null 2>&1
  [ "$status" -eq 0 ]
  grep -qF "[BLOCKED] parse:critic-code:" "$PLAN_FILE"
}

@test "G3: exact full marker is also blocked without human capability" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    cmd_clear_marker "'"$PLAN_FILE"'" "[BLOCKED] parse:critic-code:"
  ' </dev/null 2>&1
  [ "$status" -ne 0 ]
}

@test "G7: unblock with invalid agent name is rejected" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    _validate_critic_agent "garbage" "unblock"
  ' 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown agent"* ]]
}

@test "G7: unblock with valid agent name passes validation" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    _validate_critic_agent "critic-code" "unblock" && echo OK
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "H2: cmd_clear_marker preserves BLOCKED-AMBIGUOUS when clearing unrelated marker (F8 regression)" {
  # F8 fixed TOCTOU by wrapping scan+delete in single flock subshell.
  # Verify clearing one marker does not accidentally delete BLOCKED-AMBIGUOUS.
  printf '\n[BLOCKED-AMBIGUOUS] something ambiguous\n' >> "$PLAN_FILE"
  bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    CLAUDE_PLAN_CAPABILITY=human cmd_clear_marker "'"$PLAN_FILE"'" "[BLOCKED] parse:critic-code:"
  ' 2>/dev/null || true
  grep -q 'BLOCKED-AMBIGUOUS.*something ambiguous' "$PLAN_FILE"
}

@test "H3: cmd_unblock does not delete unrelated BLOCKED lines containing agent name (F9 regression)" {
  # F9 fixed awk substring matching to use precise [BLOCKED*:agent:] pattern.
  # A line like "[BLOCKED] integration: critic-code container" should NOT be deleted.
  printf '\n[BLOCKED] coder:critic-code: actual block\n[BLOCKED] integration: critic-code container down\n' >> "$PLAN_FILE"
  bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    export CLAUDE_PLAN_FILE="'"$PLAN_FILE"'"
    CLAUDE_PLAN_CAPABILITY=human cmd_unblock critic-code
  ' 2>/dev/null || true
  grep -q 'integration: critic-code container down' "$PLAN_FILE"
}
