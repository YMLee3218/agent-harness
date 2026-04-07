#!/usr/bin/env bash
# PreToolUse hook for Bash tool.
# Reads JSON from stdin, extracts .tool_input.command, blocks destructive patterns.
# Exit 2 = blocked; exit 0 = allowed.

input=$(cat)

# Parse command from JSON — prefer jq, fall back to python3
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
  cmd=$(printf '%s' "$input" | python3 -c \
    'import sys,json; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("command",""))' \
    2>/dev/null)
fi

if printf '%s' "$cmd" | grep -qE \
  '(^|[[:space:]])rm[[:space:]]+-rf[[:space:]]|drop[[:space:]]+table|truncate[[:space:]]+table'; then
  echo "BLOCKED: destructive command" >&2
  exit 2
fi

exit 0
