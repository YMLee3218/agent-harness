#!/usr/bin/env bats
# Regression tests for G12 (Ring B AND model).

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

@test "G12: CLAUDE_PLAN_CAPABILITY=harness alone is blocked without PPID match" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    CLAUDE_PLAN_CAPABILITY=harness
    require_capability test_cmd B
  ' </dev/null 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires CLAUDE_PLAN_CAPABILITY=harness"* ]]
}

@test "G12: Ring C still allows CLAUDE_PLAN_CAPABILITY=human from non-TTY" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    CLAUDE_PLAN_CAPABILITY=human
    require_capability test_cmd C && echo OK
  ' </dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

# ── Ring B gate: clear-converged / record-verdict / append-review-verdict ─────

@test "Ring-B: clear-converged is rejected without CLAUDE_PLAN_CAPABILITY=harness" {
  # All Ring B commands share this gate; clear-converged is representative.
  run bash -c '
    unset CLAUDE_PLAN_CAPABILITY
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    require_capability clear-converged B
    echo ALLOWED
  ' </dev/null 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" != *"ALLOWED"* ]]
}

