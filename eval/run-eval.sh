#!/usr/bin/env bash
# Eval harness: runs critic agents against fixture inputs via headless Claude Code
# and compares verdicts against expected/ files.
#
# Usage: bash eval/run-eval.sh [--fixture <name>]
#
# Requires: claude CLI in PATH with headless support (-p flag)
# Exit 0 = all evals passed; exit 1 = at least one mismatch

set -euo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="$EVAL_DIR/fixtures"
EXPECTED_DIR="$EVAL_DIR/expected"
PASS=0
FAIL=0

filter="${1:-}"
if [ "$filter" = "--fixture" ]; then
  filter="${2:-}"
fi

run_eval() {
  local fixture_name="$1" agent_type="$2"
  local fixture_file="$FIXTURES_DIR/${fixture_name}"
  local expected_file="$EXPECTED_DIR/${fixture_name%.md}.verdict"

  [ -f "$fixture_file" ] || { echo "SKIP: fixture not found: $fixture_file"; return; }
  [ -f "$expected_file" ] || { echo "SKIP: expected verdict not found: $expected_file"; return; }

  local expected_verdict
  expected_verdict=$(tr -d '[:space:]' < "$expected_file")

  echo -n "eval: $fixture_name ($agent_type) ... "

  # Run critic agent headlessly; capture stdout
  local output
  output=$(claude -p "Review the following requirements/spec. Path: $fixture_file" \
             --model claude-haiku-4-5-20251001 \
             --agent "$agent_type" \
             --output-format text 2>/dev/null || echo "")

  # Extract verdict from output
  local actual_verdict=""
  if printf '%s' "$output" | grep -q '<!-- verdict: PASS -->'; then
    actual_verdict="PASS"
  elif printf '%s' "$output" | grep -q '<!-- verdict: FAIL -->'; then
    actual_verdict="FAIL"
  else
    actual_verdict="PARSE_ERROR"
  fi

  if [ "$actual_verdict" = "$expected_verdict" ]; then
    echo "PASS (got $actual_verdict)"
    PASS=$((PASS + 1))
  else
    echo "FAIL (expected $expected_verdict, got $actual_verdict)"
    FAIL=$((FAIL + 1))
    if [ -n "$output" ]; then
      echo "--- output ---"
      printf '%s\n' "$output" | tail -20
      echo "--------------"
    fi
  fi
}

# Feature critic evals
if [ -z "$filter" ] || [[ "feature-good-1" == *"$filter"* ]]; then
  run_eval "feature-good-1.md" "critic-feature"
fi
if [ -z "$filter" ] || [[ "feature-bad-layer-misassignment" == *"$filter"* ]]; then
  run_eval "feature-bad-layer-misassignment.md" "critic-feature"
fi

# Spec critic evals
if [ -z "$filter" ] || [[ "spec-good-1" == *"$filter"* ]]; then
  run_eval "spec-good-1.md" "critic-spec"
fi
if [ -z "$filter" ] || [[ "spec-bad-missing-error-scenario" == *"$filter"* ]]; then
  run_eval "spec-bad-missing-error-scenario.md" "critic-spec"
fi

echo ""
echo "Eval results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
