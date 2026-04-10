#!/usr/bin/env bash
# Integration eval: tests plan-file.sh + phase-gate.sh behaviours end-to-end.
# No LLM calls — all scenarios are deterministic script-level tests.
#
# Usage: bash eval/integration/run-integration-eval.sh
# Exit 0 = all passed; exit 1 = at least one failure.

set -uo pipefail

WORKSPACE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PLAN_FILE_SH="$WORKSPACE_DIR/scripts/plan-file.sh"
PHASE_GATE_SH="$WORKSPACE_DIR/scripts/phase-gate.sh"
PASS=0
FAIL=0

tmpdir=$(mktemp -d)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# ── Test helpers ──────────────────────────────────────────────────────────────

check() {
  local desc="$1" want_exit="$2"
  shift 2
  local actual_exit=0
  "$@" >/dev/null 2>&1 || actual_exit=$?
  if [ "$actual_exit" -eq "$want_exit" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit $want_exit, got $actual_exit)"
    FAIL=$((FAIL + 1))
  fi
}

check_output() {
  local desc="$1" want_exit="$2" want_out="$3"
  shift 3
  local actual_exit=0 actual_out
  actual_out=$("$@" 2>/dev/null) || actual_exit=$?
  if [ "$actual_exit" -eq "$want_exit" ] && [ "$actual_out" = "$want_out" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit=$want_exit out='$want_out', got exit=$actual_exit out='$actual_out')"
    FAIL=$((FAIL + 1))
  fi
}

make_plan() {
  local dir="$1" slug="$2" phase="$3"
  mkdir -p "$dir/plans"
  cat > "$dir/plans/${slug}.md" <<EOF
---
feature: $slug
phase: $phase
schema: 1
---

## Vision
Integration eval test plan

## Phase
$phase

## Phase Transitions

## Critic Verdicts

## Open Questions

## Task Ledger
EOF
}

# ── Scenario 1: Plan file creation → phase transition → verification ──────────

echo "=== Scenario 1: Phase transition lifecycle ==="

dir1="$tmpdir/scenario1"
mkdir -p "$dir1"
make_plan "$dir1" "add-feature" "brainstorm"
export CLAUDE_PROJECT_DIR="$dir1"
export CLAUDE_PLAN_FILE="$dir1/plans/add-feature.md"

check_output "get-phase returns brainstorm" 0 "brainstorm" \
  bash "$PLAN_FILE_SH" get-phase "$CLAUDE_PLAN_FILE"

check "set-phase to spec" 0 \
  bash "$PLAN_FILE_SH" set-phase "$CLAUDE_PLAN_FILE" spec

check_output "get-phase returns spec after set" 0 "spec" \
  bash "$PLAN_FILE_SH" get-phase "$CLAUDE_PLAN_FILE"

check "state.json created by set-phase" 0 \
  test -f "$dir1/plans/add-feature.state.json"

check_output "state.json phase matches" 0 "spec" \
  jq -r '.phase' "$dir1/plans/add-feature.state.json"

check "set-phase to red" 0 \
  bash "$PLAN_FILE_SH" set-phase "$CLAUDE_PLAN_FILE" red

check_output "get-phase returns red" 0 "red" \
  bash "$PLAN_FILE_SH" get-phase "$CLAUDE_PLAN_FILE"

check "set-phase to green" 0 \
  bash "$PLAN_FILE_SH" set-phase "$CLAUDE_PLAN_FILE" green

check_output "get-phase returns green" 0 "green" \
  bash "$PLAN_FILE_SH" get-phase "$CLAUDE_PLAN_FILE"

check "set-phase to integration" 0 \
  bash "$PLAN_FILE_SH" set-phase "$CLAUDE_PLAN_FILE" integration

check_output "get-phase returns integration" 0 "integration" \
  bash "$PLAN_FILE_SH" get-phase "$CLAUDE_PLAN_FILE"

check "set-phase to done" 0 \
  bash "$PLAN_FILE_SH" set-phase "$CLAUDE_PLAN_FILE" done

check_output "get-phase returns done" 0 "done" \
  bash "$PLAN_FILE_SH" get-phase "$CLAUDE_PLAN_FILE"

check "invalid phase rejected" 1 \
  bash "$PLAN_FILE_SH" set-phase "$CLAUDE_PLAN_FILE" invalid

unset CLAUDE_PLAN_FILE

# ── Scenario 2: Compact simulation → context recovery ────────────────────────

echo ""
echo "=== Scenario 2: Compact simulation and context recovery ==="

dir2="$tmpdir/scenario2"
mkdir -p "$dir2"
make_plan "$dir2" "compact-test" "green"
export CLAUDE_PROJECT_DIR="$dir2"
export CLAUDE_PLAN_FILE="$dir2/plans/compact-test.md"

# Simulate pre-compact event
echo '{"compact_trigger":"context_limit"}' | bash "$PLAN_FILE_SH" flush-before-compact 2>/dev/null

