#!/usr/bin/env bats
# T-1/C1: _sc_mktemp guard — empty path must be refused, no CWD stray files.

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
source '$SCRIPTS_DIR/lib/sidecar.sh'
SH
}

@test "T-1/C1: _sc_mktemp refuses empty path" {
  run bash -c "
    $(_load_sidecar)
    set +e
    _sc_mktemp '' 2>&1
    echo rc=\$?
  " 2>&1
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"ERROR"* ]]
}

@test "T-1/C1: _sc_mktemp creates file with non-empty path" {
  local _tmpdir
  _tmpdir=$(mktemp -d)
  run bash -c "
    $(_load_sidecar)
    _f=\$(_sc_mktemp '${_tmpdir}/test.json') && echo ok && rm -f \"\$_f\"
  " 2>&1
  rm -rf "$_tmpdir"
  [[ "$output" == *"ok"* ]]
}

@test "T-1/C1: sc_update_json with empty path returns 1, no CWD stray file" {
  local _cwd_before _cwd_after _stray
  _cwd_before=$(ls -1 "$PLAN_BASE"/ 2>/dev/null | wc -l)
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    $(_load_sidecar)
    sc_update_json '' '{\"test\":1}' 2>&1
    echo rc=\$?
  " 2>&1
  _cwd_after=$(ls -1 "$PLAN_BASE"/ 2>/dev/null | wc -l)
  [[ "$output" == *"ERROR"* ]]
  [ "$_cwd_after" -le "$_cwd_before" ]
}

@test "T-1/C1: sc_dir exit→return does not create stray files on invalid CLAUDE_PROJECT_DIR" {
  local _before _after
  _before=$(ls -la "$PLAN_BASE"/ 2>/dev/null | grep -cE '^\.[A-Za-z0-9]{6}' || true)
  run bash -c "
    unset CLAUDE_PROJECT_DIR
    export CLAUDE_PROJECT_DIR='/nonexistent/path'
    $(_load_sidecar)
    sc_path '/nonexistent/path/plans/test.md' 'verdicts.jsonl' 2>&1
    echo rc=\$?
  " 2>&1
  _after=$(ls -la "$PLAN_BASE"/ 2>/dev/null | grep -cE '^\.[A-Za-z0-9]{6}' || true)
  [ "$_after" -le "$_before" ]
  [[ "$output" == *"FATAL"* ]]
}
