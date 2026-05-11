#!/usr/bin/env bats
# T-26/D5: bash AST tokenizer — redirect target extraction.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

_load_parser() {
  cat <<SH
source '$SCRIPTS_DIR/lib/bash-parser.sh'
SH
}

@test "T-26/D5: bash-parser.sh exists" {
  [ -f "$SCRIPTS_DIR/lib/bash-parser.sh" ]
}

@test "T-26/D5: parse_bash_command detects redirect target" {
  run bash -c "
    $(_load_parser)
    parse_bash_command 'echo x > /tmp/out.txt'
  " 2>&1
  [[ "$output" == *"REDIRECT_TARGET:/tmp/out.txt"* ]] || [[ "$output" == *"/tmp/out.txt"* ]]
}

@test "T-26/D5: parse_bash_command detects append redirect" {
  run bash -c "
    $(_load_parser)
    parse_bash_command 'echo x >> /var/log/test.log'
  " 2>&1
  [[ "$output" == *"/var/log/test.log"* ]]
}

@test "T-26/D5: parse_bash_command detects pipe" {
  run bash -c "
    $(_load_parser)
    parse_bash_command 'cat foo | grep bar'
  " 2>&1
  [[ "$output" == *"PIPE"* ]]
}

@test "T-26/D5: bash_get_redirect_targets extracts paths" {
  run bash -c "
    $(_load_parser)
    bash_get_redirect_targets 'cat /dev/null > CLAUDE.md'
  " 2>&1
  [[ "$output" == *"CLAUDE.md"* ]]
}

@test "T-26/D5: pretooluse-bash.sh sources bash-parser.sh" {
  grep -q 'bash-parser.sh' "$SCRIPTS_DIR/pretooluse-bash.sh"
}
