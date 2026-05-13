#!/usr/bin/env bash
# Stop hook: verify unit tests pass before an autonomous run completes.
# Active when CLAUDE_NONINTERACTIVE=1 and the active plan phase is green or integration.
# In interactive mode (CLAUDE_NONINTERACTIVE unset/0), exits 0 immediately.
# Phase coverage: green and integration only — see phase_runs_stop_check in phase-policy.sh.
# done is excluded: session already closed, no test run needed.
# Exit codes: 0=allow stop, 2=block stop (stderr fed back to Claude as context),
# 1/other=non-blocking error. Always use exit 2 (never exit 1) to prevent stop.
set -euo pipefail

[ "${CLAUDE_NONINTERACTIVE:-0}" = "1" ] || exit 0

# Guard against infinite loops: if Claude is already continuing due to a prior
# Stop-hook block, do not block again. Anthropic docs explicitly warn about this
# pattern — stop_hook_active=true means we already fired once; a second block
# would loop forever if tests keep failing.
_payload=$(cat)
export CLAUDE_PLAN_CAPABILITY=harness
PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"
if ! command -v jq >/dev/null 2>&1; then
  echo "[STOP-BLOCKED] jq required for autonomous stop-check — install jq and re-run" >&2
  if [ -n "${CLAUDE_PLAN_FILE:-}" ] && [ -f "$CLAUDE_PLAN_FILE" ]; then
    _phase=$(bash "$PLAN_FILE_SH" get-phase "$CLAUDE_PLAN_FILE" 2>/dev/null || echo "unknown")
    bash "$PLAN_FILE_SH" record-stop-block "$CLAUDE_PLAN_FILE" "$_phase" \
      "jq required for stop-check — install jq and re-run" 2>/dev/null || true
  fi
  exit 2
