#!/usr/bin/env bash
# Outputs one-line TUI status for the Claude Code statusLine display.
# Format: {phase} | last: {verdict-label}   (or "no active plan" if none found)
# Model invocations: none — shell only.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
plan_file=$("$SCRIPTS_DIR/plan-file.sh" find-active 2>/dev/null) || {
  echo "no active plan"
  exit 0
}

phase=$("$SCRIPTS_DIR/plan-file.sh" get-phase "$plan_file" 2>/dev/null || echo "?")

last_verdict=$(awk '
  /^## Critic Verdicts$/ { in_s=1; next }
  in_s && /^## /         { in_s=0 }
  in_s && /^- /          { line=$0 }
  END                    { sub(/^- /, "", line); print line }
' "$plan_file" 2>/dev/null)

if [ -n "$last_verdict" ]; then
  printf '%s | last: %s\n' "$phase" "$last_verdict"
else
  printf '%s | no verdicts yet\n' "$phase"
fi
