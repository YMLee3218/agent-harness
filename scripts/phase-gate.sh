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
  # Prefer active (non-done) plan; fall back to most recent plan to detect 'done' phase
  plan_file=$(bash "$PLAN_FILE_SH" find-active 2>/dev/null) \
    || plan_file=$(bash "$PLAN_FILE_SH" find-latest 2>/dev/null) \
    || return 1
  bash "$PLAN_FILE_SH" get-phase "$plan_file" 2>/dev/null || return 1
}

# Domain/feature/infrastructure source paths (blocked during red phase).
# Override with PHASE_GATE_SRC_GLOB (colon-separated glob patterns).
is_source_path() {
  local p="$1"
  if [ -n "${PHASE_GATE_SRC_GLOB:-}" ]; then
    local pattern
    while IFS= read -r pattern; do
      case "$p" in $pattern) return 0 ;; esac
    done < <(printf '%s\n' "$PHASE_GATE_SRC_GLOB" | tr ':' '\n')
    return 1
  fi
  case "$p" in
    src/domain/*|src/features/*|src/infrastructure/*|\
    */src/domain/*|*/src/features/*|*/src/infrastructure/*|\
    src/main/kotlin/*|src/main/java/*|\
    packages/*/src/*|\
    internal/*|cmd/*|\
    app/*|app/models/*|app/controllers/*|app/services/*|\
    lib/*|\
    crates/*/src/*|\
    apps/*/src/*)
      return 0 ;;
    *) return 1 ;;
  esac
}

# Test paths (blocked during green phase to prevent cheating).
# Override with PHASE_GATE_TEST_GLOB (colon-separated glob patterns).
is_test_path() {
  local p="$1"
  if [ -n "${PHASE_GATE_TEST_GLOB:-}" ]; then
    local pattern
    while IFS= read -r pattern; do
      case "$p" in $pattern) return 0 ;; esac
    done < <(printf '%s\n' "$PHASE_GATE_TEST_GLOB" | tr ':' '\n')
    return 1
  fi
  # Exclude *.spec.md — these are BDD spec files, not test runners
  case "$p" in
    *.spec.md) return 1 ;;
    tests/*|*_test.*|test_*.*|*.test.*|*.spec.*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Write/Edit mode ───────────────────────────────────────────────────────────

mode_write() {
  local input
  input=$(cat)

  local phase
  if ! phase=$(get_active_phase); then
    if [ "${PHASE_GATE_STRICT:-0}" = "1" ]; then
      echo "BLOCKED [phase-gate]: PHASE_GATE_STRICT=1 and no active plan file. Run /initializing-project to set up gating." >&2
      exit 2
    fi
    echo "[phase-gate] no active plan file; write allowed. Run /initializing-project to enable gating." >&2
    exit 0
  fi

  local file_path
  file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  [ -z "$file_path" ] && exit 0

  case "$phase" in
    brainstorm|spec)
      if is_source_path "$file_path"; then
        echo "BLOCKED [phase-gate]: Phase is '$phase'. Writing source files is not allowed before Red phase. Complete /writing-spec and /writing-tests first." >&2
        exit 2
      fi
      ;;
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
    done)
      echo "BLOCKED [phase-gate]: Phase is 'done'. This feature is complete. Create a new plan file to start a new feature." >&2
      exit 2
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
        printf 'Current plan phase is "%s". Complete /writing-spec and /writing-tests first to advance the phase to "red" before implementing.\n' "$phase"
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
