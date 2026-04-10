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

T1=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T1" "feat" "red" >/dev/null
write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T1" bash "$SCRIPT" write >/dev/null 2>&1
check "write/red: source file blocked" 2 $?

# ── Test 2: write/red — test file allowed ─────────────────────────────────────

T2=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T2" "feat" "red" >/dev/null
write_input "tests/test_foo.py" | CLAUDE_PROJECT_DIR="$T2" bash "$SCRIPT" write >/dev/null 2>&1
check "write/red: test file allowed" 0 $?

# ── Test 3: write/green — test file blocked ───────────────────────────────────

T3=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T3" "feat" "green" >/dev/null
write_input "tests/test_foo.py" | CLAUDE_PROJECT_DIR="$T3" bash "$SCRIPT" write >/dev/null 2>&1
check "write/green: test file blocked" 2 $?

# ── Test 4: write/no-plan — fail open when PHASE_GATE_STRICT=0 ───────────────

T4=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T4" PHASE_GATE_STRICT=0 bash "$SCRIPT" write >/dev/null 2>&1
check "write/no-plan: fails open with PHASE_GATE_STRICT=0" 0 $?

# ── Test 5: prompt/brainstorm — impl keyword injects context ──────────────────

T5=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T5" "feat" "brainstorm" >/dev/null
out=$(prompt_input "implement the feature" | CLAUDE_PROJECT_DIR="$T5" bash "$SCRIPT" prompt 2>/dev/null)
check_stdout "prompt/brainstorm: impl keyword produces context" "yes" "$out"

# ── Test 6: prompt/brainstorm — any prompt injects phase-reminder (keyword-free) ──

T6=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T6" "feat" "brainstorm" >/dev/null
out=$(prompt_input "write the spec" | CLAUDE_PROJECT_DIR="$T6" bash "$SCRIPT" prompt 2>/dev/null)
check_stdout "prompt/brainstorm: any prompt injects phase-reminder (no keyword needed)" "yes" "$out"

# ── Test 7: prompt/red — impl keyword not injected ───────────────────────────

T7=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T7" "feat" "red" >/dev/null
out=$(prompt_input "implement the feature" | CLAUDE_PROJECT_DIR="$T7" bash "$SCRIPT" prompt 2>/dev/null)
check_stdout "prompt/red: impl keyword at red phase — no injection" "no" "$out"

# ── Test 8: write/brainstorm — source file blocked ───────────────────────────

T8=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T8" "feat" "brainstorm" >/dev/null
write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T8" bash "$SCRIPT" write >/dev/null 2>&1
check "write/brainstorm: source file blocked" 2 $?

# ── Test 9: write/spec — source file blocked ──────────────────────────────────

T9=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T9" "feat" "spec" >/dev/null
write_input "src/features/add-todo/handler.ts" | CLAUDE_PROJECT_DIR="$T9" bash "$SCRIPT" write >/dev/null 2>&1
check "write/spec: source file blocked" 2 $?

# ── Test 10: write/done — any file blocked ────────────────────────────────────

T10=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T10" "feat" "done" >/dev/null
write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T10" bash "$SCRIPT" write >/dev/null 2>&1
check "write/done: source file blocked" 2 $?

# ── Test 11: write/green — spec.md NOT blocked (BDD spec, not test) ───────────

T11=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T11" "feat" "green" >/dev/null
write_input "features/add-todo/spec.md" | CLAUDE_PROJECT_DIR="$T11" bash "$SCRIPT" write >/dev/null 2>&1
check "write/green: spec.md not blocked (BDD spec is not a test file)" 0 $?

# ── Test 12: write/green — *.spec.ts IS blocked ───────────────────────────────

T12=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T12" "feat" "green" >/dev/null
write_input "src/features/add-todo/handler.spec.ts" | CLAUDE_PROJECT_DIR="$T12" bash "$SCRIPT" write >/dev/null 2>&1
check "write/green: .spec.ts blocked" 2 $?

# ── Test 13: write/red — uppercase phase handled correctly ────────────────────

T13=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
mkdir -p "$T13/plans"
cat > "$T13/plans/feat.md" <<'EOF'
## Phase
Red

## Critic Verdicts
EOF
write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T13" bash "$SCRIPT" write >/dev/null 2>&1
check "write/red (uppercase phase): source file blocked" 2 $?

# ── Test 14: write/no-plan with PHASE_GATE_STRICT=0 — fail-open emits stderr warning ──

