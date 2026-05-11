#!/usr/bin/env bats
# T-20/H12: dead code audit — _record_blocked_unlocked must not exist in production code.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

@test "T-20/H12: _record_blocked_unlocked has 0 occurrences in scripts/" {
  local _count
  _count=$(grep -rn '_record_blocked_unlocked' "$SCRIPTS_DIR/" 2>/dev/null | wc -l || true)
  [ "$_count" -eq 0 ]
}

@test "T-20/H12: run-critic-loop.sh has no hand-rolled dirname/basename fallback" {
  local _count
  _count=$(grep -nE 'dirname.*basename' "$SCRIPTS_DIR/run-critic-loop.sh" | wc -l || true)
  [ "$_count" -eq 0 ]
}
