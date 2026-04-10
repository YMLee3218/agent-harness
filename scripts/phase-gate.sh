#!/usr/bin/env bash
# Phase-gate hook — enforces plan-file phase rules via PreToolUse and UserPromptSubmit hooks.
#
# Usage:
#   phase-gate.sh write    (PreToolUse Write|Edit — reads tool JSON from stdin)
#   phase-gate.sh prompt   (UserPromptSubmit — always exit 0; hook registered for future use)
#
# Exit 2 = block the tool call (Write/Edit mode only)
# Exit 0 = allow
#
# Fail-closed when PHASE_GATE_STRICT=1 (default): if no active plan file exists, block all writes.
# Fail-open when PHASE_GATE_STRICT=0: if no active plan file, allow unconditionally with a warning.

PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

get_active_phase() {
  local plan_file rc
  # Pass through find-active stderr so ambiguity errors ("2 active plan files found") are visible.
  # Fall back to most recent plan only for the "no active plans" case (exit 2).
  # Exit 3 means ambiguous (2+ active plans) — fail-closed, no fallback.
  plan_file=$(bash "$PLAN_FILE_SH" find-active 2>/dev/null)
  rc=$?
  if [ $rc -eq 3 ]; then
    bash "$PLAN_FILE_SH" find-active >/dev/null  # re-run to emit stderr
    return 1
  elif [ $rc -ne 0 ]; then
    plan_file=$(bash "$PLAN_FILE_SH" find-latest 2>/dev/null) || return 1
  fi
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
    src/main/kotlin/*|src/main/java/*|src/main/scala/*|\
    packages/*/src/*|\
    internal/*|cmd/*|pkg/*|\
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

  if ! command -v jq >/dev/null 2>&1; then
    if [ "${PHASE_GATE_STRICT:-1}" = "1" ]; then
      echo "BLOCKED [phase-gate]: jq is required but not found" >&2
      exit 2
    fi
    echo "[phase-gate] warning: jq not found; write allowed (strict mode off)" >&2
    exit 0
  fi

  local phase
  if ! phase=$(get_active_phase); then
    if [ "${PHASE_GATE_STRICT:-1}" = "1" ]; then
      echo "BLOCKED [phase-gate]: PHASE_GATE_STRICT=1 and no active plan file. Run /initializing-project to set up a plan, or set PHASE_GATE_STRICT=0 for bootstrap." >&2
      exit 2
    fi
    echo "[phase-gate] no active plan file; write allowed. Run /initializing-project to enable gating." >&2
    exit 0
  fi

  local file_path
  file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
  [ -z "$file_path" ] && exit 0

  case "$phase" in
    brainstorm|spec)
      if is_source_path "$file_path"; then
        echo "BLOCKED [phase-gate]: Phase is '$phase'. Writing source files is not allowed before Red phase. Complete /writing-spec and /writing-tests first." >&2
        exit 2
      fi
      if is_test_path "$file_path"; then
        echo "BLOCKED [phase-gate]: Phase is '$phase'. Writing test files is not allowed before spec is approved. Complete /writing-spec first, then advance to Red phase with /writing-tests." >&2
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
    integration)
      # Integration phase: tests are frozen; only source and integration-specific files may change.
      if is_test_path "$file_path"; then
        echo "BLOCKED [phase-gate]: Phase is 'integration'. Test files are frozen — fix integration failures in source code only." >&2
        exit 2
      fi
      ;;
    done)
      if is_source_path "$file_path" || is_test_path "$file_path"; then
        echo "BLOCKED [phase-gate]: Phase is 'done' and '$file_path' is a source/test path. Run /initializing-project to start a new feature, or set CLAUDE_PLAN_FILE=plans/{new-slug}.md to continue." >&2
        exit 2
      fi
      echo "[phase-gate] warning: most recent plan is 'done' but '$file_path' is not a source/test file — allowing. To start a new feature, run /initializing-project." >&2
      exit 0
      ;;
  esac

  exit 0
}

# ── Prompt mode ───────────────────────────────────────────────────────────────

mode_prompt() {
  exit 0
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

[ $# -ge 1 ] || { echo "Usage: phase-gate.sh <write|prompt>" >&2; exit 1; }

case "$1" in
  write)  mode_write ;;
  prompt) mode_prompt ;;
  *) echo "Unknown mode: $1" >&2; exit 1 ;;
esac
