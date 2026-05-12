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

# ── T-H5: C5 depth counter — INT/TERM/RETURN trap preservation ───────────────

@test "T-H5/C5: caller INT trap is preserved after _with_lock completes" {
  local lock_base="$PLAN_BASE/test-int-trap.lock"
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    trap '"'"'echo "int_fired"'"'"' INT
    set +e
    _with_lock "'"$lock_base"'" true
    current_trap=$(trap -p INT)
    printf "%s" "$current_trap" | grep -q "int_fired" && echo "int_trap_preserved"
  ' 2>&1
  [[ "$output" == *"int_trap_preserved"* ]]
}

@test "T-H5/C5: nested _with_lock restores outer caller EXIT trap at depth 0" {
  local lock_base1="$PLAN_BASE/test-nested1.lock"
  local lock_base2="$PLAN_BASE/test-nested2.lock"
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    trap '"'"'echo "outer_exit"'"'"' EXIT
    _inner() { _with_lock "'"$lock_base2"'" true; }
    set +e
    _with_lock "'"$lock_base1"'" _inner
    current_trap=$(trap -p EXIT)
    printf "%s" "$current_trap" | grep -q "outer_exit" && echo "outer_trap_preserved"
    echo "depth=${#_SC_LOCK_STACK[@]}"
  ' 2>&1
  [[ "$output" == *"outer_trap_preserved"* ]]
  [[ "$output" == *"depth=0"* ]]
}

