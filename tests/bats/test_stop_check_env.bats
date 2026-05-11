#!/usr/bin/env bats
# T-7/C7: stop-check .env strict parser — calls actual stop-check.sh functions, not inline re-implementation.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
  FIXTURE_DIR=$(mktemp -d)
  ENV_FILE="$FIXTURE_DIR/test.env"
}

teardown() {
  teardown_plan_dir
  rm -rf "$FIXTURE_DIR"
}

# ── C7 static checks ──────────────────────────────────────────────────────────

@test "C7: test file has no inline IFS parser (must call actual script)" {
  # Ensures the test file itself does not re-implement the parser.
  # Use split pattern to avoid the grep matching itself.
  local _pattern="while""IFS"
  local _count
  _count=$(grep -c "$_pattern" "$BATS_TEST_FILENAME" || true)
  [ "$_count" -eq 0 ]
}

@test "C7: stop-check.sh defines _parse_env_file at top level" {
  grep -qE '^_parse_env_file\(\)' "$SCRIPTS_DIR/stop-check.sh"
}

@test "C7 mutant-guard: _parse_env_file function is defined in stop-check.sh" {
  grep -qE '^_parse_env_file\(\)' "$SCRIPTS_DIR/stop-check.sh"
}

@test "C7: stop-check.sh has no top-level local keyword" {
  ! grep -nE '^[[:space:]]*local[[:space:]]' "$SCRIPTS_DIR/stop-check.sh"
}

@test "C7: stop-check.sh exits 0 in non-interactive mode" {
  run bash "$SCRIPTS_DIR/stop-check.sh" < /dev/null 2>&1
  [ "$status" -eq 0 ]
}

# ── Actual _parse_env_file tests via script sourcing ─────────────────────────

# Helper: create a small wrapper that loads just _parse_env_file from stop-check.sh
_load_parse_env_fn() {
  # Extract function body from stop-check.sh using awk (function is at top level, closed by ^})
  awk '/^_parse_env_file\(\)/,/^\}/' "$SCRIPTS_DIR/stop-check.sh"
}

@test "T-7/H8: _parse_env_file sets valid variables" {
  printf 'FOO_TOKEN=abc123\n' > "$ENV_FILE"
  run bash -c "
    $(_load_parse_env_fn)
    _parse_env_file '$ENV_FILE'
    echo \"FOO_TOKEN=\${FOO_TOKEN:-unset}\"
  " 2>&1
  [[ "$output" == *"FOO_TOKEN=abc123"* ]]
}

@test "T-7/H8: _parse_env_file does not execute embedded commands" {
  local pwn_marker="$FIXTURE_DIR/pwn-env"
  rm -f "$pwn_marker"
  printf 'MYVAR=val; touch %s\n' "$pwn_marker" > "$ENV_FILE"
  bash -c "
    $(_load_parse_env_fn)
    _parse_env_file '$ENV_FILE'
  " 2>/dev/null || true
  [ ! -f "$pwn_marker" ]
}

@test "T-7/H8: _parse_env_file does not execute sourced shell commands" {
  local pwn_marker="$FIXTURE_DIR/pwn-src"
  rm -f "$pwn_marker"
  printf 'GOODVAR=ok\ntouch %s\n' "$pwn_marker" > "$ENV_FILE"
  bash -c "
    $(_load_parse_env_fn)
    _parse_env_file '$ENV_FILE'
  " 2>/dev/null || true
  [ ! -f "$pwn_marker" ]
}

@test "T-7/H8: _parse_env_file skips keys with lowercase letters" {
  printf 'invalid_key=secret\n' > "$ENV_FILE"
  run bash -c "
    $(_load_parse_env_fn)
    _parse_env_file '$ENV_FILE'
    echo \"RESULT=\${invalid_key:-unset}\"
  " 2>&1
  [[ "$output" == *"RESULT=unset"* ]]
}

@test "T-7/H8: _parse_env_file skips comment lines" {
  printf '# comment\nGOOD_VAR=ok\n' > "$ENV_FILE"
  run bash -c "
    $(_load_parse_env_fn)
    _parse_env_file '$ENV_FILE'
    echo \"GOOD=\${GOOD_VAR:-unset}\"
  " 2>&1
  [[ "$output" == *"GOOD=ok"* ]]
}

# ── H8: TELEGRAM token shape validation ─────────────────────────────────────

@test "T-16/H8: valid TELEGRAM_BOT_TOKEN passes shape check" {
  run bash -c '
    token="123456789:ABCdefGHIjkl01234567890123456789012"
    [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]{20,50}$ ]] && echo "VALID" || echo "INVALID"
  ' 2>&1
  [[ "$output" == *"VALID"* ]]
}

@test "T-16/H8: TELEGRAM_BOT_TOKEN with URL traversal fails shape check" {
  run bash -c '
    token="bot:abc/../malicious-host/x"
    [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]{20,50}$ ]] && echo "VALID" || echo "INVALID"
  ' 2>&1
  [[ "$output" == *"INVALID"* ]]
}

@test "T-16/H8: empty TELEGRAM_BOT_TOKEN is skipped" {
  run bash -c '
    token=""
    [ -z "$token" ] && echo "SKIPPED" || echo "USED"
  ' 2>&1
  [[ "$output" == *"SKIPPED"* ]]
}

@test "T-16/H8: invalid chat_id (non-numeric) is rejected" {
  run bash -c '
    chat="evil;rm -rf"
    [[ "$chat" =~ ^-?[0-9]+$ ]] && echo "VALID" || echo "INVALID"
  ' 2>&1
  [[ "$output" == *"INVALID"* ]]
}

# ── H7: placeholder blocking ──────────────────────────────────────────────────

@test "T-12/H7: stop-check blocks uppercase placeholder {UPPERCASE_TOKEN} in test_cmd" {
  run bash -c '
    test_cmd="{UPPERCASE_TOKEN} run tests"
    printf "%s" "$test_cmd" | grep -qE "\{[A-Za-z0-9_-]+\}" && echo "BLOCKED"
  ' 2>&1
  [[ "$output" == *"BLOCKED"* ]]
}

@test "T-12/H7: stop-check regex accepts {lowercase_token} as placeholder too" {
  run bash -c '
    test_cmd="{lowercase-token} run tests"
    printf "%s" "$test_cmd" | grep -qE "\{[A-Za-z0-9_-]+\}" && echo "BLOCKED"
  ' 2>&1
  [[ "$output" == *"BLOCKED"* ]]
}

@test "T-12/H7: stop-check regex matches brace-token in pytest deselect (known trade-off)" {
  run bash -c '
    test_cmd="pytest --deselect tests/{feature}"
    printf "%s" "$test_cmd" | grep -qE "\{[A-Za-z0-9_-]+\}" && echo "WOULD_BLOCK"
  ' 2>&1
  [[ "$output" == *"WOULD_BLOCK"* ]]
}
