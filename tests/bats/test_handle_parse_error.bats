#!/usr/bin/env bats
# T2: _handle_parse_error unit tests including ceiling exit 4 

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

_load_rv_libs() {
  printf '
    export CLAUDE_PROJECT_DIR="%s"
    source "%s/lib/active-plan.sh"
    source "%s/phase-policy.sh"
    source "%s/lib/sidecar.sh"
    export PLAN_FILE_SH="%s/plan-file.sh"
    source "%s/lib/plan-lib.sh"
    source "%s/lib/plan-cmd-state.sh"
    source "%s/lib/plan-loop-helpers.sh"
    source "%s/lib/plan-cmd-verdicts.sh"
    source "%s/lib/plan-cmd-notes.sh"
    source "%s/lib/plan-cmd-record-verdict.sh"
  ' "$PLAN_BASE" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR"
}

@test "T2: _handle_parse_error exits 1 on first PARSE_ERROR (no ceiling)" {
  run bash -c "
    $(_load_rv_libs)
    sc_ensure_dir '$PLAN_FILE'
    _handle_parse_error '$PLAN_FILE' 'implement' 'critic-code' \
      'test-log' 'test-block' 'test-retry'
  " 2>&1
  [ "$status" -eq 1 ]
}

@test "L5 regression: _handle_parse_error exits 1 (not 4) when ceiling is hit" {
  # L5: exit 4 withdrawn — all _handle_parse_error paths exit 1.
  # Pre-populate verdicts.jsonl to hit the ceiling (default 5)
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  # Write 5 PARSE_ERROR verdict records to trigger ceiling
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  for i in 1 2 3 4 5; do
    printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"PARSE_ERROR","category":"","ordinal":%d,"milestone_seq":0}\n' \
      "$ts" "$i" >> "$state_dir/verdicts.jsonl"
  done
  # Write convergence state to reflect ceiling_blocked
  printf '{"phase":"implement","agent":"critic-code","first_turn":true,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":5,"milestone_seq":0}\n' \
    > "$state_dir/convergence/implement__critic-code.json"

  run bash -c "
    $(_load_rv_libs)
    export CLAUDE_CRITIC_LOOP_CEILING=5
    _handle_parse_error '$PLAN_FILE' 'implement' 'critic-code' \
      'test-log' 'test-block' 'test-retry'
  " 2>&1
  # exit 4 was withdrawn (L5) — ceiling path now exits 1 like all other failure paths
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKED-CEILING"* ]]
}

@test "T2: _handle_parse_error appends PARSE_ERROR verdict to plan" {
  run bash -c "
    $(_load_rv_libs)
    sc_ensure_dir '$PLAN_FILE'
    _handle_parse_error '$PLAN_FILE' 'implement' 'critic-code' \
      'test-log' 'test-block' 'test-retry'
  " 2>&1
  # Check verdict was appended
  grep -q 'PARSE_ERROR' "$PLAN_FILE"
}

@test "T2: _handle_parse_error ordinal failure exits 1 not 4" {
  # Corrupt the verdicts.jsonl to trigger rc=2 (ordinal fail)
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  printf 'CORRUPT_JSON\n' > "$state_dir/verdicts.jsonl"

  run bash -c "
    $(_load_rv_libs)
    _handle_parse_error '$PLAN_FILE' 'implement' 'critic-code' \
      'test-log' 'test-block' 'test-retry'
  " 2>&1
  # rc=2 should still exit 1, not 4
  [ "$status" -eq 1 ]
}
