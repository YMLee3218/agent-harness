#!/usr/bin/env bats
# T10/T13: Integration e2e — harness state machine + critic-loop plumbing.
# Tests the plan-file.sh command suite end-to-end without invoking real claude sessions.
# Ring B commands are called via sourced libs (bypasses dispatcher's PPID-chain check, intentional for tests).

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"
WS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  INTEG_BASE=$(mktemp -d)
  INTEG_PLANS="$INTEG_BASE/plans"
  mkdir -p "$INTEG_PLANS"
  export CLAUDE_PROJECT_DIR="$INTEG_BASE"
  export CLAUDE_PLAN_CAPABILITY=harness
  export PLAN_FILE="$INTEG_PLANS/test-feature.md"
}

teardown() {
  [[ -n "${INTEG_BASE:-}" ]] && rm -rf "$INTEG_BASE"
}

_libs() {
  printf 'export CLAUDE_PROJECT_DIR="%s"
    export CLAUDE_PLAN_CAPABILITY=harness
    source "%s/lib/active-plan.sh"
    source "%s/phase-policy.sh"
    source "%s/lib/sidecar.sh"
    export PLAN_FILE_SH="%s/plan-file.sh"
    source "%s/lib/plan-lib.sh"
    source "%s/lib/plan-loop-helpers.sh"
    source "%s/lib/plan-cmd.sh"' \
    "$INTEG_BASE" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR"
}

# ── Sanity: harness scripts are executable and --help-equivalent exits cleanly ──

@test "T10/smoke: run-dev-cycle.sh is a valid bash script (syntax check)" {
  run bash -n "$SCRIPTS_DIR/run-dev-cycle.sh"
  [ "$status" -eq 0 ]
}

@test "T10/smoke: run-integration.sh is a valid bash script (syntax check)" {
  run bash -n "$SCRIPTS_DIR/run-integration.sh"
  [ "$status" -eq 0 ]
}

@test "T10/smoke: run-integration.sh requires --plan and --integration-cmd args" {
  run bash "$SCRIPTS_DIR/run-integration.sh" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* || "$output" == *"plan"* ]]
}

@test "T10/smoke: plan-file.sh find-active returns rc=2 when no plans exist" {
  run bash "$SCRIPTS_DIR/plan-file.sh" find-active 2>&1
  [ "$status" -eq 2 ]
}

# ── T13: Happy-path — init, phase transitions, verdict recording ──────────────

@test "T13/happy: cmd_init creates a valid plan file with sidecar" {
  run bash -c "
    $(_libs)
    cmd_init '$PLAN_FILE'
    echo 'init_ok'
    grep '^schema: 2' '$PLAN_FILE' && echo 'schema_ok'
    [ -d '${PLAN_FILE%.md}.state' ] && echo 'sidecar_ok'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"init_ok"* ]]
  [[ "$output" == *"schema_ok"* ]]
  [[ "$output" == *"sidecar_ok"* ]]
}

@test "T13/happy: cmd_get_phase returns initial brainstorm phase" {
  bash -c "$(_libs); cmd_init '$PLAN_FILE'" 2>/dev/null
  run bash -c "$(_libs); cmd_get_phase '$PLAN_FILE'"
  [ "$status" -eq 0 ]
  [[ "$output" == "brainstorm" ]]
}

@test "T13/happy: cmd_transition moves phase and records it in plan.md" {
  bash -c "$(_libs); cmd_init '$PLAN_FILE'" 2>/dev/null
  run bash -c "
    $(_libs)
    cmd_transition '$PLAN_FILE' spec 'moving to spec phase'
    cmd_get_phase '$PLAN_FILE'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"spec"* ]]
  grep -q 'brainstorm.*spec' "$PLAN_FILE"
}

@test "T13/happy: cmd_is_converged returns not-converged for fresh plan" {
  bash -c "$(_libs); cmd_init '$PLAN_FILE'" 2>/dev/null
  bash -c "$(_libs); cmd_transition '$PLAN_FILE' spec 'to spec'" 2>/dev/null
  run bash -c "$(_libs); cmd_is_converged '$PLAN_FILE' spec critic-spec" 2>&1
  [ "$status" -ne 0 ]
}

@test "T13/happy: cmd_reset_milestone runs without error on fresh state" {
  bash -c "$(_libs); cmd_init '$PLAN_FILE'" 2>/dev/null
  bash -c "$(_libs); cmd_transition '$PLAN_FILE' spec 'to spec'" 2>/dev/null
  run bash -c "$(_libs); cmd_reset_milestone '$PLAN_FILE' critic-spec" 2>&1
  [ "$status" -eq 0 ]
}

# ── T13/fail-recover: verdict recording, blocking, and recovery ───────────────

@test "T13/fail-recover: recording a PASS verdict updates plan.md and sidecar" {
  bash -c "$(_libs); cmd_init '$PLAN_FILE'" 2>/dev/null
  bash -c "$(_libs); cmd_transition '$PLAN_FILE' implement 'to implement'" 2>/dev/null
  run bash -c "
    $(_libs)
    export CLAUDE_PLAN_FILE='$PLAN_FILE'
    printf '%s' '{\"agent_type\":\"critic-code\",\"last_assistant_message\":\"### Verdict\\n<!-- verdict: PASS -->\"}' \
      | cmd_record_verdict 2>&1
  "
  [ "$status" -eq 0 ]
  grep -q 'PASS' "$PLAN_FILE"
  [ -f "${PLAN_FILE%.md}.state/verdicts.jsonl" ]
}

@test "T13/fail-recover: FAIL verdict records in jsonl and plan.md" {
  bash -c "$(_libs); cmd_init '$PLAN_FILE'" 2>/dev/null
  bash -c "$(_libs); cmd_transition '$PLAN_FILE' implement 'to implement'" 2>/dev/null
  run bash -c "
    $(_libs)
    export CLAUDE_PLAN_FILE='$PLAN_FILE'
    set +e
    printf '%s' '{\"agent_type\":\"critic-code\",\"last_assistant_message\":\"### Verdict\\n<!-- verdict: FAIL -->\\n<!-- category: LAYER_VIOLATION -->\"}' \
      | cmd_record_verdict 2>&1
    echo \"rc=\$?\"
  "
  [[ "$output" == *"rc=1"* ]]
  grep -q 'FAIL' "$PLAN_FILE"
}

@test "T13/fail-recover: cmd_gc_sidecars runs without error" {
  bash -c "$(_libs); cmd_init '$PLAN_FILE'" 2>/dev/null
  run bash -c "$(_libs); cmd_gc_sidecars '$PLAN_FILE'" 2>&1
  [ "$status" -eq 0 ]
}

@test "T13/fail-recover: consecutive PASS verdicts reach converged state" {
  bash -c "$(_libs); cmd_init '$PLAN_FILE'" 2>/dev/null
  bash -c "$(_libs); cmd_transition '$PLAN_FILE' implement 'to implement'" 2>/dev/null
  # Record two PASS verdicts to trigger convergence (streak >= 2)
  for _ in 1 2; do
    bash -c "
      $(_libs)
      export CLAUDE_PLAN_FILE='$PLAN_FILE'
      printf '%s' '{\"agent_type\":\"critic-code\",\"last_assistant_message\":\"### Verdict\\n<!-- verdict: PASS -->\"}' \
        | cmd_record_verdict
    " 2>/dev/null || true
  done
  run bash -c "$(_libs); cmd_is_converged '$PLAN_FILE' implement critic-code" 2>&1
  [ "$status" -eq 0 ]
}
