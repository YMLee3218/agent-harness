#!/usr/bin/env bash
# Regression tests for plan-file.sh
# Usage: bash plan-file.test.sh
# Exit 0 = all tests passed; exit 1 = at least one failure.

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/plan-file.sh"
TMPDIR_BASE=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMPDIR_BASE"; }
trap cleanup EXIT

run() {
  local desc="$1" want_exit="$2"
  shift 2
  local got_exit got_out
  got_out=$("$@" 2>/dev/null)
  got_exit=$?
  if [ "$got_exit" -eq "$want_exit" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit $want_exit, got $got_exit)"
    FAIL=$((FAIL + 1))
  fi
}

run_output() {
  local desc="$1" want_exit="$2" want_out="$3"
  shift 3
  local got_exit got_out
  got_out=$("$@" 2>/dev/null)
  got_exit=$?
  if [ "$got_exit" -eq "$want_exit" ] && [ "$got_out" = "$want_out" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit=$want_exit out='$want_out', got exit=$got_exit out='$got_out')"
    FAIL=$((FAIL + 1))
  fi
}

# ── Create test plan file helper ─────────────────────────────────────────────

make_plan() {
  local dir="$1" slug="$2" phase="$3"
  mkdir -p "$dir/plans"
  cat > "$dir/plans/${slug}.md" <<EOF
---
feature: $slug
phase: $phase
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

# ── Tests: get-phase ──────────────────────────────────────────────────────────

T1=$(mktemp -d -p "$TMPDIR_BASE")
f1=$(make_plan "$T1" "my-feature" "spec")
run_output "get-phase: spec"      0 "spec"      bash "$SCRIPT" get-phase "$f1"
run_output "get-phase: brainstorm" 0 "brainstorm" bash "$SCRIPT" get-phase "$(make_plan "$T1" "feat2" "brainstorm")"
run        "get-phase: missing file" 2              bash "$SCRIPT" get-phase "$T1/plans/nonexistent.md"

# ── Tests: set-phase ─────────────────────────────────────────────────────────

T2=$(mktemp -d -p "$TMPDIR_BASE")
f2=$(make_plan "$T2" "feature-a" "brainstorm")

run        "set-phase: brainstorm→spec valid"   0 bash "$SCRIPT" set-phase "$f2" "spec"
run_output "set-phase: reads back as spec"      0 "spec" bash "$SCRIPT" get-phase "$f2"
run        "set-phase: spec→red valid"          0 bash "$SCRIPT" set-phase "$f2" "red"
run_output "set-phase: reads back as red"       0 "red" bash "$SCRIPT" get-phase "$f2"
run        "set-phase: invalid phase"           1 bash "$SCRIPT" set-phase "$f2" "invalid"
run        "set-phase: set to done"             0 bash "$SCRIPT" set-phase "$f2" "done"
run_output "set-phase: reads back as done"      0 "done" bash "$SCRIPT" get-phase "$f2"

# ── Tests: append-verdict ────────────────────────────────────────────────────

T3=$(mktemp -d -p "$TMPDIR_BASE")
f3=$(make_plan "$T3" "feature-b" "spec")

run "append-verdict: first entry" 0 bash "$SCRIPT" append-verdict "$f3" "spec/critic-spec: PASS"

verdict_count=$(grep -c "critic-spec: PASS" "$f3" 2>/dev/null || echo 0)
if [ "$verdict_count" -ge 1 ]; then
  echo "PASS: append-verdict: entry appears in file"
  PASS=$((PASS + 1))
else
  echo "FAIL: append-verdict: entry not found in file"
  FAIL=$((FAIL + 1))
fi

run "append-verdict: second entry" 0 bash "$SCRIPT" append-verdict "$f3" "red/critic-test: PASS"

# ── Tests: find-active ───────────────────────────────────────────────────────

T4=$(mktemp -d -p "$TMPDIR_BASE")
(cd "$T4" && {
  make_plan "$T4" "done-feature" "done" >/dev/null
  sleep 0.01
  make_plan "$T4" "active-feature" "red" >/dev/null
  run "find-active: finds non-done plan" 0 bash "$SCRIPT" find-active
})

T5=$(mktemp -d -p "$TMPDIR_BASE")
(cd "$T5" && {
  make_plan "$T5" "all-done" "done" >/dev/null
  run "find-active: no active plan → exit 2" 2 bash "$SCRIPT" find-active
})

T6=$(mktemp -d -p "$TMPDIR_BASE")
(cd "$T6" && {
  run "find-active: no plans dir → exit 2" 2 bash "$SCRIPT" find-active
})

# ── Tests: record-verdict ────────────────────────────────────────────────────

T7=$(mktemp -d -p "$TMPDIR_BASE")
f7=$(make_plan "$T7" "rec-feature" "spec")
(cd "$T7" && {
  input='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"## critic-spec Review\n\n### Verdict\nPASS"}'
  printf '%s' "$input" | bash "$SCRIPT" record-verdict
  got=$?
  if [ "$got" -eq 0 ] && grep -q "critic-spec" "$f7"; then
    echo "PASS: record-verdict: PASS recorded in plan file"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict: expected exit 0 and verdict in file (got exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

T8=$(mktemp -d -p "$TMPDIR_BASE")
(cd "$T8" && {
  # Non-critic agent should be ignored (exit 0, no write)
  make_plan "$T8" "feat" "spec" >/dev/null
  input='{"hook_event_name":"SubagentStop","agent_type":"general-purpose","last_assistant_message":"Some output"}'
  printf '%s' "$input" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  echo "PASS: record-verdict: non-critic agent ignored (exit 0)"
  PASS=$((PASS + 1))
})

# ── Tests: set-phase awk bug regression (uppercase existing value) ────────────

T9=$(mktemp -d -p "$TMPDIR_BASE")
mkdir -p "$T9/plans"
cat > "$T9/plans/bug.md" <<'EOF'
## Phase
Brainstorm

## Critic Verdicts
EOF
bash "$SCRIPT" set-phase "$T9/plans/bug.md" "spec" >/dev/null 2>&1
got=$(bash "$SCRIPT" get-phase "$T9/plans/bug.md" 2>/dev/null)
if [ "$got" = "spec" ]; then
  echo "PASS: set-phase awk bug: uppercase existing value replaced correctly"
  PASS=$((PASS + 1))
else
  echo "FAIL: set-phase awk bug: expected 'spec', got '$got'"
  FAIL=$((FAIL + 1))
fi

# Ensure old value is gone and new value appears exactly once
old_count=$(grep -cE "^[Bb]rainstorm$" "$T9/plans/bug.md" 2>/dev/null; true)
new_count=$(grep -cE "^spec$" "$T9/plans/bug.md" 2>/dev/null; true)
if [ "${old_count:-1}" -eq 0 ] && [ "${new_count:-0}" -eq 1 ]; then
  echo "PASS: set-phase awk bug: no duplicate phase lines"
  PASS=$((PASS + 1))
else
  echo "FAIL: set-phase awk bug: expected old=0 new=1, got old=${old_count} new=${new_count}"
  FAIL=$((FAIL + 1))
fi

# ── Tests: get-phase with uppercase value ────────────────────────────────────

T10=$(mktemp -d -p "$TMPDIR_BASE")
mkdir -p "$T10/plans"
printf '## Phase\nRed\n\n## Critic Verdicts\n' > "$T10/plans/upper.md"
run_output "get-phase: uppercase value normalised to lowercase" 0 "red" \
  bash "$SCRIPT" get-phase "$T10/plans/upper.md"

# ── Tests: frontmatter sync after set-phase ───────────────────────────────────

T11=$(mktemp -d -p "$TMPDIR_BASE")
f11=$(make_plan "$T11" "sync-feat" "brainstorm")
bash "$SCRIPT" set-phase "$f11" "red" >/dev/null 2>&1
fm_phase=$(grep "^phase:" "$f11" | awk '{print $2}')
if [ "$fm_phase" = "red" ]; then
  echo "PASS: set-phase: frontmatter phase: field synced"
  PASS=$((PASS + 1))
else
  echo "FAIL: set-phase: frontmatter phase: not synced (got '$fm_phase')"
  FAIL=$((FAIL + 1))
fi

# ── Tests: record-verdict with bold FAIL line ─────────────────────────────────

T12=$(mktemp -d -p "$TMPDIR_BASE")
f12=$(make_plan "$T12" "bold-feat" "spec")
(cd "$T12" && {
  input='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"### Verdict\n**FAIL** — missing scenario"}'
  printf '%s' "$input" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  if grep -q "FAIL" "$f12"; then
    echo "PASS: record-verdict: bold FAIL line recorded"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict: bold FAIL line not found in plan file"
    FAIL=$((FAIL + 1))
  fi
})

# ── Results ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
