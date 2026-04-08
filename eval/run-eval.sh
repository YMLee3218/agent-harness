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
  local fixture_name="$1" agent_type="$2" prompt_prefix="${3:-Review the following. Path:}"
  local fixture_file="$FIXTURES_DIR/${fixture_name}"
  local expected_file="$EXPECTED_DIR/${fixture_name%.md}.verdict"

  [ -f "$fixture_file" ] || { echo "SKIP: fixture not found: $fixture_file"; return; }
  [ -f "$expected_file" ] || { echo "SKIP: expected verdict not found: $expected_file"; return; }

  local expected_verdict
  expected_verdict=$(tr -d '[:space:]' < "$expected_file")

  echo -n "eval: $fixture_name ($agent_type) ... "

  # Run critic agent headlessly; capture stdout.
  # --model uses the agent's own frontmatter model when --agent resolves the definition;
  # the flag here is a fallback for headless invocation without agent resolution.
  local output
  output=$(claude -p "$prompt_prefix $fixture_file" \
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
  run_eval "feature-good-1.md" "critic-feature" "Review the following requirements decomposition."
fi
if [ -z "$filter" ] || [[ "feature-bad-layer-misassignment" == *"$filter"* ]]; then
  run_eval "feature-bad-layer-misassignment.md" "critic-feature" "Review the following requirements decomposition."
fi

# Workflow output evals — feature critic applied to brainstorming outputs
if [ -z "$filter" ] || [[ "brainstorm-good" == *"$filter"* ]]; then
  run_eval "brainstorm-good.md" "critic-feature" "Review the following requirements decomposition produced by a brainstorming step."
fi
if [ -z "$filter" ] || [[ "brainstorm-bad-missing-layer" == *"$filter"* ]]; then
  run_eval "brainstorm-bad-missing-layer.md" "critic-feature" "Review the following requirements decomposition produced by a brainstorming step."
fi

# Spec critic evals
if [ -z "$filter" ] || [[ "spec-good-1" == *"$filter"* ]]; then
  run_eval "spec-good-1.md" "critic-spec" "Review the following BDD spec."
fi
if [ -z "$filter" ] || [[ "spec-bad-missing-error-scenario" == *"$filter"* ]]; then
  run_eval "spec-bad-missing-error-scenario.md" "critic-spec" "Review the following BDD spec."
fi

# Workflow output evals — spec critic applied to writing-spec outputs
if [ -z "$filter" ] || [[ "spec-bad-no-boundary" == *"$filter"* ]]; then
  run_eval "spec-bad-no-boundary.md" "critic-spec" "Review the following BDD spec produced by a writing-spec step."
fi

# Test critic evals
if [ -z "$filter" ] || [[ "test-good-1" == *"$filter"* ]]; then
  run_eval "test-good-1.md" "critic-test" "Review the following test file. The embedded Test Manifest and Test Command Result show whether tests pass or fail."
fi
if [ -z "$filter" ] || [[ "test-bad-modified-after-red" == *"$filter"* ]]; then
  run_eval "test-bad-modified-after-red.md" "critic-test" "Review the following test file. The embedded Test Manifest and Test Command Result show whether tests pass or fail."
fi

# Workflow output evals — test critic applied to writing-tests outputs
if [ -z "$filter" ] || [[ "tests-bad-passing-red" == *"$filter"* ]]; then
  run_eval "tests-bad-passing-red.md" "critic-test" "Review the following test file. The embedded Test Manifest and Test Command Result show whether tests pass or fail."
fi

# Code critic evals
if [ -z "$filter" ] || [[ "code-good-1" == *"$filter"* ]]; then
  run_eval "code-good-1.md" "critic-code" "Review the following implementation for spec compliance and layer boundary violations. The spec, docs, implementation, and layer analysis are all embedded in the file."
fi
if [ -z "$filter" ] || [[ "code-bad-layer-violation" == *"$filter"* ]]; then
  run_eval "code-bad-layer-violation.md" "critic-code" "Review the following implementation for spec compliance and layer boundary violations. The spec, docs, implementation, and layer analysis are all embedded in the file."
fi

# Skill routing isolation checks (deterministic — no LLM invocation)
# Verifies that slash-only skills declare disable-model-invocation: true so they
# cannot be auto-triggered by brainstorm-style prompts.
check_routing_isolation() {
  local skill_path="$1" skill_name="$2"
  if [ -f "$skill_path" ] && grep -q "^disable-model-invocation: true" "$skill_path"; then
    echo "routing: $skill_name has disable-model-invocation: true ... PASS"
    PASS=$((PASS + 1))
  else
    echo "routing: $skill_name missing disable-model-invocation: true ... FAIL (auto-trigger risk)"
    FAIL=$((FAIL + 1))
  fi
}

WORKSPACE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "$filter" ] || [[ "routing" == *"$filter"* ]]; then
  check_routing_isolation "$WORKSPACE_DIR/skills/running-dev-cycle/SKILL.md" "running-dev-cycle"
  check_routing_isolation "$WORKSPACE_DIR/skills/running-integration-tests/SKILL.md" "running-integration-tests"
fi

echo ""
echo "Eval results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
