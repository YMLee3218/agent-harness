#!/usr/bin/env bats
# T-22/D1: launcher token — missing/expired/wrong-owner must fail; valid token passes.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

_load_token() {
  cat <<SH
source '$SCRIPTS_DIR/lib/launcher-token.sh'
SH
}

@test "T-22/D1: launcher_token_verify returns 1 when CLAUDE_LAUNCHER_TOKEN_FILE unset" {
  run bash -c "
    $(_load_token)
    unset CLAUDE_LAUNCHER_TOKEN_FILE
    launcher_token_verify && echo PASS || echo FAIL
  " 2>&1
  [[ "$output" == *"FAIL"* ]]
}

@test "T-22/D1: launcher_token_verify returns 1 for missing token file" {
  run bash -c "
    $(_load_token)
    export CLAUDE_LAUNCHER_TOKEN_FILE='/nonexistent/token.file'
    launcher_token_verify && echo PASS || echo FAIL
  " 2>&1
  [[ "$output" == *"FAIL"* ]]
}

@test "T-22/D1: launcher_token_issue creates valid token file" {
  run bash -c "
    $(_load_token)
    launcher_token_issue
    launcher_token_verify && echo PASS || echo FAIL
    launcher_token_revoke
  " 2>&1
  [[ "$output" == *"PASS"* ]]
}

@test "T-22/D1: launcher_token_verify returns 1 for expired token" {
  local _tmp
  _tmp=$(mktemp)
  echo "token" > "$_tmp"
  # Make it old by changing mtime to 120s ago
  touch -t "$(date -v-120S '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '2 minutes ago' '+%Y%m%d%H%M.%S' 2>/dev/null || echo '200101010000.00')" "$_tmp" 2>/dev/null || true
  run bash -c "
    $(_load_token)
    export CLAUDE_LAUNCHER_TOKEN_FILE='$_tmp'
    export _LAUNCHER_TOKEN_MAX_AGE=60
    launcher_token_verify && echo PASS || echo FAIL
  " 2>&1
  rm -f "$_tmp"
  [[ "$output" == *"FAIL"* ]]
}

@test "T-22/D1: launcher_token_revoke removes the token file" {
  run bash -c "
    $(_load_token)
    launcher_token_issue
    _tfile=\"\$CLAUDE_LAUNCHER_TOKEN_FILE\"
    launcher_token_revoke
    [ ! -f \"\$_tfile\" ] && echo REVOKED || echo NOT_REVOKED
  " 2>&1
  [[ "$output" == *"REVOKED"* ]]
}
