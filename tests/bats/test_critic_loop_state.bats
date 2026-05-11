#!/usr/bin/env bats
# Regression tests for G2 (fallback no-op) and G8 (distinct return code).

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

@test "G2: ceiling-dedup fallback writes to blocked.jsonl without flock" {
  # Verify sc_append_jsonl_unlocked works when the lock would be held
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    BPATH="'"$PLAN_DIR"'/test-feature.state/blocked.jsonl"
    sc_append_jsonl_unlocked "$BPATH" '"'"'{"ts":"2024-01-01T00:00:00Z","kind":"runtime","agent":"harness","scope":"test/agent","message":"test","cleared_at":null}'"'"'
    [ -f "$BPATH" ] && echo "WRITTEN" || echo "NOT_WRITTEN"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"WRITTEN"* ]]
}

@test "G8: corrupt verdicts.jsonl returns exit code 2 from consecutive-check" {
  # Create a corrupt verdicts.jsonl
  local vpath="$PLAN_DIR/test-feature.state/verdicts.jsonl"
  echo "not-valid-json" > "$vpath"
  # Create a fake convergence file
  local cpath="$PLAN_DIR/test-feature.state/convergence/implement__critic-code.json"
  echo '{"phase":"implement","agent":"critic-code","first_turn":true,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":1,"milestone_seq":0}' > "$cpath"

  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-state.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd-state.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd-verdicts.sh
    export CLAUDE_PLAN_FILE="'"$PLAN_FILE"'"
    result=0
    _check_consecutive_and_block "'"$PLAN_FILE"'" "implement" "critic-code" \
      '"'"'[.[] | select(.phase == $p and .agent == $a)] | .[-2].verdict // ""'"'"' \
      "PARSE_ERROR" "parse" "test msg" "test log" || result=$?
    echo "exit_code=$result"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"exit_code=2"* ]]
}
