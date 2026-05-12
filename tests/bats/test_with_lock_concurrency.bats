#!/usr/bin/env bats
# _with_lock concurrency — two children competing for same lock must both run body.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

_load_sidecar() {
  cat <<SH
export CLAUDE_PROJECT_DIR='$PLAN_BASE'
source '$SCRIPTS_DIR/lib/sidecar.sh'
SH
}

@test "R11: 100-run stress — all workers complete body exactly once" {
  local _counter_file="$PLAN_BASE/stress_counter"
  printf '0' > "$_counter_file"
  local _lock_base="$PLAN_BASE/stress_lock"
  local _pids=()

  for _i in $(seq 1 100); do
    bash -c "
      export CLAUDE_PROJECT_DIR='$PLAN_BASE'
      source '$SCRIPTS_DIR/lib/sidecar.sh'
      _incr() {
        local v
        v=\$(cat '$_counter_file')
        printf '%s' \"\$(( v + 1 ))\" > '$_counter_file'
      }
      _with_lock '$_lock_base' _incr
    " &
    _pids+=($!)
  done

  for _pid in "${_pids[@]}"; do
    wait "$_pid" || true
  done

  local _result
  _result=$(cat "$_counter_file")
  [ "$_result" -eq 100 ]
}

@test "R11: two concurrent _with_lock callers both complete body" {
  local _counter_file="$PLAN_BASE/counter"
  echo 0 > "$_counter_file"
  local _lock_base="$PLAN_BASE/shared"

  # Run two background jobs both incrementing the counter under the same lock
  bash -c "
    $(_load_sidecar)
    _incr() { local v; v=\$(cat '$_counter_file'); echo \$(( v + 1 )) > '$_counter_file'; }
    _with_lock '$_lock_base' _incr
  " &
  bash -c "
    $(_load_sidecar)
    _incr() { local v; v=\$(cat '$_counter_file'); echo \$(( v + 1 )) > '$_counter_file'; }
    _with_lock '$_lock_base' _incr
  " &
  wait

  local _result
  _result=$(cat "$_counter_file")
  # Both increments must have run — result should be 2
  [ "$_result" -eq 2 ]
}

@test "R11: _with_lock lockdir is removed after contention resolves" {
  local _lock_base="$PLAN_BASE/contended"
  bash -c "
    $(_load_sidecar)
    _noop() { sleep 0.05; }
    _with_lock '$_lock_base' _noop
  " &
  bash -c "
    $(_load_sidecar)
    _noop() { sleep 0.05; }
    _with_lock '$_lock_base' _noop
  " &
  wait

  # Lockdir must be gone after both complete
  [ ! -d "${_lock_base}.lockdir" ]
}
