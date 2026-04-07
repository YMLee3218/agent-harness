#!/usr/bin/env bash
# PreToolUse hook for Bash tool.
# Reads JSON from stdin, extracts .tool_input.command, blocks destructive patterns.
# Exit 2 = blocked; exit 0 = allowed.
#
# NOTE: This is a *mistake-prevention* gate, not a security boundary.
# Pattern matching can be bypassed via base64/eval/variable expansion.
# Treat it as a guardrail against accidental destructive commands, not a hardened sandbox.
set -uo pipefail

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

# SQL DDL: DROP/TRUNCATE TABLE|DATABASE|SCHEMA
# Uses ERE (no PCRE) to be portable on macOS/BSD grep
if printf '%s' "$cmd" | grep -iqE \
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

# git commit --amend: block if HEAD is already pushed; warn-only if unpublished
if printf '%s' "$cmd" | grep -iqE \
  'git[[:space:]]+commit[[:space:]]+.*--amend'; then
  # Check whether HEAD appears in any remote tracking branch (already pushed)
  if git branch -r --contains HEAD 2>/dev/null | grep -q .; then
    echo "BLOCKED: git commit --amend on a commit already pushed to remote. Create a new commit instead to avoid requiring force-push." >&2
    exit 2
  fi
  echo "WARNING: git commit --amend detected — commit is not yet pushed (safe to amend)" >&2
  # exit 0: allowed with warning
fi

# git -c core.hooksPath bypass
if printf '%s' "$cmd" | grep -iqE \
  'git[[:space:]]+-c[[:space:]]+[^=]*[Hh]ooks[Pp]ath'; then
  echo "BLOCKED: git -c hooksPath override detected (hook bypass attempt)" >&2
  exit 2
fi

# Pipe-to-shell: echo payload | bash/sh (command injection vector)
if printf '%s' "$cmd" | grep -iqE \
  '\|[[:space:]]*(ba)?sh([[:space:]]+-[[:alpha:]]+)*([[:space:]]|$)'; then
  echo "BLOCKED: pipe-to-shell detected" >&2
  exit 2
fi

exit 0