fi
if [ -n "$_payload" ]; then
  if [ "$(printf '%s' "$_payload" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
    echo "[stop-check] stop_hook_active=true — bypassing to avoid infinite loop" >&2
    exit 0
  fi
fi

# Locate active plan file; CLAUDE_PLAN_FILE explicitly set but missing → skip cleanly.
if [ -n "${CLAUDE_PLAN_FILE:-}" ] && [ ! -f "$CLAUDE_PLAN_FILE" ]; then
  echo "[stop-check] CLAUDE_PLAN_FILE is set but file not found: ${CLAUDE_PLAN_FILE} — skipping" >&2
  exit 0
fi

# shellcheck source=lib/telegram-notify.sh
source "$(dirname "$0")/lib/telegram-notify.sh"
# shellcheck source=lib/active-plan.sh
source "$(dirname "$0")/lib/active-plan.sh"
# shellcheck source=phase-policy.sh
source "$(dirname "$0")/phase-policy.sh"
resolve_active_plan_and_phase active_plan phase || exit 0

# Human-must-clear marker: send Telegram notification and allow stop
if _hmc_found=$(marker_present_human_must_clear "$active_plan" 2>/dev/null); then
  _question=$(grep -F "[$_hmc_found" "$active_plan" | head -1)
  [[ -z "$_question" ]] && _question=$(grep -F "$_hmc_found" "$active_plan" | head -1)
  _slug=$(basename "$active_plan" .md)
  telegram_send_blocked_ambiguous "$_slug" "$_question" \
    "$HOME/.claude/channels/telegram/.env" \
    "$HOME/.claude/channels/telegram/access.json" 2>/dev/null || true
  echo "[stop-check] [$_hmc_found] detected — Telegram notified; allowing stop" >&2
  exit 0
fi

# Enforce in green and integration phases only (unit tests must pass in both).
# All other phases — brainstorm, spec, red, implement, review, done — are excluded.
# review is excluded: pr-review FAIL recovery phase; source modifications mid-cycle may break tests.
# implement is excluded: codex writes source to satisfy failing tests (via run-implement.sh).
# done is excluded: see header comment — session already closed, no test run needed.
phase_runs_stop_check "$phase" || exit 0

# if integration phase and a [BLOCKED] integration marker is already recorded,
# allow the stop without re-running tests to avoid infinite Stop-hook block loops.
# Reads from sidecar blocked.jsonl exclusively (no plan.md fallback).
if [ "$phase" = "integration" ]; then
  if bash "$PLAN_FILE_SH" is-blocked "$active_plan" integration 2>/dev/null; then
    echo "[stop-check] integration [BLOCKED] already recorded — allowing stop (sidecar self-halt)" >&2
    exit 0
  fi
fi

# Extract test command from project CLAUDE.md (## Commands → - Test: `cmd` line).
# Requires CLAUDE_PROJECT_DIR to be set — no PWD fallback to avoid reading the wrong CLAUDE.md.
if [ -z "${CLAUDE_PROJECT_DIR:-}" ]; then
  if [ "${CLAUDE_NONINTERACTIVE:-0}" = "1" ]; then
    bash "$PLAN_FILE_SH" record-stop-block "$active_plan" "$phase" \
      "CLAUDE_PROJECT_DIR unset — cannot locate CLAUDE.md for test command" 2>/dev/null || true
    echo "[STOP-BLOCKED] CLAUDE_PROJECT_DIR unset in autonomous mode — set CLAUDE_PROJECT_DIR and re-run" >&2
    exit 2
  fi
  echo "[stop-check] CLAUDE_PROJECT_DIR not set; skipping test verification" >&2
  exit 0
fi
test_cmd=""
_raw_test_line=""
claude_md="${CLAUDE_PROJECT_DIR}/CLAUDE.md"
claude_md_exists=0
if [ -f "$claude_md" ]; then
  claude_md_exists=1
  _raw_test_line=$(grep -E '^\- Test: ' "$claude_md" 2>/dev/null | head -1 || true)
  test_cmd=$(printf '%s' "$_raw_test_line" | sed 's/^- Test: *//;s/^`//;s/`$//' || true)
fi

# Skip if placeholder: checks both _raw_test_line (catches failed sed) and test_cmd (catches extracted placeholder).
# {word} pattern avoids false positives from legitimate brace usage like pytest --deselect 'tests/{foo}'.
if printf '%s' "$_raw_test_line" | grep -q "initializing-project" \
   || printf '%s' "$test_cmd" | grep -q "initializing-project" \
   || printf '%s' "$test_cmd" | grep -qE '\{[A-Za-z0-9_-]+\}' \
   || printf '%s' "$test_cmd" | grep -qE '<[a-z0-9_-]+>'; then
  if [ "${CLAUDE_NONINTERACTIVE:-0}" = "1" ] && [ "$claude_md_exists" -eq 1 ]; then
    bash "$PLAN_FILE_SH" record-stop-block "$active_plan" "$phase" \
      "Test command is a placeholder (run /initializing-project to fill in)" 2>/dev/null || true
    echo "BLOCKED [stop-check]: test command is a placeholder; autonomous run cannot verify tests. Run /initializing-project or set the Test line in CLAUDE.md (phase=${phase})." >&2
    exit 2
  fi
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
# macOS ships without GNU coreutils by default; check for gtimeout (Homebrew coreutils) or timeout.
_timeout="${CLAUDE_STOP_CHECK_TIMEOUT:-600}"
_timeout_cmd=""
if command -v gtimeout >/dev/null 2>&1; then
  _timeout_cmd="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
  _timeout_cmd="timeout"
fi

echo "[stop-check] Verifying tests pass before stop (phase=${phase}, CLAUDE_NONINTERACTIVE=1)..." >&2
_test_exit=0
if [ -n "$_timeout_cmd" ]; then
  "$_timeout_cmd" "$_timeout" bash -c "$test_cmd" >/dev/null 2>&1 || _test_exit=$?
else
  bash -c "$test_cmd" >/dev/null 2>&1 || _test_exit=$?
fi
if [ $_test_exit -eq 0 ]; then
  echo "[stop-check] Tests passed — stop allowed." >&2
  exit 0
elif [ -n "$_timeout_cmd" ] && [ $_test_exit -eq 124 ]; then
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
