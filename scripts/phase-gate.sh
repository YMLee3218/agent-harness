#!/usr/bin/env bash
# Phase-gate hook — enforces plan-file phase rules via PreToolUse and UserPromptSubmit hooks.
#
# Usage:
#   phase-gate.sh write    (PreToolUse Write|Edit — reads tool JSON from stdin)
#   phase-gate.sh prompt   (UserPromptSubmit — reads prompt JSON from stdin, may inject additionalContext)
#
# Exit 2 = block the tool call (Write/Edit mode only)
# Exit 0 = allow; if stdout is valid JSON with "additionalContext", Claude receives it (prompt mode)
#
# Fail-open: if plan-file is absent or Phase cannot be read, allow unconditionally.

PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

get_active_phase() {
  local plan_file
  plan_file=$("$PLAN_FILE_SH" find-active 2>/dev/null) || return 1
  "$PLAN_FILE_SH" get-phase "$plan_file" 2>/dev/null || return 1
}

# Domain/feature/infrastructure source paths (blocked during red phase)
is_source_path() {
  local p="$1"
  case "$p" in
    src/domain/*|src/features/*|src/infrastructure/*|\
    */src/domain/*|*/src/features/*|*/src/infrastructure/*)
      return 0 ;;
    *) return 1 ;;
  esac
}

# Test paths (blocked during green phase to prevent cheating)
is_test_path() {
  local p="$1"
  case "$p" in
    tests/*|*_test.*|*.test.*|*.spec.*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Write/Edit mode ───────────────────────────────────────────────────────────

mode_write() {
  local input
  input=$(cat)

  local phase
  phase=$(get_active_phase) || exit 0   # no active plan → allow

  local file_path
  file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  [ -z "$file_path" ] && exit 0

  case "$phase" in
    red)
      if is_source_path "$file_path"; then
        echo "BLOCKED [phase-gate]: Phase is 'red' (Red phase). Writing source files in src/domain/, src/features/, src/infrastructure/ is not allowed during Red phase. Write tests only." >&2
        exit 2
      fi
      ;;
    green)
      if is_test_path "$file_path"; then
        echo "BLOCKED [phase-gate]: Phase is 'green' (Green phase). Modifying test files is not allowed — tests must remain as written during Red phase. Fix the implementation, not the tests." >&2
        exit 2
      fi
      ;;
  esac

  exit 0
}

# ── Prompt mode ───────────────────────────────────────────────────────────────

mode_prompt() {
  local input
  input=$(cat)

  local phase
  phase=$(get_active_phase) || exit 0   # no active plan → allow with no injection

  local prompt_text
  prompt_text=$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null)

  # Check if the prompt contains implementation keywords but plan phase is too early
  local impl_pattern='implement|구현|make.*pass|go ahead|proceed|start coding|코딩|작성해'
  if printf '%s' "$prompt_text" | grep -iqE "$impl_pattern"; then
    case "$phase" in
      brainstorm|spec)
        printf '{"additionalContext": "현재 plan file의 Phase가 '\''%s'\''입니다. 구현을 시작하려면 먼저 /writing-spec, /writing-tests 를 완료하여 Phase를 '\''red'\''로 올리세요."}\n' "$phase"
        exit 0
        ;;
    esac
  fi

  exit 0
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

[ $# -ge 1 ] || { echo "Usage: phase-gate.sh <write|prompt>" >&2; exit 1; }

case "$1" in
  write)  mode_write ;;
  prompt) mode_prompt ;;
  *) echo "Unknown mode: $1" >&2; exit 1 ;;
esac
