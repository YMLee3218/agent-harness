#!/usr/bin/env bats
# _with_lock EXIT trap regression.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

@test "T2/C2: _with_lock cleans up lockdir when body calls exit" {
  local lock_base="$PLAN_BASE/test-exit.lock"
  # Body calls exit — lockdir must still be removed via EXIT trap
  bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    _body() { exit 42; }
    set +e
    _with_lock "'"$lock_base"'" _body
  ' 2>/dev/null || true
  # Lockdir must not remain after body exit
  [ ! -d "${lock_base}.lockdir" ]
}

@test "T2/C2: _with_lock returns body exit code" {
  local lock_base="$PLAN_BASE/test-rc.lock"
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    set +e
    _with_lock "'"$lock_base"'" bash -c "exit 7"
    echo "rc=$?"
  ' 2>&1
  [[ "$output" == *"rc=7"* ]]
}


