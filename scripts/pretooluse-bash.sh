#!/usr/bin/env bash
# PreToolUse hook for Bash tool.
# Reads JSON from stdin, extracts .tool_input.command, blocks destructive patterns.
# Exit 2 = blocked; exit 0 = allowed.
#
# Test cases (all must exit 2):
#   echo '{"tool_input":{"command":"rm -rf /tmp/x"}}' | bash pretooluse-bash.sh
#   echo '{"tool_input":{"command":"rm -rf/tmp/x"}}' | bash pretooluse-bash.sh
#   echo '{"tool_input":{"command":"sudo rm -rf /"}}' | bash pretooluse-bash.sh
#   echo '{"tool_input":{"command":"dd if=/dev/zero of=/dev/sda"}}' | bash pretooluse-bash.sh
#   echo '{"tool_input":{"command":"mkfs.ext4 /dev/sdb1"}}' | bash pretooluse-bash.sh
#   echo '{"tool_input":{"command":"echo x > /dev/sda"}}' | bash pretooluse-bash.sh
#   echo '{"tool_input":{"command":"git push --force"}}' | bash pretooluse-bash.sh
#   echo '{"tool_input":{"command":"git push -f origin main"}}' | bash pretooluse-bash.sh
#   echo '{"tool_input":{"command":"git clean -fd ."}}' | bash pretooluse-bash.sh
#   echo '{"tool_input":{"command":"DROP TABLE users"}}' | bash pretooluse-bash.sh
#   echo '{"tool_input":{"command":"TRUNCATE TABLE orders"}}' | bash pretooluse-bash.sh
#
# Test cases (all must exit 0):
#   echo '{"tool_input":{"command":"ls -rf /tmp"}}' | bash pretooluse-bash.sh
#   echo '{"tool_input":{"command":"git push origin feature/x"}}' | bash pretooluse-bash.sh

input=$(cat)

# Parse command from JSON — prefer jq, fall back to python3
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
  cmd=$(printf '%s' "$input" | python3 -c \
    'import sys,json; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("command",""))' \
    2>/dev/null)
fi

# Block destructive patterns.
# Note: settings.json already lists Bash(rm *) and Bash(git push *) as "ask",
# so the UI prompts the user first. This hook is the final barrier if that guard is bypassed.
if printf '%s' "$cmd" | grep -iqE \
  '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f([[:space:]/]|$)' \
  || printf '%s' "$cmd" | grep -iqE \
  '(^|[;|&[:space:]])[[:space:]]*dd[[:space:]]+if=' \
  || printf '%s' "$cmd" | grep -iqE \
  '(^|[;|&[:space:]])[[:space:]]*mkfs[[:space:]./]' \
  || printf '%s' "$cmd" | grep -iqE \
  '>[[:space:]]*/dev/[sh]d[a-z]' \
  || printf '%s' "$cmd" | grep -iqE \
  'git[[:space:]]+push[[:space:]]+(.*[[:space:]]+)?(-f|--force)([[:space:]]|$)' \
  || printf '%s' "$cmd" | grep -iqE \
  'git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*f' \
  || printf '%s' "$cmd" | grep -iqE \
  '(drop|truncate)[[:space:]]+table'; then
  echo "BLOCKED: destructive command detected" >&2
  exit 2
fi

exit 0
