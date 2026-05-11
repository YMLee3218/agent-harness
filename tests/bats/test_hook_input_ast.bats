#!/usr/bin/env bats
# T-23/D2: hook input AST normalization helper.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

_load_hook_input() {
  cat <<SH
source '$SCRIPTS_DIR/lib/hook-input.sh'
SH
}

@test "T-23/D2: hook_normalize_command extracts command from JSON" {
  run bash -c "
    $(_load_hook_input)
    hook_normalize_command '{\"tool_input\":{\"command\":\"echo hello\"}}' 2>&1
  " 2>&1
  [[ "$output" == *"echo hello"* ]]
}

@test "T-23/D2: hook_normalize_command returns 1 for missing command" {
  run bash -c "
    $(_load_hook_input)
    hook_normalize_command '{\"tool_input\":{}}' && echo PASS || echo FAIL
  " 2>&1
  [[ "$output" == *"FAIL"* ]]
}

@test "T-23/D2: hook_get_redirect_targets extracts redirect destination" {
  run bash -c "
    $(_load_hook_input)
    hook_get_redirect_targets 'echo x > /tmp/test.txt'
  " 2>&1
  [[ "$output" == *"/tmp/test.txt"* ]]
}

@test "T-23/D2: write-guards sources hook-input.sh" {
  grep -q 'hook-input.sh' "$SCRIPTS_DIR/pretooluse-write-guards.sh"
}
