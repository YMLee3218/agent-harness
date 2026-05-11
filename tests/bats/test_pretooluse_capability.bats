#!/usr/bin/env bats
# T-9/H1: PATH injection, T-10/H2: base64 decode-eval, T-11/H3: ENV truncation, T-12/H4: lstart empty.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

_run_capability_block() {
  local cmd="$1"
  local _json
  _json=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "$cmd")")
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '$_json' \
      | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
}

# ── T-9/H1: PATH/interpreter env injection ────────────────────────────────────

@test "T-9/H1: PATH=/tmp/evil bash -c blocked in harness mode" {
  _run_capability_block 'PATH=/tmp/evil:/usr/bin bash -c echo'
  [ "$status" -eq 2 ]
  [[ "$output" =~ BLOCKED ]]
}

@test "T-9/H1: PYTHONSTARTUP=/tmp/x python3 blocked in harness mode" {
  _run_capability_block 'PYTHONSTARTUP=/tmp/x python3 script.py'
  [ "$status" -eq 2 ]
  [[ "$output" =~ BLOCKED ]]
}

@test "T-9/H1: PYTHONPATH=/tmp python3 blocked in harness mode" {
  _run_capability_block 'PYTHONPATH=/tmp python3 script.py'
  [ "$status" -eq 2 ]
  [[ "$output" =~ BLOCKED ]]
}

@test "T-9/H1: NODE_OPTIONS=--require=/tmp/x node blocked in harness mode" {
  _run_capability_block 'NODE_OPTIONS=--require=/tmp/x node app.js'
  [ "$status" -eq 2 ]
  [[ "$output" =~ BLOCKED ]]
}

@test "T-9/H1: normal command without PATH injection allowed" {
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hello\"}}' \
      | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
  [ "$status" -eq 0 ]
}

# ── T-10/H2: base64 decode-eval ──────────────────────────────────────────────

@test "T-10/H2: eval with base64 decode blocked" {
  _run_capability_block 'eval "$(base64 -d <<<Y2F0IC9ldGMvcGFzc3dk)"'
  [ "$status" -eq 2 ]
  [[ "$output" =~ BLOCKED ]]
}

@test "T-10/H2: command substitution with base64 decode blocked" {
  _run_capability_block 'cmd=$(echo Y2F0IC9ldGMvcGFzc3dk | base64 -d); eval "$cmd"'
  [ "$status" -eq 2 ]
  [[ "$output" =~ BLOCKED ]]
}

# ── T-8/C8: absolute-path shell invocation ───────────────────────────────────

@test "T-8/C8: /bin/bash -c blocked" {
  _run_capability_block '/bin/bash -c "echo evil"'
  [ "$status" -eq 2 ]
  [[ "$output" =~ BLOCKED ]]
}

@test "T-8/C8: env -i bash -ic blocked" {
  _run_capability_block 'env -i bash -ic "echo evil"'
  [ "$status" -eq 2 ]
  [[ "$output" =~ BLOCKED ]]
}

@test "T-17/H9: bash split-flag -i -c blocked" {
  _run_capability_block 'bash -i -c "echo evil"'
  [ "$status" -eq 2 ]
  [[ "$output" =~ BLOCKED ]]
}

@test "T-17/H9: /bin/bash -i -c blocked" {
  _run_capability_block '/bin/bash -i -c "echo evil"'
  [ "$status" -eq 2 ]
  [[ "$output" =~ BLOCKED ]]
}
