#!/usr/bin/env bats
# T11: _decode_ansi_c unit tests — covers all supported escape classes.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

@test "T11: empty string passes through unchanged" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/pretooluse-target-blocks-lib.sh
    result=$(_decode_ansi_c "")
    echo "result=[${result}]"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "result=[]" ]]
}

@test "T11: plain ASCII string passes through unchanged" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/pretooluse-target-blocks-lib.sh
    _decode_ansi_c "hello world"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "hello world" ]]
}

@test "T11: \xNN hex escape decoded" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/pretooluse-target-blocks-lib.sh
    _decode_ansi_c "\x41\x42\x43"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "ABC" ]]
}

@test "T11: \x55 hex escape decodes to 'U' (capability bypass pattern)" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/pretooluse-target-blocks-lib.sh
    _decode_ansi_c "\x55"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "U" ]]
}

@test "T11: multiple hex escapes decoded (CLAUDE)" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/pretooluse-target-blocks-lib.sh
    _decode_ansi_c "\x43\x4c\x41\x55\x44\x45"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "CLAUDE" ]]
}

@test "T11: \$' wrapper stripped before decoding" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/pretooluse-target-blocks-lib.sh
    _decode_ansi_c $'"'"'\x41\x42\x43'"'"'
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "ABC" ]]
}

@test "T11: block_capability_spoofing blocks \x55 hex-encoded CLAUDE_PLAN_CAPABILITY" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/pretooluse-target-blocks-lib.sh
    source '"$SCRIPTS_DIR"'/pretooluse-capability-blocks.sh
    set +e
    block_capability_spoofing '"'"'CLA\x55DE_PLAN_CAPABILITY=harness'"'"'
    echo rc=$?
  ' 2>&1
  [[ "$output" == *"BLOCKED"* || "$output" == *"rc=2"* ]]
}

@test "T11: block_capability_spoofing C2a — decoded form also matched" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/pretooluse-target-blocks-lib.sh
    source '"$SCRIPTS_DIR"'/pretooluse-capability-blocks.sh
    set +e
    # The decoded form must be checked: \x55 = U → CLAUDE_PLAN_CAPABILITY
    cmd=$'"'"'CLA\x55DE_PLAN_CAPABILITY=harness'"'"'
    block_capability_spoofing "$cmd"
    echo rc=$?
  ' 2>&1
  [[ "$output" == *"BLOCKED"* || "$output" == *"rc=2"* ]]
}

@test "T11: block_capability_spoofing passes clean command (no false positive)" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/pretooluse-target-blocks-lib.sh
    source '"$SCRIPTS_DIR"'/pretooluse-capability-blocks.sh
    set +e
    block_capability_spoofing "echo hello world"
    echo rc=$?
  ' 2>&1
  [[ "$output" == *"rc=0"* ]]
}

@test "T11: block_destructive_rm blocks plain rm -rf" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/pretooluse-target-blocks-lib.sh
    source '"$SCRIPTS_DIR"'/pretooluse-blocks.sh
    set +e
    block_destructive_rm "rm -rf /tmp/test"
    echo rc=$?
  ' 2>&1
  [[ "$output" == *"BLOCKED"* || "$output" == *"rc=2"* ]]
}

@test "T11: block_pipe_to_shell blocks here-string to bash (S2a)" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/pretooluse-target-blocks-lib.sh
    source '"$SCRIPTS_DIR"'/pretooluse-write-guards.sh
    set +e
    block_pipe_to_shell "bash <<< '"'"'echo pwned'"'"'"
    echo rc=$?
  ' 2>&1
  [[ "$output" == *"BLOCKED"* || "$output" == *"rc=2"* ]]
}

@test "T11: block_pipe_to_shell blocks deno eval (S2b)" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/pretooluse-target-blocks-lib.sh
    source '"$SCRIPTS_DIR"'/pretooluse-write-guards.sh
    set +e
    block_pipe_to_shell "deno eval '"'"'console.log(1)'"'"'"
    echo rc=$?
  ' 2>&1
  [[ "$output" == *"BLOCKED"* || "$output" == *"rc=2"* ]]
}

@test "T11: block_destructive_rm blocks shred (S3b)" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/pretooluse-target-blocks-lib.sh
    source '"$SCRIPTS_DIR"'/pretooluse-blocks.sh
    set +e
    block_destructive_rm "shred -uz /important/file"
    echo rc=$?
  ' 2>&1
  [[ "$output" == *"BLOCKED"* || "$output" == *"rc=2"* ]]
}

@test "T11: block_destructive_rm blocks rm -rf \$PWD (S3a)" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/pretooluse-target-blocks-lib.sh
    source '"$SCRIPTS_DIR"'/pretooluse-blocks.sh
    set +e
    block_destructive_rm "rm -rf \$PWD"
    echo rc=$?
  ' 2>&1
  [[ "$output" == *"BLOCKED"* || "$output" == *"rc=2"* ]]
}
