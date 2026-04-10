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

T1=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f1=$(make_plan "$T1" "my-feature" "spec")
run_output "get-phase: spec"      0 "spec"      bash "$SCRIPT" get-phase "$f1"
run_output "get-phase: brainstorm" 0 "brainstorm" bash "$SCRIPT" get-phase "$(make_plan "$T1" "feat2" "brainstorm")"
run        "get-phase: missing file" 2              bash "$SCRIPT" get-phase "$T1/plans/nonexistent.md"

# ── Tests: set-phase ─────────────────────────────────────────────────────────

T2=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f2=$(make_plan "$T2" "feature-a" "brainstorm")

run        "set-phase: brainstorm→spec valid"   0 bash "$SCRIPT" set-phase "$f2" "spec"
run_output "set-phase: reads back as spec"      0 "spec" bash "$SCRIPT" get-phase "$f2"
run        "set-phase: spec→red valid"          0 bash "$SCRIPT" set-phase "$f2" "red"
run_output "set-phase: reads back as red"       0 "red" bash "$SCRIPT" get-phase "$f2"
run        "set-phase: invalid phase"           1 bash "$SCRIPT" set-phase "$f2" "invalid"
run        "set-phase: refactor rejected (removed from FSM)" 1 bash "$SCRIPT" set-phase "$f2" "refactor"
run        "set-phase: set to done"             0 bash "$SCRIPT" set-phase "$f2" "done"
run_output "set-phase: reads back as done"      0 "done" bash "$SCRIPT" get-phase "$f2"

# ── Tests: append-verdict ────────────────────────────────────────────────────

T3=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
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

T4=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T4" && {
  make_plan "$T4" "done-feature" "done" >/dev/null
  sleep 0.01
  make_plan "$T4" "active-feature" "red" >/dev/null
  run "find-active: finds non-done plan" 0 bash "$SCRIPT" find-active
})

T5=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T5" && {
  make_plan "$T5" "all-done" "done" >/dev/null
  run "find-active: no active plan → exit 2" 2 bash "$SCRIPT" find-active
})

T6=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T6" && {
  run "find-active: no plans dir → exit 2" 2 bash "$SCRIPT" find-active
})

# ── Tests: record-verdict ────────────────────────────────────────────────────

