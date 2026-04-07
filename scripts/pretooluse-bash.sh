#!/usr/bin/env bash
# PreToolUse hook for Bash tool.
# Reads JSON from stdin, extracts .tool_input.command, blocks destructive patterns.
# Exit 2 = blocked; exit 0 = allowed.

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  echo "BLOCKED: jq is required but not found" >&2
  exit 2
fi

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ $? -ne 0 ]; then
  echo "BLOCKED: failed to parse hook input JSON" >&2
  exit 2
fi

# rm -rf / rm -fr (and sudo variants, and combined flags like -rdf)
if printf '%s' "$cmd" | grep -iqE \
  '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f([[:space:]/]|$)' \
  || printf '%s' "$cmd" | grep -iqE \
  '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*r([[:space:]/]|$)'; then
  echo "BLOCKED: destructive rm detected" >&2
  exit 2
fi

# dd disk write, mkfs, raw device write
if printf '%s' "$cmd" | grep -iqE \
  '(^|[;|&[:space:]])[[:space:]]*dd[[:space:]]+if=' \
  || printf '%s' "$cmd" | grep -iqE \
  '(^|[;|&[:space:]])[[:space:]]*mkfs[[:space:]./]' \
  || printf '%s' "$cmd" | grep -iqE \
  '>[[:space:]]*/dev/[sh]d[a-z]'; then
  echo "BLOCKED: destructive disk command detected" >&2
  exit 2
fi

# git push --force / -f
if printf '%s' "$cmd" | grep -iqE \
  'git[[:space:]]+push[[:space:]]+(.*[[:space:]]+)?(-f|--force)([[:space:]]|$)'; then
  echo "BLOCKED: git push --force detected" >&2
  exit 2
fi

# git clean -f
if printf '%s' "$cmd" | grep -iqE \
  'git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*f'; then
  echo "BLOCKED: git clean -f detected" >&2
  exit 2
fi

# SQL DDL: DROP/TRUNCATE TABLE|DATABASE|SCHEMA (word boundaries prevent false positives
# such as 'truncate table_backup.sql' or column names like drop_column)
if printf '%s' "$cmd" | grep -iqP \
  '\b(DROP|TRUNCATE)\s+(TABLE|DATABASE|SCHEMA)\b' 2>/dev/null \
  || printf '%s' "$cmd" | grep -iqE \
  '(^|[[:space:]])(DROP|TRUNCATE)[[:space:]]+(TABLE|DATABASE|SCHEMA)([[:space:]]|$)'; then
  echo "BLOCKED: destructive SQL DDL detected" >&2
  exit 2
fi

# git commit --no-verify (already in settings deny list; belt-and-suspenders)
if printf '%s' "$cmd" | grep -iqE \
  'git[[:space:]]+commit[[:space:]]+.*--no-verify'; then
  echo "BLOCKED: git commit --no-verify detected" >&2
  exit 2
fi

# git commit --amend: warn but allow (amending unpublished commits is legitimate)
if printf '%s' "$cmd" | grep -iqE \
  'git[[:space:]]+commit[[:space:]]+.*--amend'; then
  echo "WARNING: git commit --amend detected — ensure commit is not yet pushed" >&2
  # exit 0: allowed with warning
fi

exit 0
