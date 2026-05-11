#!/usr/bin/env bats
# T-25/D4: trap body invariant lint — variable interpolation in traps must be detected.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"
LINT_SCRIPT="$SCRIPTS_DIR/lib/lint-trap-bodies.sh"

setup() {
  setup_plan_dir
  FIXTURE_DIR=$(mktemp -d)
}

teardown() {
  teardown_plan_dir
  rm -rf "$FIXTURE_DIR"
}

@test "T-25/D4: lint-trap-bodies.sh exists" {
  [ -f "$LINT_SCRIPT" ]
}

@test "T-25/D4: lint passes for trap with literal (no variable)" {
  cat > "$FIXTURE_DIR/safe.sh" <<'EOF'
#!/usr/bin/env bash
trap '_cleanup' EXIT
_cleanup() { echo done; }
EOF
  run bash "$LINT_SCRIPT" "$FIXTURE_DIR" 2>&1
  [ "$status" -eq 0 ]
}

@test "T-25/D4: lint detects variable interpolation in double-quoted trap body" {
  cat > "$FIXTURE_DIR/unsafe.sh" <<'SCRIPT'
#!/usr/bin/env bash
_LOCKFILE="/tmp/test.lock"
trap "rm -f $_LOCKFILE" EXIT
SCRIPT
  run bash "$LINT_SCRIPT" "$FIXTURE_DIR" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION"* ]] || [[ "$output" == *"interpolation"* ]]
}

@test "T-25/D4: lint does not flag sidecar.sh (uses stack arrays, not interpolation)" {
  run bash "$LINT_SCRIPT" "$SCRIPTS_DIR" 2>&1
  [ "$status" -eq 0 ]
}
