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

@test "G3: exact full marker is blocked by Ring C when invoked via plan-file.sh without human capability" {
  run bash -c '
    unset CLAUDE_PLAN_CAPABILITY
    bash "'"$SCRIPTS_DIR"'/plan-file.sh" clear-marker "'"$PLAN_FILE"'" "[BLOCKED] parse:critic-code:"
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