check "pre-compact marker written to Open Questions" 0 \
  grep -q "\[PRE-COMPACT" "$dir2/plans/compact-test.md"

# Simulate post-compact event
bash "$PLAN_FILE_SH" log-post-compact 2>/dev/null

check "post-compact marker written to Open Questions" 0 \
  grep -q "\[POST-COMPACT" "$dir2/plans/compact-test.md"

# Verify context command outputs non-empty JSON after compact
context_output=$(bash "$PLAN_FILE_SH" context 2>/dev/null || echo "")
if printf '%s' "$context_output" | jq . >/dev/null 2>&1; then
  echo "PASS: context command outputs valid JSON after compact"
  PASS=$((PASS + 1))
else
  echo "FAIL: context command outputs valid JSON after compact (output='$context_output')"
  FAIL=$((FAIL + 1))
fi

if printf '%s' "$context_output" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q "green"; then
  echo "PASS: context includes phase info"
  PASS=$((PASS + 1))
else
  echo "FAIL: context includes phase info (output='$context_output')"
  FAIL=$((FAIL + 1))
fi

# Run gc-events and verify PRE-COMPACT is removed but POST-COMPACT kept
bash "$PLAN_FILE_SH" gc-events 2>/dev/null

check "gc-events removes PRE-COMPACT" 0 \
  bash -c '! grep -q "\[PRE-COMPACT" "'"$dir2/plans/compact-test.md"'"'

check "gc-events retains POST-COMPACT" 0 \
  grep -q "\[POST-COMPACT" "$dir2/plans/compact-test.md"

unset CLAUDE_PLAN_FILE

# ── Scenario 3: Phase gate blocks correct paths per phase ─────────────────────

echo ""
echo "=== Scenario 3: Phase gate enforcement ==="

dir3="$tmpdir/scenario3"
mkdir -p "$dir3"
make_plan "$dir3" "gate-test" "red"
export CLAUDE_PROJECT_DIR="$dir3"
export CLAUDE_PLAN_FILE="$dir3/plans/gate-test.md"
export PHASE_GATE_STRICT="1"

# In red phase: writing source files should be blocked (exit 2)
src_payload='{"tool_name":"Write","tool_input":{"file_path":"src/domain/foo.go","content":"x"}}'
check "red phase blocks src write" 2 \
  bash -c 'printf "%s" '"'"'{"tool_name":"Write","tool_input":{"file_path":"src/domain/foo.go","content":"x"}}'"'"' | bash '"$PHASE_GATE_SH"' write'

# In red phase: writing test files should be allowed (exit 0)
check "red phase allows test write" 0 \
  bash -c 'printf "%s" '"'"'{"tool_name":"Write","tool_input":{"file_path":"tests/foo_test.go","content":"x"}}'"'"' | bash '"$PHASE_GATE_SH"' write'

# Advance to green phase
bash "$PLAN_FILE_SH" set-phase "$CLAUDE_PLAN_FILE" green 2>/dev/null

# In green phase: writing test files should be blocked
check "green phase blocks test write" 2 \
  bash -c 'printf "%s" '"'"'{"tool_name":"Write","tool_input":{"file_path":"tests/foo_test.go","content":"x"}}'"'"' | bash '"$PHASE_GATE_SH"' write'

# In green phase: writing source files should be allowed
check "green phase allows src write" 0 \
  bash -c 'printf "%s" '"'"'{"tool_name":"Write","tool_input":{"file_path":"src/domain/foo.go","content":"x"}}'"'"' | bash '"$PHASE_GATE_SH"' write'

# Advance to integration phase
bash "$PLAN_FILE_SH" set-phase "$CLAUDE_PLAN_FILE" integration 2>/dev/null

# In integration phase: test files should be blocked (same as green)
check "integration phase blocks test write" 2 \
  bash -c 'printf "%s" '"'"'{"tool_name":"Write","tool_input":{"file_path":"tests/foo_test.go","content":"x"}}'"'"' | bash '"$PHASE_GATE_SH"' write'

# In integration phase: source files allowed
check "integration phase allows src write" 0 \
  bash -c 'printf "%s" '"'"'{"tool_name":"Write","tool_input":{"file_path":"src/domain/foo.go","content":"x"}}'"'"' | bash '"$PHASE_GATE_SH"' write'

unset CLAUDE_PLAN_FILE PHASE_GATE_STRICT

# ── Scenario 4: Mock critic verdict → append-verdict → phase advance ──────────

echo ""
echo "=== Scenario 4: Verdict recording and BLOCKED detection ==="

dir4="$tmpdir/scenario4"
mkdir -p "$dir4"
make_plan "$dir4" "verdict-test" "spec"
export CLAUDE_PROJECT_DIR="$dir4"
export CLAUDE_PLAN_FILE="$dir4/plans/verdict-test.md"

# Append a PASS verdict
check "append-verdict PASS" 0 \
  bash "$PLAN_FILE_SH" append-verdict "$CLAUDE_PLAN_FILE" "spec/critic-spec: PASS"

