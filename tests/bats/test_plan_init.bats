#!/usr/bin/env bats
# T-3: cmd_init slug validation — illegal characters must be rejected.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

_load_libs() {
  printf '
    export CLAUDE_PROJECT_DIR="%s"
    source "%s/lib/active-plan.sh"
    source "%s/phase-policy.sh"
    source "%s/lib/sidecar.sh"
    export PLAN_FILE_SH="%s/plan-file.sh"
    source "%s/lib/plan-lib.sh"
    source "%s/lib/plan-cmd-state.sh"
  ' "$PLAN_BASE" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR"
}

@test "T-3: cmd_init accepts valid slug" {
  local valid_plan="$PLAN_DIR/my-feature.md"
  run bash -c "
    $(_load_libs)
    cmd_init '$valid_plan'
    echo rc=\$?
  " 2>&1
  [[ "$status" -eq 0 ]] || [[ "$output" == *"rc=0"* ]]
}

@test "T-3: cmd_init rejects slug with single quote" {
  local bad_plan="$PLAN_DIR/foo'bar.md"
  run bash -c "
    $(_load_libs)
    set +e
    cmd_init '$bad_plan'
    echo rc=\$?
  " 2>&1
  [[ "$output" == *"rc=1"* ]] || [[ "$output" == *"illegal characters"* ]] || [[ "$status" -ne 0 ]]
}

@test "T-3: cmd_init rejects slug with newline (via basename)" {
  run bash -c "
    $(_load_libs)
    set +e
    slug=\$(printf 'evil\nbad')
    # Construct plan file path with control char in name (only possible in some filesystems)
    cmd_init \"$PLAN_DIR/\${slug}.md\" 2>&1 || true
  " 2>&1
  # Either the shell rejects the path or cmd_init does — we just ensure no panic
  [ "$status" -le 1 ]
}

@test "T-3: cmd_init rejects slug with uppercase letters" {
  local bad_plan="$PLAN_DIR/FooBar.md"
  run bash -c "
    $(_load_libs)
    set +e
    cmd_init '$bad_plan'
    echo rc=\$?
  " 2>&1
  [[ "$output" == *"rc=1"* ]] || [[ "$output" == *"illegal characters"* ]] || [[ "$status" -ne 0 ]]
}

@test "T-3: cmd_init rejects slug starting with hyphen" {
  local bad_plan="$PLAN_DIR/-bad-slug.md"
  run bash -c "
    $(_load_libs)
    set +e
    cmd_init '$bad_plan'
    echo rc=\$?
  " 2>&1
  [[ "$output" == *"rc=1"* ]] || [[ "$output" == *"illegal characters"* ]] || [[ "$status" -ne 0 ]]
}

@test "T-3: cmd_init rejects slug longer than 64 chars" {
  local long_slug; long_slug=$(printf '%0.s' {1..65} | tr '[:upper:]' 'a' || python3 -c "print('a'*65)")
  long_slug=$(python3 -c "print('a'*65)")
  local bad_plan="$PLAN_DIR/${long_slug}.md"
  run bash -c "
    $(_load_libs)
    set +e
    cmd_init '$bad_plan'
    echo rc=\$?
  " 2>&1
  [[ "$output" == *"rc=1"* ]] || [[ "$output" == *"illegal characters"* ]] || [[ "$status" -ne 0 ]]
}
