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
    GATE_FAIL_REASON="ambiguous"
    return 1
  elif [ $rc -ne 0 ]; then
    plan_file=$(bash "$PLAN_FILE_SH" find-latest 2>/dev/null) || { GATE_FAIL_REASON="none"; return 1; }
  fi
  bash "$PLAN_FILE_SH" get-phase "$plan_file" 2>/dev/null || { GATE_FAIL_REASON="none"; return 1; }
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
    tests/*|*_test.*|test_*.*|*.test.*|*.spec.*|*_spec.*) return 0 ;;
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
  GATE_FAIL_REASON="none"
  if ! phase=$(get_active_phase); then
    if [ "${PHASE_GATE_STRICT:-1}" = "1" ]; then
      if [ "${GATE_FAIL_REASON}" = "ambiguous" ]; then
        echo "BLOCKED [phase-gate]: multiple active plan files found. Set CLAUDE_PLAN_FILE=plans/{slug}.md to disambiguate, or set PHASE_GATE_STRICT=0." >&2
        exit 2
      fi
      # No plan file yet — bootstrap mode: allow plans/, docs/, and root-level files
      # but still protect src/ and tests/ to prevent accidental implementation writes.
      local file_path_early
      file_path_early=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
      if [ -n "$file_path_early" ] && (is_source_path "$file_path_early" || is_test_path "$file_path_early"); then
        echo "BLOCKED [phase-gate]: PHASE_GATE_STRICT=1, no active plan file, and '$file_path_early' is a source/test path. Run /brainstorming first to create a plan, then advance to the appropriate phase." >&2
        exit 2
      fi
      echo "[phase-gate] no active plan file; bootstrap write allowed for '$file_path_early'. Run /brainstorming to enable full phase gating." >&2
      exit 0
    fi
    echo "[phase-gate] no active plan file; write allowed. Run /brainstorming to enable gating." >&2
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
    implement)
      # Implementation phase: coder subagents write source files to satisfy failing tests.
      # Test files remain frozen — coders must not modify tests.
      if is_test_path "$file_path"; then
        echo "BLOCKED [phase-gate]: Phase is 'implement'. Test files are frozen — implement code in src/ only, do not modify tests." >&2
        exit 2
      fi
      ;;
    review)
      # PR review fix phase: source files may be modified to address review issues.
      # Test files remain frozen (as in green phase).
      if is_test_path "$file_path"; then
        echo "BLOCKED [phase-gate]: Phase is 'review'. Test files are frozen — apply pr-review fixes to source only." >&2
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
        echo "BLOCKED [phase-gate]: Phase is 'done' and '$file_path' is a source/test path. Run /brainstorming to start a new feature (creates a new plan file), or set CLAUDE_PLAN_FILE=plans/{new-slug}.md before writing." >&2
        exit 2
      fi
      echo "[phase-gate] warning: most recent plan is 'done' but '$file_path' is not a source/test file — allowing. To start a new feature, run /brainstorming." >&2
      exit 0
      ;;
  esac

  exit 0
}

# ── Prompt mode ───────────────────────────────────────────────────────────────
# UserPromptSubmit hook: injects a phase reminder into Claude's context when the
# pipeline is in an early phase (brainstorm or spec). Outputs the canonical
# hookSpecificOutput JSON so Claude sees the current phase before responding.
# No output for red/implement/review/green/integration/done — gating is handled by Write hooks.

mode_prompt() {
  # Read the payload (not used directly, but must consume stdin)
  cat >/dev/null

  local phase
  GATE_FAIL_REASON="none"
  phase=$(get_active_phase 2>/dev/null) || exit 0

  case "$phase" in
    brainstorm)
      printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"[phase-gate] Pipeline phase: brainstorm. Complete /brainstorming before writing spec or code. Do not write source files or tests yet."}}\n'
      ;;
    spec)
      printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"[phase-gate] Pipeline phase: spec. Complete /writing-spec before writing tests or code. Do not write source files yet."}}\n'
      ;;
  esac
  exit 0
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

[ $# -ge 1 ] || { echo "Usage: phase-gate.sh <write|prompt>" >&2; exit 1; }

case "$1" in
  write)  mode_write ;;
  prompt) mode_prompt ;;
  *) echo "Unknown mode: $1" >&2; exit 1 ;;
esac
