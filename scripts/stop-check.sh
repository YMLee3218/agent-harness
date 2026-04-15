#!/usr/bin/env bash
# Stop hook: verify unit tests pass before an autonomous run completes.
#
# Active when CLAUDE_NONINTERACTIVE=1 and the active plan phase is green, integration, or done.
# In interactive mode (CLAUDE_NONINTERACTIVE unset/0), exits 0 immediately to avoid
# running tests after every response.
#
# Phase behaviour:
#   green       — unit tests must pass (implementation just finished)
#   integration — unit tests must pass (integration loop may modify source)
#   done        — unit tests must pass (final integrity check)
#
# Exit 2 = block Claude from stopping (tests failing — must be fixed first)
# Exit 0 = allow stop

[ "${CLAUDE_NONINTERACTIVE:-0}" = "1" ] || exit 0

# Guard against infinite loops: if Claude is already continuing due to a prior
# Stop-hook block, do not block again. Anthropic docs explicitly warn about this
# pattern — stop_hook_active=true means we already fired once; a second block
# would loop forever if tests keep failing.
_payload=$(cat)
if command -v jq >/dev/null 2>&1 && [ -n "$_payload" ]; then
  if [ "$(printf '%s' "$_payload" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
    echo "[stop-check] stop_hook_active=true — bypassing to avoid infinite loop" >&2
    exit 0
  fi
fi

PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"

# Locate active plan file
if [ -n "${CLAUDE_PLAN_FILE:-}" ] && [ -f "$CLAUDE_PLAN_FILE" ]; then
  active_plan="$CLAUDE_PLAN_FILE"
else
  active_plan=$(bash "$PLAN_FILE_SH" find-active 2>/dev/null) || exit 0
fi

[ -z "$active_plan" ] && exit 0

# Enforce in green, integration, and done phases (unit tests must pass in all three).
# review phase is intentionally excluded: it is the pr-review FAIL recovery phase where
# source modifications are allowed mid-cycle and tests may temporarily be broken.
# The phase transitions to green (and triggers enforcement) only after [CONVERGED] pr-review.
phase=$(bash "$PLAN_FILE_SH" get-phase "$active_plan" 2>/dev/null) || exit 0
case "$phase" in
  green|integration|done) ;;
  *) exit 0 ;;
esac

# F3 guard: if integration phase and a [BLOCKED] marker for integration tests is
# already recorded in the plan file, allow the stop without re-running tests.
# This avoids an infinite Stop-hook block loop when stop_hook_active is unavailable
# in the Stop payload (plan-file-based self-halt, no dependency on stop_hook_active).
if [ "$phase" = "integration" ]; then
  if grep -qF "[BLOCKED] integration tests failed after 2 fix attempts" "$active_plan" 2>/dev/null \
     || grep -qF "[BLOCKED-INTEGRATION]" "$active_plan" 2>/dev/null; then
    echo "[stop-check] integration [BLOCKED] already recorded — allowing stop (plan-based self-halt)" >&2
    exit 0
  fi
fi

# Extract test command from project CLAUDE.md (## Commands → - Test: `cmd` line).
# Requires CLAUDE_PROJECT_DIR to be set — no PWD fallback to avoid reading the wrong CLAUDE.md.
if [ -z "${CLAUDE_PROJECT_DIR:-}" ]; then
  echo "[stop-check] CLAUDE_PROJECT_DIR not set; skipping test verification" >&2
  exit 0
fi
test_cmd=""
claude_md="${CLAUDE_PROJECT_DIR}/CLAUDE.md"
claude_md_exists=0
if [ -f "$claude_md" ]; then
  claude_md_exists=1
  test_cmd=$(grep -E '^\- Test: ' "$claude_md" 2>/dev/null \
    | sed "s/^- Test: \`\(.*\)\`/\1/" \
    | head -1 || true)
fi

# Skip gracefully if the line is still an initializing-project placeholder, has unfilled {template-vars},
# or contains angle-bracket placeholders such as <command> (used in examples/local.md template).
# Use pattern {word} (lowercase letters, digits, underscores, hyphens) to avoid false positives
# from legitimate brace usage such as pytest --deselect 'tests/{foo}'.
if printf '%s' "$test_cmd" | grep -q "initializing-project" \
   || printf '%s' "$test_cmd" | grep -qE '\{[a-z0-9_-]+\}' \
   || printf '%s' "$test_cmd" | grep -qE '<[a-z0-9_-]+>'; then
  echo "[stop-check] test command is a placeholder; skipping test verification" >&2
  exit 0
fi

# No matching '- Test: `cmd`' line found.
if [ -z "$test_cmd" ]; then
  if [ "$claude_md_exists" -eq 1 ]; then
    # CLAUDE.md exists but no test line — treat as configuration error in autonomous mode
    # (we are already in CLAUDE_NONINTERACTIVE=1 context; see line 16).
    bash "$PLAN_FILE_SH" record-stop-block "$active_plan" "$phase" \
      "CLAUDE.md found but no '- Test: \`cmd\`' line — add test command" 2>/dev/null || true
    echo "BLOCKED [stop-check]: CLAUDE.md found but no '- Test: \`cmd\`' line detected. Add a test command to CLAUDE.md using the exact format: \`- Test: \`<command>\`\` (phase=${phase})." >&2
    exit 2
  fi
  echo "[stop-check] CLAUDE.md not found; skipping test verification" >&2
  exit 0
fi

# Run tests; block stop on failure.
# Trust model: test_cmd comes from the project's own CLAUDE.md — treated as
# project-controlled input. We use bash -c rather than eval to make the trust
# boundary explicit; the command string itself is not sanitised further.
# Timeout: default 600s max to prevent stalled suites from blocking the session indefinitely.
# Override via CLAUDE_STOP_CHECK_TIMEOUT env var (e.g. CLAUDE_STOP_CHECK_TIMEOUT=1200 for large suites).
_timeout="${CLAUDE_STOP_CHECK_TIMEOUT:-600}"
echo "[stop-check] Verifying tests pass before stop (phase=${phase}, CLAUDE_NONINTERACTIVE=1)..." >&2
timeout "$_timeout" bash -c "$test_cmd" >/dev/null 2>&1
_test_exit=$?
if [ $_test_exit -eq 0 ]; then
  echo "[stop-check] Tests passed — stop allowed." >&2
  exit 0
elif [ $_test_exit -eq 124 ]; then
  bash "$PLAN_FILE_SH" record-stop-block "$active_plan" "$phase" \
    "tests timed out after ${_timeout}s — fix hanging test" 2>/dev/null || true
  echo "BLOCKED [stop-check]: tests timed out after ${_timeout}s — fix the hanging test before stopping." >&2
  exit 2
else
  bash "$PLAN_FILE_SH" record-stop-block "$active_plan" "$phase" \
    "tests failing (cmd: ${test_cmd})" 2>/dev/null || true
  echo "BLOCKED [stop-check]: Tests are failing in ${phase} phase. Fix failures before stopping." >&2
  echo "[stop-check] Command: ${test_cmd}" >&2
  exit 2
fi
