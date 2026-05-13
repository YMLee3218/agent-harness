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

# ── T13: E2E — init → transition → 2× PASS → converged ──────────────────────

@test "T13/e2e: init, transition, and consecutive PASS verdicts reach converged state" {
  run bash -c "
    $(_libs)
    cmd_init '$PLAN_FILE'
    echo 'init_ok'
    grep '^schema: 2' '$PLAN_FILE' && echo 'schema_ok'
    [ -d '${PLAN_FILE%.md}.state' ] && echo 'sidecar_ok'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"init_ok"* && "$output" == *"schema_ok"* && "$output" == *"sidecar_ok"* ]]

  run bash -c "
    $(_libs)
    cmd_transition '$PLAN_FILE' implement 'to implement'
    cmd_get_phase '$PLAN_FILE'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"implement"* ]]
  grep -q 'brainstorm.*implement' "$PLAN_FILE"

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
