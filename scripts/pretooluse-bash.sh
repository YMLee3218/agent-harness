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
# If input was provided but command field is missing/empty, block rather than silently allow
if [ -z "$cmd" ] && [ -n "$input" ]; then
  echo "BLOCKED: could not extract command field from hook input" >&2
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

# chmod world-writable: octal modes granting others write (e.g. 777, 775, 757),
# or symbolic modes o+w / a+w
if printf '%s' "$cmd" | grep -iqE \
  'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?[0-7]*[2367][0-7][0-7]([[:space:]]|$)' \
  || printf '%s' "$cmd" | grep -iqE \
  'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?(o|a)\+[rwx]*w'; then
  echo "BLOCKED: world-writable chmod detected" >&2
  exit 2
fi

# eval / source with command substitution — dynamic code execution via injected input
if printf '%s' "$cmd" | grep -iqE \
  '(^|[;|&[:space:]])[[:space:]]*eval[[:space:]]+[^[:space:]]*\$\(' \
  || printf '%s' "$cmd" | grep -iqE \
  '(^|[;|&[:space:]])[[:space:]]*source[[:space:]]+<\('; then
  echo "BLOCKED: eval/source with command substitution detected" >&2
  exit 2
fi

# Phase-aware bash write detection: catches > file, tee file, cat > file redirections that
# bypass the Write|Edit PreToolUse phase gate. Guardrail only — not a security boundary.
_plan_file_sh="$(dirname "$0")/plan-file.sh"
if [ -f "$_plan_file_sh" ]; then
  # Use CLAUDE_PLAN_FILE when set to avoid find-active overhead on every Bash call
  if [ -n "${CLAUDE_PLAN_FILE:-}" ] && [ -f "$CLAUDE_PLAN_FILE" ]; then
    _active_plan="$CLAUDE_PLAN_FILE"
  else
    _active_plan=$(bash "$_plan_file_sh" find-active 2>/dev/null || echo "")
  fi
  if [ -n "$_active_plan" ]; then
    _current_phase=$(bash "$_plan_file_sh" get-phase "$_active_plan" 2>/dev/null || echo "")
    if [ -n "$_current_phase" ]; then
      _writes_src=0; _writes_test=0
      # Detect redirects to source paths: > src/, >> src/, tee src/
      printf '%s' "$cmd" | grep -iqE \
        '(>{1,2}[[:space:]]*)([^[:space:]]*/)?src/|tee[[:space:]]+([^[:space:]]*/)?src/' \
        && _writes_src=1 || true
      # Detect redirects to test paths: > tests/, >> tests/, tee tests/, or *_test.* / *.test.*
      printf '%s' "$cmd" | grep -iqE \
        '(>{1,2}[[:space:]]*)([^[:space:]]*/)?tests/|tee[[:space:]]+([^[:space:]]*/)?tests/|(>{1,2}[[:space:]]*)([^[:space:]]*)(_test\.|\.test\.)' \
        && _writes_test=1 || true
      case "$_current_phase" in
        brainstorm|spec)
          if [ "$_writes_src" -eq 1 ]; then
            echo "BLOCKED [phase-gate/bash]: Phase is '$_current_phase'. Bash redirect to src/ detected — use Write/Edit tool (enforced by phase-gate)." >&2; exit 2
          fi
          if [ "$_writes_test" -eq 1 ]; then
            echo "BLOCKED [phase-gate/bash]: Phase is '$_current_phase'. Bash redirect to test path detected — complete /writing-spec first." >&2; exit 2
          fi
          ;;
        red)
          if [ "$_writes_src" -eq 1 ]; then
            echo "BLOCKED [phase-gate/bash]: Phase is 'red'. Bash redirect to src/ detected — write tests only during Red phase." >&2; exit 2
          fi
          ;;
        green|integration)
          if [ "$_writes_test" -eq 1 ]; then
            echo "BLOCKED [phase-gate/bash]: Phase is '$_current_phase'. Bash redirect to test path detected — tests are frozen during this phase." >&2; exit 2
          fi
          ;;
        done)
          if [ "$_writes_src" -eq 1 ] || [ "$_writes_test" -eq 1 ]; then
            echo "BLOCKED [phase-gate/bash]: Phase is 'done'. Bash redirect to src/ or test path — run /initializing-project to start a new feature." >&2; exit 2
          fi
          ;;
      esac
    fi
  fi
fi

exit 0
