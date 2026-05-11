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

@test "T2/C2: _with_lock cleans up lockdir when body succeeds" {
  local lock_base="$PLAN_BASE/test.lock"
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    _with_lock "'"$lock_base"'" true
    [ ! -d "'"${lock_base}.lockdir"'" ] && echo "lockdir_cleaned"
  ' 2>&1
  [[ "$output" == *"lockdir_cleaned"* ]]
  [ ! -d "${lock_base}.lockdir" ]
}

@test "T2/C2: _with_lock cleans up lockdir when body fails" {
  local lock_base="$PLAN_BASE/test.lock"
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    set +e
    _with_lock "'"$lock_base"'" false
    rc=$?
    [ ! -d "'"${lock_base}.lockdir"'" ] && echo "lockdir_cleaned"
    exit 0
  ' 2>&1
  [[ "$output" == *"lockdir_cleaned"* ]]
  [ ! -d "${lock_base}.lockdir" ]
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

# ── T10/L5: _with_lock preserves caller EXIT trap ─────────────────────────────

@test "T10/L5: caller EXIT trap is preserved after _with_lock completes" {
  local lock_base="$PLAN_BASE/test-exit-trap.lock"
  local sentinel="$PLAN_BASE/exit-trap-fired"
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    # Register caller EXIT trap before calling _with_lock
    trap '"'"'echo "caller_exit_fired"'"'"' EXIT
    set +e
    _with_lock "'"$lock_base"'" true
    # After _with_lock, EXIT trap must still be registered
    current_trap=$(trap -p EXIT)
    printf "%s" "$current_trap" | grep -q "caller_exit_fired" && echo "trap_preserved"
  ' 2>&1
  [[ "$output" == *"trap_preserved"* ]]
}

@test "T10/L5: _with_lock does not fire caller EXIT trap prematurely" {
  local lock_base="$PLAN_BASE/test-exit-trap2.lock"
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    fired=0
    trap '"'"'fired=1'"'"' EXIT
    set +e
    _with_lock "'"$lock_base"'" true
    # fired must still be 0 here (trap not triggered by _with_lock internals)
    echo "fired=$fired"
  ' 2>&1
  [[ "$output" == *"fired=0"* ]]
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

# ── T-1: nested lockdir cleanup on SIGINT ────────────────────────────────────

@test "T-1: nested _with_lock — both lockdirs removed after inner SIGINT" {
  local outer="$PLAN_BASE/test-outer.lock"
  local inner="$PLAN_BASE/test-inner.lock"
  # Body exits abnormally; both lockdirs must be cleaned up by _sc_lock_cleanup.
  bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    _inner() { exit 42; }
    set +e
    _with_lock "'"$outer"'" _with_lock "'"$inner"'" _inner
  ' 2>/dev/null || true
  [ ! -d "${outer}.lockdir" ]
  [ ! -d "${inner}.lockdir" ]
}

@test "T-1: nested _with_lock — outer lockdir survives while inner runs" {
  local outer="$PLAN_BASE/test-outer2.lock"
  local inner="$PLAN_BASE/test-inner2.lock"
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    _check() {
      [ -d "'"${outer}.lockdir"'" ] && echo "outer_held"
      [ -d "'"${inner}.lockdir"'" ] && echo "inner_held"
    }
    _with_lock "'"$outer"'" _with_lock "'"$inner"'" _check
  ' 2>&1
  [[ "$output" == *"outer_held"* ]]
  [[ "$output" == *"inner_held"* ]]
  [ ! -d "${outer}.lockdir" ]
  [ ! -d "${inner}.lockdir" ]
}

# ── T-2: single-quote injection prevention ───────────────────────────────────

@test "T-2: _with_lock trap does not execute injected commands via lockdir path" {
  local evil_dir
  evil_dir=$(mktemp -d "$PLAN_BASE/XXXXXX")
  local pwn_marker="$PLAN_BASE/pwn-marker"
  rm -f "$pwn_marker"
  # lockdir path contains single-quote + command; old code would execute it on trap fire.
  local evil_lock="${evil_dir}/foo';touch '${pwn_marker}';echo '.lock"
  bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    set +e
    _body() { exit 1; }
    _with_lock "'"$evil_lock"'" _body
  ' 2>/dev/null || true
  # The injected touch command must NOT have run
  [ ! -f "$pwn_marker" ]
  rm -rf "$evil_dir"
}

# ── L4: SIGINT actual fire — nested lockdir cleanup ──────────────────────────

@test "L4: nested _with_lock cleans up all lockdirs after actual SIGINT" {
  local outer="$PLAN_BASE/test-sigint-outer.lock"
  local inner="$PLAN_BASE/test-sigint-inner.lock"
  local script
  script=$(mktemp /tmp/bats_sigint_XXXXXX.sh)
  cat > "$script" <<SCRIPT
source '$SCRIPTS_DIR/lib/active-plan.sh'
source '$SCRIPTS_DIR/phase-policy.sh'
source '$SCRIPTS_DIR/lib/sidecar.sh'
export PLAN_FILE_SH='$SCRIPTS_DIR/plan-file.sh'
source '$SCRIPTS_DIR/lib/plan-lib.sh'
_inner() { kill -INT \$BASHPID; }
set +e
_with_lock '$outer' _with_lock '$inner' _inner
SCRIPT
  bash "$script" 2>/dev/null || true
  rm -f "$script"
  [ ! -d "${outer}.lockdir" ]
  [ ! -d "${inner}.lockdir" ]
}
