#!/usr/bin/env bats
# T1: _require_phase unit tests 

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

_load_state_lib() {
  source "$SCRIPTS_DIR/lib/active-plan.sh"
  source "$SCRIPTS_DIR/phase-policy.sh"
  source "$SCRIPTS_DIR/lib/sidecar.sh"
  export PLAN_FILE_SH="$SCRIPTS_DIR/plan-file.sh"
  source "$SCRIPTS_DIR/lib/plan-lib.sh"
  source "$SCRIPTS_DIR/lib/plan-cmd-state.sh"
}

@test "T1: _require_phase returns current phase for a valid plan" {
  run bash -c '
    export CLAUDE_PROJECT_DIR="'"$PLAN_BASE"'"
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd-state.sh
    _require_phase "'"$PLAN_FILE"'" "test-label"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "implement" ]]
}

@test "T1: _require_phase dies when phase section is empty (unknown)" {
  sed -i '' 's/^implement$//' "$PLAN_FILE" 2>/dev/null || sed -i 's/^implement$//' "$PLAN_FILE"
  run bash -c '
    export CLAUDE_PROJECT_DIR="'"$PLAN_BASE"'"
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd-state.sh
    _require_phase "'"$PLAN_FILE"'" "test-label"
  ' 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"phase"* || "$output" == *"ERROR"* ]]
}

@test "T1: _require_phase dies when plan file does not exist" {
  run bash -c '
    export CLAUDE_PROJECT_DIR="'"$PLAN_BASE"'"
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd-state.sh
    _require_phase "'"$PLAN_DIR"'/nonexistent.md" "test-label"
  ' 2>&1
  [ "$status" -ne 0 ]
}