check "PASS verdict in Critic Verdicts" 0 \
  grep -q "critic-spec: PASS" "$dir4/plans/verdict-test.md"

# Append two consecutive FAIL verdicts with same category to trigger BLOCKED
check "append-verdict FAIL first" 0 \
  bash "$PLAN_FILE_SH" append-verdict "$CLAUDE_PLAN_FILE" "spec/critic-spec: FAIL [category: MISSING_SCENARIO]"

check "append-verdict FAIL second (same category)" 0 \
  bash "$PLAN_FILE_SH" append-verdict "$CLAUDE_PLAN_FILE" "spec/critic-spec: FAIL [category: MISSING_SCENARIO]"

# Simulate SubagentStop payload triggering record-verdict with BLOCKED scenario
# (We test the marker injection via append-note since record-verdict needs transcript files)
check "append-note BLOCKED marker" 0 \
  bash "$PLAN_FILE_SH" append-note "$CLAUDE_PLAN_FILE" "[BLOCKED-CATEGORY] critic-spec: MISSING_SCENARIO failed twice"

check "BLOCKED marker in Open Questions" 0 \
  grep -q "\[BLOCKED-CATEGORY\]" "$dir4/plans/verdict-test.md"

# gc-events should retain BLOCKED markers
bash "$PLAN_FILE_SH" gc-events 2>/dev/null
check "gc-events retains BLOCKED markers" 0 \
  grep -q "\[BLOCKED-CATEGORY\]" "$dir4/plans/verdict-test.md"

unset CLAUDE_PLAN_FILE

# ── Scenario 5: migrate-to-json on existing Markdown plan ────────────────────

echo ""
echo "=== Scenario 5: migrate-to-json ==="

dir5="$tmpdir/scenario5"
mkdir -p "$dir5"
make_plan "$dir5" "migrate-me" "red"
export CLAUDE_PROJECT_DIR="$dir5"
export CLAUDE_PLAN_FILE="$dir5/plans/migrate-me.md"

state_file="$dir5/plans/migrate-me.state.json"
check "no state.json before migrate" 0 \
  bash -c '[ ! -f '"$state_file"' ]'

check "migrate-to-json creates state file" 0 \
  bash "$PLAN_FILE_SH" migrate-to-json "$CLAUDE_PLAN_FILE"

check "state.json exists after migrate" 0 \
  test -f "$state_file"

check_output "state.json has correct phase" 0 "red" \
  jq -r '.phase' "$state_file"

check "migrate-to-json is idempotent" 0 \
  bash "$PLAN_FILE_SH" migrate-to-json "$CLAUDE_PLAN_FILE"

unset CLAUDE_PLAN_FILE CLAUDE_PROJECT_DIR

# ── Scenario 6: Phase gate blocks writes in brainstorm and spec phases ─────────

echo ""
echo "=== Scenario 6: Phase gate enforcement — brainstorm and spec phases ==="

dir6="$tmpdir/scenario6"
mkdir -p "$dir6"
make_plan "$dir6" "early-phase-test" "brainstorm"
export CLAUDE_PROJECT_DIR="$dir6"
export CLAUDE_PLAN_FILE="$dir6/plans/early-phase-test.md"
export PHASE_GATE_STRICT="1"

# In brainstorm phase: source writes are blocked
check "brainstorm phase blocks src write" 2 \
  bash -c 'printf "%s" '"'"'{"tool_name":"Write","tool_input":{"file_path":"src/domain/foo.go","content":"x"}}'"'"' | bash '"$PHASE_GATE_SH"' write'

# In brainstorm phase: test writes are also blocked
check "brainstorm phase blocks test write" 2 \
  bash -c 'printf "%s" '"'"'{"tool_name":"Write","tool_input":{"file_path":"tests/foo_test.go","content":"x"}}'"'"' | bash '"$PHASE_GATE_SH"' write'

# Advance to spec phase
bash "$PLAN_FILE_SH" set-phase "$CLAUDE_PLAN_FILE" spec 2>/dev/null

# In spec phase: source writes are blocked
check "spec phase blocks src write" 2 \
  bash -c 'printf "%s" '"'"'{"tool_name":"Write","tool_input":{"file_path":"src/domain/foo.go","content":"x"}}'"'"' | bash '"$PHASE_GATE_SH"' write'

# In spec phase: test writes are also blocked
check "spec phase blocks test write" 2 \
  bash -c 'printf "%s" '"'"'{"tool_name":"Write","tool_input":{"file_path":"tests/foo_test.go","content":"x"}}'"'"' | bash '"$PHASE_GATE_SH"' write'

# Spec phase: non-source, non-test writes are allowed (e.g. spec.md itself)
check "spec phase allows spec.md write" 0 \
  bash -c 'printf "%s" '"'"'{"tool_name":"Write","tool_input":{"file_path":"features/add-todo/spec.md","content":"x"}}'"'"' | bash '"$PHASE_GATE_SH"' write'

unset CLAUDE_PLAN_FILE PHASE_GATE_STRICT

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Integration eval results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
