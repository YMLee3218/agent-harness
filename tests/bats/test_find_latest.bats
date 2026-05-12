#!/usr/bin/env bats
# T-19/H11: cmd_find_latest — POSIX mtime sort, no ls -t parsing.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

@test "T-19/H11: _find_latest_by_mtime uses find, not ls -t command" {
  # Must not use ls -t as a command (not as a comment)
  ! grep -nE '^\s*[^#].*\bls\s+-t\b' "$SCRIPTS_DIR/lib/plan-cmd-state.sh"
}

@test "T-19/H11: cmd_find_latest returns newest plan by mtime" {
  local _tmp
  _tmp=$(mktemp -d)
  mkdir -p "$_tmp/plans"
  echo '---' > "$_tmp/plans/old-plan.md"
  touch -t 202001010000 "$_tmp/plans/old-plan.md"
  echo '---' > "$_tmp/plans/new-plan.md"
  touch -t 202001020000 "$_tmp/plans/new-plan.md"
  run bash -c "
    export CLAUDE_PROJECT_DIR='$_tmp'
    source '$SCRIPTS_DIR/lib/plan-cmd-state.sh' 2>/dev/null || \
      source '$SCRIPTS_DIR/lib/sidecar.sh' 2>/dev/null
    source '$SCRIPTS_DIR/lib/plan-cmd-state.sh'
    cmd_find_latest 2>&1
  " 2>&1
  rm -rf "$_tmp"
  # Should return new-plan.md, not old-plan.md
  [[ "$output" == *"new-plan.md"* ]]
}

@test "T-19/H11: cmd_find_latest returns rc=2 when plans/ empty" {
  local _empty_base
  _empty_base=$(mktemp -d)
  mkdir -p "$_empty_base/plans"
  run bash -c "
    export CLAUDE_PROJECT_DIR='$_empty_base'
    source '$SCRIPTS_DIR/lib/sidecar.sh'
    source '$SCRIPTS_DIR/lib/active-plan.sh'
    source '$SCRIPTS_DIR/phase-policy.sh'
    source '$SCRIPTS_DIR/lib/plan-lib.sh'
    source '$SCRIPTS_DIR/lib/plan-cmd-state.sh'
    set +e
    cmd_find_latest
    echo rc=\$?
  " 2>&1
  rm -rf "$_empty_base"
  [[ "$output" == *"rc=2"* ]]
}
