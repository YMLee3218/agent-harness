#!/usr/bin/env bats
# T6: sidecar symlink attack prevention (sc_ensure_dir + _with_lock).

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

_load_sidecar() {
  printf '
    export CLAUDE_PROJECT_DIR="%s"
    source "%s/lib/active-plan.sh"
    source "%s/phase-policy.sh"
    source "%s/lib/sidecar.sh"
    export PLAN_FILE_SH="%s/plan-file.sh"
    source "%s/lib/plan-lib.sh"
  ' "$PLAN_BASE" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR"
}

@test "T6: sc_ensure_dir rejects sidecar dir that is a symlink" {
  local state_dir="$PLAN_DIR/test-feature.state"
  rm -rf "$state_dir"
  ln -s /tmp "$state_dir"
  run bash -c "
    $(_load_sidecar)
    sc_ensure_dir '$PLAN_FILE'
  " 2>&1
  [[ "$output" == *"symlink"* || "$output" == *"FATAL"* ]]
  [[ "$status" -ne 0 ]]
}

@test "T6: sc_ensure_dir rejects dangling symlink in sidecar dir path" {
  local state_dir="$PLAN_DIR/test-feature.state"
  rm -rf "$state_dir"
  ln -s /tmp/nonexistent_target_xyz "$state_dir"
  run bash -c "
    $(_load_sidecar)
    set +e
    sc_ensure_dir '$PLAN_FILE'
    echo rc=\$?
  " 2>&1
  # Must not succeed silently — either fails or reports symlink error
  [[ "$output" == *"symlink"* || "$output" == *"FATAL"* || "$output" == *"rc=1"* || "$status" -ne 0 ]]
}

@test "T6: _with_lock fails if lockdir path is already a symlink" {
  local lock_base="$PLAN_BASE/test.lock"
  ln -s /tmp "${lock_base}.lockdir"
  run bash -c "
    $(_load_sidecar)
    set +e
    _with_lock '$lock_base' true
    echo rc=\$?
  " 2>&1
  [[ "$output" == *"symlink"* || "$output" == *"rc=1"* ]]
}

@test "T6: _with_lock acquires lock normally when no symlink present" {
  local lock_base="$PLAN_BASE/normal.lock"
  run bash -c "
    $(_load_sidecar)
    _with_lock '$lock_base' true
    echo rc=\$?
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  [ ! -d "${lock_base}.lockdir" ]
}

@test "T6: sc_ensure_dir succeeds on normal (non-symlink) directory" {
  local state_dir="$PLAN_DIR/test-feature.state"
  rm -rf "$state_dir"
  run bash -c "
    $(_load_sidecar)
    sc_ensure_dir '$PLAN_FILE'
    echo rc=\$?
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  [ -d "$state_dir" ]
}
