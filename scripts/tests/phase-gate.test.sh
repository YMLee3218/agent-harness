#!/usr/bin/env bash
# Regression tests for phase-gate.sh
# Usage: bash phase-gate.test.sh
# Exit 0 = all tests passed; exit 1 = at least one failure.

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/phase-gate.sh"
TMPDIR_BASE=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMPDIR_BASE"; }
trap cleanup EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

check() {
  local desc="$1" want_exit="$2" got_exit="$3"
  if [ "$got_exit" -eq "$want_exit" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit $want_exit, got $got_exit)"
    FAIL=$((FAIL + 1))
  fi
}

check_stdout() {
  local desc="$1" want_nonempty="$2" got_out="$3"
  local ok=0
  if [ "$want_nonempty" = "yes" ] && [ -n "$got_out" ]; then ok=1; fi
  if [ "$want_nonempty" = "no"  ] && [ -z "$got_out" ]; then ok=1; fi
  if [ "$ok" -eq 1 ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (want_nonempty=$want_nonempty, got='$got_out')"
    FAIL=$((FAIL + 1))
  fi
}

make_plan() {
  local dir="$1" slug="$2" phase="$3"
  mkdir -p "$dir/plans"
  cat > "$dir/plans/${slug}.md" <<EOF
---
feature: $slug
---

## Vision
Test plan

## Scenarios

## Test Manifest

## Phase
$phase

## Critic Verdicts

## Open Questions
EOF
  echo "$dir/plans/${slug}.md"
}

write_input() { printf '{"tool_input":{"file_path":"%s"}}' "$1"; }
prompt_input() { printf '{"prompt":"%s","hook_event_name":"UserPromptSubmit"}' "$1"; }

# ── Test 1: write/red — source file blocked ───────────────────────────────────

T1=$(mktemp -d -p "$TMPDIR_BASE")
make_plan "$T1" "feat" "red" >/dev/null
write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T1" bash "$SCRIPT" write >/dev/null 2>&1
check "write/red: source file blocked" 2 $?

# ── Test 2: write/red — test file allowed ─────────────────────────────────────

T2=$(mktemp -d -p "$TMPDIR_BASE")
make_plan "$T2" "feat" "red" >/dev/null
write_input "tests/test_foo.py" | CLAUDE_PROJECT_DIR="$T2" bash "$SCRIPT" write >/dev/null 2>&1
check "write/red: test file allowed" 0 $?

# ── Test 3: write/green — test file blocked ───────────────────────────────────

T3=$(mktemp -d -p "$TMPDIR_BASE")
make_plan "$T3" "feat" "green" >/dev/null
write_input "tests/test_foo.py" | CLAUDE_PROJECT_DIR="$T3" bash "$SCRIPT" write >/dev/null 2>&1
check "write/green: test file blocked" 2 $?

# ── Test 4: write/no-plan — fail open ────────────────────────────────────────

T4=$(mktemp -d -p "$TMPDIR_BASE")
write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T4" bash "$SCRIPT" write >/dev/null 2>&1
check "write/no-plan: fails open" 0 $?

# ── Test 5: prompt/brainstorm — impl keyword injects context ──────────────────

T5=$(mktemp -d -p "$TMPDIR_BASE")
make_plan "$T5" "feat" "brainstorm" >/dev/null
out=$(prompt_input "implement the feature" | CLAUDE_PROJECT_DIR="$T5" bash "$SCRIPT" prompt 2>/dev/null)
check_stdout "prompt/brainstorm: impl keyword produces context" "yes" "$out"

# ── Test 6: prompt/no-keyword — no injection ─────────────────────────────────

T6=$(mktemp -d -p "$TMPDIR_BASE")
make_plan "$T6" "feat" "brainstorm" >/dev/null
out=$(prompt_input "write the spec" | CLAUDE_PROJECT_DIR="$T6" bash "$SCRIPT" prompt 2>/dev/null)
check_stdout "prompt/no-keyword: no stdout output" "no" "$out"

# ── Test 7: prompt/red — impl keyword not injected ───────────────────────────

T7=$(mktemp -d -p "$TMPDIR_BASE")
make_plan "$T7" "feat" "red" >/dev/null
out=$(prompt_input "implement the feature" | CLAUDE_PROJECT_DIR="$T7" bash "$SCRIPT" prompt 2>/dev/null)
check_stdout "prompt/red: impl keyword at red phase — no injection" "no" "$out"

# ── Test 8: write/brainstorm — source file blocked ───────────────────────────

T8=$(mktemp -d -p "$TMPDIR_BASE")
make_plan "$T8" "feat" "brainstorm" >/dev/null
write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T8" bash "$SCRIPT" write >/dev/null 2>&1
check "write/brainstorm: source file blocked" 2 $?

# ── Test 9: write/spec — source file blocked ──────────────────────────────────

T9=$(mktemp -d -p "$TMPDIR_BASE")
make_plan "$T9" "feat" "spec" >/dev/null
write_input "src/features/add-todo/handler.ts" | CLAUDE_PROJECT_DIR="$T9" bash "$SCRIPT" write >/dev/null 2>&1
check "write/spec: source file blocked" 2 $?

# ── Test 10: write/done — any file blocked ────────────────────────────────────

T10=$(mktemp -d -p "$TMPDIR_BASE")
make_plan "$T10" "feat" "done" >/dev/null
write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T10" bash "$SCRIPT" write >/dev/null 2>&1
check "write/done: source file blocked" 2 $?

# ── Test 11: write/green — spec.md NOT blocked (BDD spec, not test) ───────────

T11=$(mktemp -d -p "$TMPDIR_BASE")
make_plan "$T11" "feat" "green" >/dev/null
write_input "features/add-todo/spec.md" | CLAUDE_PROJECT_DIR="$T11" bash "$SCRIPT" write >/dev/null 2>&1
check "write/green: spec.md not blocked (BDD spec is not a test file)" 0 $?

# ── Test 12: write/green — *.spec.ts IS blocked ───────────────────────────────

T12=$(mktemp -d -p "$TMPDIR_BASE")
make_plan "$T12" "feat" "green" >/dev/null
write_input "src/features/add-todo/handler.spec.ts" | CLAUDE_PROJECT_DIR="$T12" bash "$SCRIPT" write >/dev/null 2>&1
check "write/green: .spec.ts blocked" 2 $?

# ── Test 13: write/red — uppercase phase handled correctly ────────────────────

T13=$(mktemp -d -p "$TMPDIR_BASE")
mkdir -p "$T13/plans"
cat > "$T13/plans/feat.md" <<'EOF'
## Phase
Red

## Critic Verdicts
EOF
write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T13" bash "$SCRIPT" write >/dev/null 2>&1
check "write/red (uppercase phase): source file blocked" 2 $?

# ── Test 14: write/no-plan — fail-open emits stderr warning ──────────────────

T14=$(mktemp -d -p "$TMPDIR_BASE")
stderr_out=$(write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T14" bash "$SCRIPT" write 2>&1 >/dev/null)
if printf '%s' "$stderr_out" | grep -q "no active plan file"; then
  echo "PASS: write/no-plan: fail-open emits stderr warning"
  PASS=$((PASS + 1))
else
  echo "FAIL: write/no-plan: expected stderr warning, got='$stderr_out'"
  FAIL=$((FAIL + 1))
fi

# ── Test 15: write/no-plan with PHASE_GATE_STRICT=1 — blocked ────────────────

T15=$(mktemp -d -p "$TMPDIR_BASE")
write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T15" PHASE_GATE_STRICT=1 bash "$SCRIPT" write >/dev/null 2>&1
check "write/no-plan + PHASE_GATE_STRICT=1: blocked" 2 $?

# ── Results ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