T7=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f7=$(make_plan "$T7" "rec-feature" "spec")
(cd "$T7" && {
  # Message includes mandatory <!-- verdict: PASS --> marker (jq interprets \n as newline)
  input='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"## critic-spec Review\n\n### Verdict\nPASS\n<!-- verdict: PASS -->"}'
  printf '%s' "$input" | bash "$SCRIPT" record-verdict
  got=$?
  if [ "$got" -eq 0 ] && grep -q "critic-spec: PASS" "$f7"; then
    echo "PASS: record-verdict: PASS marker recorded in plan file"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict: expected exit 0 and PASS in file (got exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

T8=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T8" && {
  # Non-critic agent should be ignored (exit 0, no write)
  make_plan "$T8" "feat" "spec" >/dev/null
  input='{"hook_event_name":"SubagentStop","agent_type":"general-purpose","last_assistant_message":"Some output"}'
  printf '%s' "$input" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  echo "PASS: record-verdict: non-critic agent ignored (exit 0)"
  PASS=$((PASS + 1))
})

# ── Tests: set-phase awk bug regression (uppercase existing value) ────────────

T9=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
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

T10=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
mkdir -p "$T10/plans"
printf '## Phase\nRed\n\n## Critic Verdicts\n' > "$T10/plans/upper.md"
run_output "get-phase: uppercase value normalised to lowercase" 0 "red" \
  bash "$SCRIPT" get-phase "$T10/plans/upper.md"

# ── Tests: frontmatter sync after set-phase ───────────────────────────────────

T11=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
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

# ── Tests: record-verdict with bold FAIL line (no marker) → PARSE_ERROR ───────
# Legacy format (bold **FAIL** without marker) is intentionally not supported.
# Without the <!-- verdict: FAIL --> marker the result must be PARSE_ERROR.

T12=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f12=$(make_plan "$T12" "bold-feat" "spec")
(cd "$T12" && {
  input='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"### Verdict\n**FAIL** — missing scenario"}'
  printf '%s' "$input" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  if grep -q "PARSE_ERROR" "$f12"; then
    echo "PASS: record-verdict: bold FAIL without marker → PARSE_ERROR"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict: expected PARSE_ERROR for bold FAIL without marker"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: record-verdict strict marker parsing ──────────────────────────────

# Case 1: PASS marker present → recorded as PASS
T13=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f13=$(make_plan "$T13" "marker-pass" "spec")
(cd "$T13" && {
  input='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"### Verdict\nPASS\n<!-- verdict: PASS -->"}'
  printf '%s' "$input" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  if grep -q "spec/critic-spec: PASS" "$f13"; then
    echo "PASS: record-verdict strict: PASS marker recorded correctly"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict strict: PASS marker not found in plan file"
    FAIL=$((FAIL + 1))
  fi
})

# Case 2: FAIL marker present → recorded as FAIL
T14=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f14=$(make_plan "$T14" "marker-fail" "spec")
(cd "$T14" && {
  input='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"### Verdict\nFAIL — missing scenario\n<!-- verdict: FAIL -->"}'
  printf '%s' "$input" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  if grep -q "spec/critic-spec: FAIL" "$f14"; then
    echo "PASS: record-verdict strict: FAIL marker recorded correctly"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict strict: FAIL marker not found in plan file"
    FAIL=$((FAIL + 1))
  fi
})

# Case 3: No marker → recorded as PARSE_ERROR with stderr warning
T15=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f15=$(make_plan "$T15" "marker-missing" "spec")
(cd "$T15" && {
  input='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"### Verdict\nPASS"}'
  stderr_out=$(printf '%s' "$input" | bash "$SCRIPT" record-verdict 2>&1 >/dev/null)
  if grep -q "PARSE_ERROR" "$f15" && printf '%s' "$stderr_out" | grep -q "missing verdict marker"; then
    echo "PASS: record-verdict strict: missing marker → PARSE_ERROR in file + stderr warning"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict strict: missing marker case failed (file has PARSE_ERROR=$(grep -c PARSE_ERROR "$f15" 2>/dev/null), stderr='$stderr_out')"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: record-verdict PARSE_ERROR exits with code 2 ─────────────────────
# Missing verdict marker must cause exit 2 so the SubagentStop hook signals failure.

T16=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f16=$(make_plan "$T16" "exit2-feat" "spec")
(cd "$T16" && {
  input='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"No marker here"}'
  printf '%s' "$input" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 2 ] && grep -q "PARSE_ERROR" "$f16"; then
    echo "PASS: record-verdict: missing marker → exit 2 + PARSE_ERROR in file"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict: expected exit 2 + PARSE_ERROR (got exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: find-active honours CLAUDE_PLAN_FILE env override ─────────────────

T17=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f17a=$(make_plan "$T17" "env-feat" "green")
make_plan "$T17" "other-feat" "brainstorm" >/dev/null
(cd "$T17" && {
  got=$(CLAUDE_PLAN_FILE="$f17a" bash "$SCRIPT" find-active 2>/dev/null)
  if [ "$got" = "$f17a" ]; then
    echo "PASS: find-active: CLAUDE_PLAN_FILE env override respected"
    PASS=$((PASS + 1))
  else
    echo "FAIL: find-active: expected '$f17a', got '$got'"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: context subcommand emits additionalContext JSON ───────────────────

T18=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T18" "ctx-feat" "green" >/dev/null
(cd "$T18" && {
  out=$(bash "$SCRIPT" context 2>/dev/null)
  if printf '%s' "$out" | grep -q '"hookSpecificOutput"' && \
     printf '%s' "$out" | grep -q '"hookEventName"' && \
     printf '%s' "$out" | grep -q '"additionalContext"' && \
     printf '%s' "$out" | grep -q 'green'; then
    echo "PASS: context: outputs canonical hookSpecificOutput JSON with current phase"
    PASS=$((PASS + 1))
  else
    echo "FAIL: context: expected hookSpecificOutput JSON with additionalContext and phase (got='$out')"
    FAIL=$((FAIL + 1))
  fi
})

T19=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T19" && {
  # No plan → exit 0, no output
  out=$(bash "$SCRIPT" context 2>/dev/null)
  if [ $? -eq 0 ] && [ -z "$out" ]; then
    echo "PASS: context: no active plan → exit 0, no output"
    PASS=$((PASS + 1))
  else
    echo "FAIL: context: expected exit 0 + empty output when no plan (got='$out')"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: record-verdict via transcript_path (real SubagentStop schema) ─────
# Claude Code SubagentStop payload: {session_id, transcript_path, stop_hook_active}
# transcript file is JSON Lines with {type:"assistant", message:{content:[{type:"text",text:"..."}]}}

T20=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f20=$(make_plan "$T20" "transcript-pass" "spec")
(cd "$T20" && {
  transcript_file="$TMPDIR_BASE/transcript_pass_$$.jsonl"
  printf '%s\n' \
    '{"type":"system","message":"session start"}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"## critic-spec Review\n\n### Verdict\nPASS\n<!-- verdict: PASS -->"}]}}' \
    > "$transcript_file"
  input="{\"session_id\":\"test-123\",\"transcript_path\":\"${transcript_file}\",\"stop_hook_active\":false,\"agent_type\":\"critic-spec\"}"
  printf '%s' "$input" | bash "$SCRIPT" record-verdict
  got=$?
  if [ "$got" -eq 0 ] && grep -q "critic-spec: PASS" "$f20"; then
    echo "PASS: record-verdict: transcript_path strategy extracts PASS verdict"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict: transcript_path strategy failed (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

T21=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f21=$(make_plan "$T21" "transcript-fail" "spec")
(cd "$T21" && {
  transcript_file="$TMPDIR_BASE/transcript_fail_$$.jsonl"
  printf '%s\n' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"### Verdict\nFAIL — missing scenario\n<!-- verdict: FAIL -->"}]}}' \
    > "$transcript_file"
  input="{\"session_id\":\"test-456\",\"transcript_path\":\"${transcript_file}\",\"stop_hook_active\":false,\"agent_type\":\"critic-spec\"}"
  printf '%s' "$input" | bash "$SCRIPT" record-verdict
  got=$?
  if [ "$got" -eq 0 ] && grep -q "critic-spec: FAIL" "$f21"; then
    echo "PASS: record-verdict: transcript_path strategy extracts FAIL verdict"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict: transcript_path FAIL strategy failed (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

T22=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f22=$(make_plan "$T22" "transcript-no-marker" "spec")
(cd "$T22" && {
  transcript_file="$TMPDIR_BASE/transcript_nomarker_$$.jsonl"
  printf '%s\n' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"### Verdict\nPASS (no marker)"}]}}' \
    > "$transcript_file"
  input="{\"session_id\":\"test-789\",\"transcript_path\":\"${transcript_file}\",\"stop_hook_active\":false,\"agent_type\":\"critic-spec\"}"
  printf '%s' "$input" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 2 ] && grep -q "PARSE_ERROR" "$f22" && grep -q "BLOCKED" "$f22"; then
    echo "PASS: record-verdict: transcript_path missing marker → exit 2, PARSE_ERROR + BLOCKED in plan"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict: transcript_path missing marker case failed (exit=$got, PARSE_ERROR=$(grep -c PARSE_ERROR "$f22" 2>/dev/null), BLOCKED=$(grep -c BLOCKED "$f22" 2>/dev/null))"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: add-task ──────────────────────────────────────────────────────────

T23=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f23=$(make_plan "$T23" "task-ledger-feat" "green")

run "add-task: creates Task Ledger section" 0 bash "$SCRIPT" add-task "$f23" "task-1" "domain"
if grep -q "## Task Ledger" "$f23" && grep -q "task-1" "$f23"; then
  echo "PASS: add-task: Task Ledger section and row created"
  PASS=$((PASS + 1))
else
  echo "FAIL: add-task: Task Ledger section or row missing"
  FAIL=$((FAIL + 1))
fi

run "add-task: second row appended" 0 bash "$SCRIPT" add-task "$f23" "task-2" "small-feature"
if grep -q "task-2" "$f23"; then
  echo "PASS: add-task: second row appended"
  PASS=$((PASS + 1))
else
  echo "FAIL: add-task: second row missing"
  FAIL=$((FAIL + 1))
fi

# ── Tests: update-task ────────────────────────────────────────────────────────

T24=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f24=$(make_plan "$T24" "update-task-feat" "green")
bash "$SCRIPT" add-task "$f24" "task-1" "domain" >/dev/null
bash "$SCRIPT" add-task "$f24" "task-2" "infrastructure" >/dev/null

run "update-task: set in_progress" 0 bash "$SCRIPT" update-task "$f24" "task-1" "in_progress"
if grep -q "in_progress" "$f24"; then
  echo "PASS: update-task: in_progress status set"
  PASS=$((PASS + 1))
else
  echo "FAIL: update-task: in_progress status not found"
  FAIL=$((FAIL + 1))
fi

run "update-task: set completed with sha" 0 bash "$SCRIPT" update-task "$f24" "task-1" "completed" "abc1234"
if grep -q "completed" "$f24" && grep -q "abc1234" "$f24"; then
  echo "PASS: update-task: completed + commit-sha recorded"
  PASS=$((PASS + 1))
else
  echo "FAIL: update-task: completed or commit-sha not found"
  FAIL=$((FAIL + 1))
fi

run "update-task: invalid status rejected" 1 bash "$SCRIPT" update-task "$f24" "task-2" "flying"

# ── Tests: record-verdict with category ──────────────────────────────────────

T25=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f25=$(make_plan "$T25" "category-feat" "spec")
(cd "$T25" && {
  input='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"### Verdict\nFAIL — missing scenario\n<!-- verdict: FAIL -->\n<!-- category: MISSING_SCENARIO -->"}'
  printf '%s' "$input" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  if grep -q "FAIL \[category: MISSING_SCENARIO\]" "$f25"; then
    echo "PASS: record-verdict: FAIL category recorded in verdict label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict: FAIL category not found in verdict label"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: record-verdict consecutive same-category FAIL → BLOCKED-CATEGORY ──

T26=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f26=$(make_plan "$T26" "consec-fail-feat" "spec")
(cd "$T26" && {
  # First FAIL with MISSING_SCENARIO
  input1='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"### Verdict\nFAIL — missing scenario\n<!-- verdict: FAIL -->\n<!-- category: MISSING_SCENARIO -->"}'
  printf '%s' "$input1" | bash "$SCRIPT" record-verdict >/dev/null 2>&1

  # Second FAIL with same category → should write BLOCKED-CATEGORY
  input2='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"### Verdict\nFAIL — still missing scenario\n<!-- verdict: FAIL -->\n<!-- category: MISSING_SCENARIO -->"}'
  printf '%s' "$input2" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 1 ] && grep -q "BLOCKED-CATEGORY" "$f26"; then
    echo "PASS: record-verdict: consecutive same-category FAIL → exit 1 + BLOCKED-CATEGORY in plan"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict: expected exit 1 + BLOCKED-CATEGORY (exit=$got, BLOCKED=$(grep -c BLOCKED-CATEGORY "$f26" 2>/dev/null))"
    FAIL=$((FAIL + 1))
  fi
})

# Different category on second FAIL must NOT block
T27=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f27=$(make_plan "$T27" "diff-category-feat" "spec")
(cd "$T27" && {
  input1='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"### Verdict\nFAIL — missing scenario\n<!-- verdict: FAIL -->\n<!-- category: MISSING_SCENARIO -->"}'
  printf '%s' "$input1" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  input2='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"### Verdict\nFAIL — structural issue\n<!-- verdict: FAIL -->\n<!-- category: STRUCTURAL -->"}'
  printf '%s' "$input2" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ] && ! grep -q "BLOCKED-CATEGORY" "$f27"; then
    echo "PASS: record-verdict: different category on second FAIL → no BLOCKED-CATEGORY"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict: different category should not block (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# PASS after FAIL resets streak: same-category FAIL after an intervening PASS must NOT block
Tpr=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
fpr=$(make_plan "$Tpr" "pass-reset-feat" "spec")
(cd "$Tpr" && {
  # First FAIL with MISSING_SCENARIO
  inp1='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"### Verdict\nFAIL — missing scenario\n<!-- verdict: FAIL -->\n<!-- category: MISSING_SCENARIO -->"}'
  printf '%s' "$inp1" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  # PASS — should reset the streak for critic-spec
  inp2='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"### Verdict\nPASS\n<!-- verdict: PASS -->\n<!-- category: NONE -->"}'
  printf '%s' "$inp2" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  # Second FAIL with same category — PASS intervened, so must NOT trigger BLOCKED-CATEGORY
  inp3='{"hook_event_name":"SubagentStop","agent_type":"critic-spec","last_assistant_message":"### Verdict\nFAIL — missing scenario again\n<!-- verdict: FAIL -->\n<!-- category: MISSING_SCENARIO -->"}'
  printf '%s' "$inp3" | bash "$SCRIPT" record-verdict >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ] && ! grep -q "BLOCKED-CATEGORY" "$fpr"; then
    echo "PASS: record-verdict: PASS between same-category FAILs resets streak — no BLOCKED-CATEGORY"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-verdict: expected no BLOCKED-CATEGORY when PASS intervened (exit=$got, BLOCKED=$(grep -c BLOCKED-CATEGORY "$fpr" 2>/dev/null))"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: append-note ───────────────────────────────────────────────────────

T28=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f28=$(make_plan "$T28" "append-note-feat" "spec")

run "append-note: appends to Open Questions" 0 bash "$SCRIPT" append-note "$f28" "[TEST-NOTE] hello"
if grep -q "\[TEST-NOTE\] hello" "$f28"; then
  echo "PASS: append-note: note appears in Open Questions"
  PASS=$((PASS + 1))
else
  echo "FAIL: append-note: note not found in plan file"
  FAIL=$((FAIL + 1))
fi

run "append-note: missing file → exit 2" 2 bash "$SCRIPT" append-note "$T28/plans/nonexistent.md" "note"

# ── Tests: find-active fail-closed with 2+ candidates ────────────────────────

T29=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T29" && {
  make_plan "$T29" "feat-alpha" "spec" >/dev/null
  sleep 0.01
  make_plan "$T29" "feat-beta" "red" >/dev/null
  # Two active plans, no CLAUDE_PLAN_FILE, no branch match → exit 2
  err_out=$(bash "$SCRIPT" find-active 2>&1 >/dev/null)
  got=$?
  if [ "$got" -eq 2 ] && printf '%s' "$err_out" | grep -qi "active plan files found"; then
    echo "PASS: find-active: 2 active plans without disambiguation → exit 2 + error message"
    PASS=$((PASS + 1))
  else
    echo "FAIL: find-active: expected exit 2 for ambiguous plans (exit=$got, stderr='$err_out')"
    FAIL=$((FAIL + 1))
  fi
})

# One active plan without CLAUDE_PLAN_FILE should still fall back with warning (not error)
T30=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T30" && {
  make_plan "$T30" "sole-active" "red" >/dev/null
  out=$(bash "$SCRIPT" find-active 2>/dev/null)
  got=$?
  if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -q "sole-active"; then
    echo "PASS: find-active: single active plan without disambiguation → allowed with warning"
    PASS=$((PASS + 1))
  else
    echo "FAIL: find-active: single-plan fallback failed (exit=$got, out='$out')"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: flush-before-compact ──────────────────────────────────────────────

T31=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T31" "compact-feat" "spec" >/dev/null
(cd "$T31" && {
  input='{"trigger":"manual"}'
  printf '%s' "$input" | bash "$SCRIPT" flush-before-compact >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ] && grep -q "\[PRE-COMPACT" "$T31/plans/compact-feat.md"; then
    echo "PASS: flush-before-compact: PRE-COMPACT marker written to Open Questions"
    PASS=$((PASS + 1))
  else
    echo "FAIL: flush-before-compact: expected exit 0 + PRE-COMPACT marker (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# flush-before-compact with no active plan → exit 0, no error
T32=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T32" && {
  input='{"trigger":"auto"}'
  printf '%s' "$input" | bash "$SCRIPT" flush-before-compact >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ]; then
    echo "PASS: flush-before-compact: no active plan → exit 0 (silent)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: flush-before-compact: expected exit 0 with no active plan (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: record-stopfail ────────────────────────────────────────────────────

T33=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T33" "stopfail-feat" "green" >/dev/null
(cd "$T33" && {
  input='{"error":"rate_limit","session_id":"sess-abc"}'
  printf '%s' "$input" | bash "$SCRIPT" record-stopfail >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ] && grep -q "\[STOPFAIL" "$T33/plans/stopfail-feat.md"; then
    echo "PASS: record-stopfail: STOPFAIL marker written to Open Questions"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-stopfail: expected exit 0 + STOPFAIL marker (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: context bounded output + BLOCKED priority ─────────────────────────

T34=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T34" && {
  plan_file=$(make_plan "$T34" "bounded-ctx" "red")
  # Add a BLOCKED item and several non-BLOCKED items
  bash "$SCRIPT" append-note "$plan_file" "[BLOCKED-CATEGORY] critic-spec: category MISSING_SCENARIO failed twice" >/dev/null 2>&1
  bash "$SCRIPT" append-note "$plan_file" "regular open question 1" >/dev/null 2>&1
  bash "$SCRIPT" append-note "$plan_file" "regular open question 2" >/dev/null 2>&1
  out=$(bash "$SCRIPT" context 2>/dev/null)
  if printf '%s' "$out" | grep -q "BLOCKED-CATEGORY" && \
     printf '%s' "$out" | grep -q '"additionalContext"'; then
    echo "PASS: context: BLOCKED items appear in bounded output"
    PASS=$((PASS + 1))
  else
    echo "FAIL: context: expected BLOCKED-CATEGORY in additionalContext (out='$out')"
    FAIL=$((FAIL + 1))
  fi
})

# context output capped at 800 chars
T35=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T35" && {
  plan_file=$(make_plan "$T35" "long-questions" "spec")
  # Add a very long open question to force truncation
  long_note=$(python3 -c "print('[BLOCKED] ' + 'x' * 900)")
  bash "$SCRIPT" append-note "$plan_file" "$long_note" >/dev/null 2>&1
  out=$(bash "$SCRIPT" context 2>/dev/null)
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null || echo "")
  if [ "${#ctx}" -le 800 ]; then
    echo "PASS: context: additionalContext capped at 800 chars (got ${#ctx})"
    PASS=$((PASS + 1))
  else
    echo "FAIL: context: additionalContext exceeds 800 chars (got ${#ctx})"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: record-critic-start ───────────────────────────────────────────────

T36=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f36=$(make_plan "$T36" "critic-start-feat" "spec")
(cd "$T36" && {
  input='{"hook_event_name":"SubagentStart","agent_type":"critic-spec","agent_id":"agent-abc"}'
  printf '%s' "$input" | bash "$SCRIPT" record-critic-start >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ] && grep -q "## Critic Runs" "$f36" && grep -q "\[START" "$f36" && grep -q "critic-spec" "$f36"; then
    echo "PASS: record-critic-start: START entry written to Critic Runs section"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-critic-start: expected exit 0 + Critic Runs section with START entry (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# Non-critic agent must be ignored (exit 0, no write)
T37=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T37" "non-critic-start" "spec" >/dev/null
(cd "$T37" && {
  input='{"hook_event_name":"SubagentStart","agent_type":"general-purpose","agent_id":"agent-xyz"}'
  printf '%s' "$input" | bash "$SCRIPT" record-critic-start >/dev/null 2>&1
  got=$?
  plan_file="$T37/plans/non-critic-start.md"
  if [ "$got" -eq 0 ] && ! grep -q "## Critic Runs" "$plan_file"; then
    echo "PASS: record-critic-start: non-critic agent ignored (no Critic Runs written)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-critic-start: expected non-critic agent to be ignored (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# Critic Verdicts section must remain unchanged after record-critic-start
T38=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f38=$(make_plan "$T38" "verdicts-intact" "spec")
bash "$SCRIPT" append-verdict "$f38" "spec/critic-spec: PASS" >/dev/null 2>&1
(cd "$T38" && {
  input='{"hook_event_name":"SubagentStart","agent_type":"critic-code","agent_id":"agent-1"}'
  printf '%s' "$input" | bash "$SCRIPT" record-critic-start >/dev/null 2>&1
  if grep -q "spec/critic-spec: PASS" "$f38" && grep -q "## Critic Runs" "$f38"; then
    echo "PASS: record-critic-start: Critic Verdicts section unaffected; Critic Runs added separately"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-critic-start: Critic Verdicts was corrupted or Critic Runs missing"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: flush-on-end ───────────────────────────────────────────────────────

T39=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T39" "session-end-feat" "green" >/dev/null
(cd "$T39" && {
  input='{"reason":"normal"}'
  printf '%s' "$input" | bash "$SCRIPT" flush-on-end >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ] && grep -q "\[SESSION-END" "$T39/plans/session-end-feat.md"; then
    echo "PASS: flush-on-end: SESSION-END marker written to Open Questions"
    PASS=$((PASS + 1))
  else
    echo "FAIL: flush-on-end: expected exit 0 + SESSION-END marker (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# flush-on-end with no active plan → exit 0, no error
T40=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T40" && {
  input='{"reason":"normal"}'
  printf '%s' "$input" | bash "$SCRIPT" flush-on-end >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ]; then
    echo "PASS: flush-on-end: no active plan → exit 0 (silent)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: flush-on-end: expected exit 0 with no active plan (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# log-post-compact: POST-COMPACT marker written with phase and open-question count
T41=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
make_plan "$T41" "post-compact-feat" "green" >/dev/null
# Add two open questions so count > 0
bash "$SCRIPT" append-note "$T41/plans/post-compact-feat.md" "Question one" >/dev/null 2>&1
bash "$SCRIPT" append-note "$T41/plans/post-compact-feat.md" "Question two" >/dev/null 2>&1
(cd "$T41" && {
  bash "$SCRIPT" log-post-compact </dev/null >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ] && grep -q "\[POST-COMPACT" "$T41/plans/post-compact-feat.md"; then
    marker=$(grep "\[POST-COMPACT" "$T41/plans/post-compact-feat.md" | head -1)
    if echo "$marker" | grep -q "phase=green" && echo "$marker" | grep -q "open_questions="; then
      echo "PASS: log-post-compact: POST-COMPACT marker with phase and open_questions written"
      PASS=$((PASS + 1))
    else
      echo "FAIL: log-post-compact: marker missing phase or open_questions fields: $marker"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "FAIL: log-post-compact: expected exit 0 + POST-COMPACT marker (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# log-post-compact with no active plan → exit 0, no error
T42=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T42" && {
  bash "$SCRIPT" log-post-compact </dev/null >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ]; then
    echo "PASS: log-post-compact: no active plan → exit 0 (silent)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: log-post-compact: expected exit 0 with no active plan (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: record-task-created / record-task-completed (P3 TaskCreated hook) ──

T43=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f43=$(make_plan "$T43" "native-task-feat" "green")
(cd "$T43" && {
  input='{"task_id":"task-abc","task_subject":"Implement domain rule","task_description":"","teammate_name":"","team_name":""}'
  printf '%s' "$input" | bash "$SCRIPT" record-task-created >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ] && grep -q "## Task Ledger" "$f43" && grep -q "task-abc" "$f43"; then
    echo "PASS: record-task-created: native task registered in Task Ledger"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-task-created: expected exit 0 + task-abc in Task Ledger (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

T44=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f44=$(make_plan "$T44" "native-task-done" "green")
bash "$SCRIPT" add-task "$f44" "task-xyz" "domain" >/dev/null 2>&1
(cd "$T44" && {
  input='{"task_id":"task-xyz","task_subject":"Implement domain rule","task_description":"","teammate_name":"","team_name":""}'
  printf '%s' "$input" | bash "$SCRIPT" record-task-completed >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ] && grep -q "completed" "$f44"; then
    echo "PASS: record-task-completed: native task marked completed in Task Ledger"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-task-completed: expected exit 0 + completed status (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# record-task-created: no active plan → exit 0 silently
T45=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T45" && {
  input='{"task_id":"task-x","task_subject":"no plan"}'
  printf '%s' "$input" | bash "$SCRIPT" record-task-created >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ]; then
    echo "PASS: record-task-created: no active plan → exit 0 (silent)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-task-created: expected exit 0 with no active plan (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: record-permission-denied (P3 PermissionDenied hook) ───────────────

T46=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
f46=$(make_plan "$T46" "perm-denied-feat" "green")
(cd "$T46" && {
  input='{"tool_name":"Write","tool_input":{},"tool_use_id":"use-1","reason":"path is outside allowed directories"}'
  printf '%s' "$input" | bash "$SCRIPT" record-permission-denied >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ] && grep -q "\[PERMISSION-DENIED" "$f46" && grep -q "Write" "$f46"; then
    echo "PASS: record-permission-denied: PERMISSION-DENIED marker written to Open Questions"
    PASS=$((PASS + 1))
  else
    echo "FAIL: record-permission-denied: expected exit 0 + PERMISSION-DENIED marker (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# ── Tests: schema versioning (P5) ─────────────────────────────────────────────

# schema: 1 → OK
T47=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T47" && {
  mkdir -p plans
  cat > plans/schema1-feat.md <<'PLANEOF'
---
feature: schema1-feat
phase: brainstorm
schema: 1
---

## Phase
brainstorm

## Critic Verdicts

## Open Questions
PLANEOF
  out=$(bash "$SCRIPT" set-phase plans/schema1-feat.md spec 2>/dev/null)
  got=$?
  if [ "$got" -eq 0 ]; then
    echo "PASS: schema: schema 1 plan accepted by set-phase"
    PASS=$((PASS + 1))
  else
    echo "FAIL: schema: schema 1 plan rejected unexpectedly (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# schema: 0 / missing → warning, no hard-fail
T48=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T48" && {
  mkdir -p plans
  cat > plans/schema0-feat.md <<'PLANEOF'
---
feature: schema0-feat
phase: brainstorm
---

## Phase
brainstorm

## Critic Verdicts

## Open Questions
PLANEOF
  out=$(bash "$SCRIPT" set-phase plans/schema0-feat.md spec 2>&1)
  got=$?
  if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qi "warning"; then
    echo "PASS: schema: missing schema field → warning printed, no hard-fail"
    PASS=$((PASS + 1))
  else
    echo "FAIL: schema: expected exit 0 + warning for missing schema (exit=$got, out='$out')"
    FAIL=$((FAIL + 1))
  fi
})

# schema: 99 → hard-fail
T49=$(mktemp -d "$TMPDIR_BASE/tmp.XXXXXX")
(cd "$T49" && {
  mkdir -p plans
  cat > plans/schema99-feat.md <<'PLANEOF'
---
feature: schema99-feat
phase: brainstorm
schema: 99
---

## Phase
brainstorm

## Critic Verdicts

## Open Questions
PLANEOF
  bash "$SCRIPT" set-phase plans/schema99-feat.md spec >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 1 ]; then
    echo "PASS: schema: unknown schema version → hard-fail (exit 1)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: schema: expected exit 1 for unsupported schema version (exit=$got)"
    FAIL=$((FAIL + 1))
  fi
})

# ── Results ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
