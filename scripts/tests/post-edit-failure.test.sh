#!/usr/bin/env bash
# Regression tests for post-edit-failure.sh and plan-file.sh record-tool-failure
# Usage: bash post-edit-failure.test.sh
# Exit 0 = all tests passed; exit 1 = at least one failure.

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/post-edit-failure.sh"
PLAN_FILE_SH="$(cd "$(dirname "$0")/.." && pwd)/plan-file.sh"
TMPDIR_BASE=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMPDIR_BASE"; }
trap cleanup EXIT

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

check_file_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (pattern '$pattern' not found in $file)"
    FAIL=$((FAIL + 1))
  fi
}

check_file_not_contains() {
  local desc="$1" file="$2" pattern="$3"
  if ! grep -q "$pattern" "$file" 2>/dev/null; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (unexpected pattern '$pattern' found in $file)"
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
---

## Vision
Test plan

## Phase
$phase

## Critic Verdicts

## Open Questions
EOF
  echo "$dir/plans/${slug}.md"
}

# ── Test 1: record-tool-failure — writes TOOL-FAIL marker to Open Questions ──

T1=$(mktemp -d -p "$TMPDIR_BASE")
f1=$(make_plan "$T1" "fail-feat" "green")
input='{"hook_event_name":"PostToolUseFailure","tool_name":"Write","error":"permission denied: /protected/path"}'
printf '%s' "$input" | CLAUDE_PROJECT_DIR="$T1" bash "$PLAN_FILE_SH" record-tool-failure >/dev/null 2>&1
check "record-tool-failure: exits 0 with active plan" 0 $?
check_file_contains "record-tool-failure: TOOL-FAIL marker written" "$f1" "\[TOOL-FAIL"
check_file_contains "record-tool-failure: tool name recorded" "$f1" "Write"

# ── Test 2: record-tool-failure — no active plan → exit 0, silent ────────────

T2=$(mktemp -d -p "$TMPDIR_BASE")
input='{"hook_event_name":"PostToolUseFailure","tool_name":"Write","error":"some error"}'
printf '%s' "$input" | CLAUDE_PROJECT_DIR="$T2" bash "$PLAN_FILE_SH" record-tool-failure >/dev/null 2>&1
check "record-tool-failure: no active plan → exit 0" 0 $?

# ── Test 3: record-tool-failure — long error message is truncated ─────────────

T3=$(mktemp -d -p "$TMPDIR_BASE")
f3=$(make_plan "$T3" "long-error-feat" "red")
long_error=$(python3 -c "print('x' * 200)")
# Use jq to build the JSON safely to avoid shell quoting issues
input=$(printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Edit","error":"%s"}' "$long_error")
printf '%s' "$input" | CLAUDE_PROJECT_DIR="$T3" bash "$PLAN_FILE_SH" record-tool-failure >/dev/null 2>&1
check_file_contains "record-tool-failure: TOOL-FAIL marker present for long error" "$f3" "\[TOOL-FAIL"
# 200-char 'x' string must not appear verbatim (was truncated to 120 chars)
if ! grep -q "$(python3 -c "print('x' * 150)")" "$f3" 2>/dev/null; then
  echo "PASS: record-tool-failure: long error message truncated"
  PASS=$((PASS + 1))
else
  echo "FAIL: record-tool-failure: long error not truncated (full string found)"
  FAIL=$((FAIL + 1))
fi

# ── Test 4: post-edit-failure.sh wrapper — exit 0 always ─────────────────────

T4=$(mktemp -d -p "$TMPDIR_BASE")
make_plan "$T4" "wrapper-feat" "green" >/dev/null
input='{"hook_event_name":"PostToolUseFailure","tool_name":"Write","error":"test error"}'
printf '%s' "$input" | CLAUDE_PROJECT_DIR="$T4" bash "$SCRIPT" >/dev/null 2>&1
check "post-edit-failure.sh: wrapper exits 0" 0 $?

# ── Test 5: post-edit-failure.sh wrapper — records failure via plan-file.sh ──

T5=$(mktemp -d -p "$TMPDIR_BASE")
f5=$(make_plan "$T5" "wrapper-record-feat" "green")
input='{"hook_event_name":"PostToolUseFailure","tool_name":"Edit","error":"readonly filesystem"}'
printf '%s' "$input" | CLAUDE_PROJECT_DIR="$T5" bash "$SCRIPT" >/dev/null 2>&1
check_file_contains "post-edit-failure.sh: TOOL-FAIL entry in plan file" "$f5" "\[TOOL-FAIL"
check_file_contains "post-edit-failure.sh: Edit tool name in plan file" "$f5" "Edit"

# ── Test 6: post-edit-failure.sh — exit 0 even with malformed input ──────────

T6=$(mktemp -d -p "$TMPDIR_BASE")
printf 'not-json' | CLAUDE_PROJECT_DIR="$T6" bash "$SCRIPT" >/dev/null 2>&1
check "post-edit-failure.sh: exit 0 with malformed input" 0 $?

# ── Results ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
