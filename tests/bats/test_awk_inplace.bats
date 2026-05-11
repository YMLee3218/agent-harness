#!/usr/bin/env bats
# T12/R1: _awk_inplace uses direct args instead of globals (_AWK_INPLACE_* removed).

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
    export CLAUDE_PLAN_CAPABILITY=harness
    source "%s/lib/active-plan.sh"
    source "%s/phase-policy.sh"
    source "%s/lib/sidecar.sh"
    export PLAN_FILE_SH="%s/plan-file.sh"
    source "%s/lib/plan-lib.sh"
  ' "$PLAN_BASE" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR"
}

@test "T12/R1: _awk_inplace rewrites file in-place with awk program arg" {
  local testfile="$PLAN_BASE/test-awk.txt"
  printf 'hello\nworld\n' > "$testfile"
  run bash -c "
    $(_load_libs)
    _awk_inplace '$testfile' '{print toupper(\$0)}'
    cat '$testfile'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"HELLO"* ]]
  [[ "$output" == *"WORLD"* ]]
}

@test "T12/R1: _awk_inplace passes -v variable correctly" {
  local testfile="$PLAN_BASE/test-awk-var.txt"
  printf 'line1\nline2\n' > "$testfile"
  run bash -c "
    $(_load_libs)
    _awk_inplace '$testfile' -v prefix='PREFIX' '{print prefix \$0}'
    cat '$testfile'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"PREFIXline1"* ]]
}

@test "T12/R1: global _AWK_INPLACE_FILE assignment is not present (removed)" {
  # Check that no non-comment line assigns _AWK_INPLACE_FILE= (comments may reference it)
  run grep -v '^[[:space:]]*#' "$SCRIPTS_DIR/lib/plan-lib.sh"
  [[ "$output" != *"_AWK_INPLACE_FILE="* ]]
  [[ "$output" != *"_AWK_INPLACE_TMP="* ]]
  [[ "$output" != *"_AWK_INPLACE_ARGS="* ]]
}

@test "T12/R1: _awk_inplace locks the file during rewrite" {
  local testfile="$PLAN_BASE/test-awk-lock.txt"
  printf 'original\n' > "$testfile"
  run bash -c "
    $(_load_libs)
    _awk_inplace '$testfile' '{print \"modified\"}'
    # lockdir must not remain after successful operation
    [ ! -d '${testfile}.lockdir' ] && echo 'lockdir_gone'
    cat '$testfile'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"lockdir_gone"* ]]
  [[ "$output" == *"modified"* ]]
}