T14=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
stderr_out=$(write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T14" PHASE_GATE_STRICT=0 bash "$SCRIPT" write 2>&1 >/dev/null)
if printf '%s' "$stderr_out" | grep -q "no active plan file"; then
  echo "PASS: write/no-plan + PHASE_GATE_STRICT=0: fail-open emits stderr warning"
  PASS=$((PASS + 1))
else
  echo "FAIL: write/no-plan + PHASE_GATE_STRICT=0: expected stderr warning, got='$stderr_out'"
  FAIL=$((FAIL + 1))
fi

# ── Test 15: write/no-plan — default is fail-closed (PHASE_GATE_STRICT default=1) ──

T15=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T15" bash "$SCRIPT" write >/dev/null 2>&1
check "write/no-plan: default is fail-closed (exit 2)" 2 $?

# ── Test 15b: write/no-plan with PHASE_GATE_STRICT=1 explicitly — blocked ────

T15b=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T15b" PHASE_GATE_STRICT=1 bash "$SCRIPT" write >/dev/null 2>&1
check "write/no-plan + PHASE_GATE_STRICT=1: blocked" 2 $?

# ── Test 16: write/done — non-source file allowed (P0-3 regression) ──────────

T16=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T16" "feat" "done" >/dev/null
write_input "README.md" | CLAUDE_PROJECT_DIR="$T16" bash "$SCRIPT" write >/dev/null 2>&1
check "write/done: non-source file allowed" 0 $?

# ── Test 17: write/done — source file still blocked ──────────────────────────

T17=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T17" "feat" "done" >/dev/null
write_input "src/domain/foo.py" | CLAUDE_PROJECT_DIR="$T17" bash "$SCRIPT" write >/dev/null 2>&1
check "write/done: source file still blocked after done" 2 $?

# ── Test 18: write/done — test file still blocked ────────────────────────────

T18=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T18" "feat" "done" >/dev/null
write_input "tests/test_foo.py" | CLAUDE_PROJECT_DIR="$T18" bash "$SCRIPT" write >/dev/null 2>&1
check "write/done: test file still blocked after done" 2 $?

# ── Test 19: write/red — Scala source file blocked ───────────────────────────

T19=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T19" "feat" "red" >/dev/null
write_input "src/main/scala/com/example/Foo.scala" | CLAUDE_PROJECT_DIR="$T19" bash "$SCRIPT" write >/dev/null 2>&1
check "write/red: Scala source file (src/main/scala/) blocked" 2 $?

# ── Test 20: write/red — Go pkg/ source file blocked ────────────────────────

T20=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T20" "feat" "red" >/dev/null
write_input "pkg/store/user_store.go" | CLAUDE_PROJECT_DIR="$T20" bash "$SCRIPT" write >/dev/null 2>&1
check "write/red: Go pkg/ source file blocked" 2 $?

# ── Test 21: write/brainstorm — Scala source file blocked ────────────────────

T21=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T21" "feat" "brainstorm" >/dev/null
write_input "src/main/scala/com/example/Service.scala" | CLAUDE_PROJECT_DIR="$T21" bash "$SCRIPT" write >/dev/null 2>&1
check "write/brainstorm: Scala source file blocked" 2 $?

# ── Test 22: write/green — Scala source file allowed (not a test path) ───────

T22=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T22" "feat" "green" >/dev/null
write_input "src/main/scala/com/example/Foo.scala" | CLAUDE_PROJECT_DIR="$T22" bash "$SCRIPT" write >/dev/null 2>&1
check "write/green: Scala source file allowed (green phase only blocks test writes)" 0 $?

# ── Test 23: write/green — pkg/ source file allowed (not a test path) ────────

T23=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T23" "feat" "green" >/dev/null
write_input "pkg/store/user_store.go" | CLAUDE_PROJECT_DIR="$T23" bash "$SCRIPT" write >/dev/null 2>&1
check "write/green: pkg/ source file allowed (green phase only blocks test writes)" 0 $?

# ── Test 24: write/brainstorm — test file blocked (B-3) ─────────────────────
# Brainstorm phase must block test files in addition to source files.

T24=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T24" "feat" "brainstorm" >/dev/null
write_input "tests/domain/foo_test.py" | CLAUDE_PROJECT_DIR="$T24" bash "$SCRIPT" write >/dev/null 2>&1
check "write/brainstorm: test file blocked" 2 $?

# ── Test 25: write/spec — test file blocked ───────────────────────────────────

T25=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T25" "feat" "spec" >/dev/null
write_input "tests/features/add-todo.test.ts" | CLAUDE_PROJECT_DIR="$T25" bash "$SCRIPT" write >/dev/null 2>&1
check "write/spec: test file blocked" 2 $?

# ── Test 26: write/red — test file allowed in red phase ──────────────────────

T26=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T26" "feat" "red" >/dev/null
write_input "tests/domain/foo_test.py" | CLAUDE_PROJECT_DIR="$T26" bash "$SCRIPT" write >/dev/null 2>&1
check "write/red: test file allowed (Red phase is for writing tests)" 0 $?

# ── Test 27: write/brainstorm — notebook in src/ blocked (NotebookEdit) ──────

T27=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T27" "feat" "brainstorm" >/dev/null
write_input "src/domain/analysis.ipynb" | CLAUDE_PROJECT_DIR="$T27" bash "$SCRIPT" write >/dev/null 2>&1
check "write/brainstorm: notebook in src/ blocked (NotebookEdit path)" 2 $?

# ── Results ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
