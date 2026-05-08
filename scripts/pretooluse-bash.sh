#!/usr/bin/env bash
# PreToolUse hook for Bash tool.
# Reads JSON from stdin, extracts .tool_input.command, blocks destructive patterns.
# Exit 2 = blocked; exit 0 = allowed.
#
# NOTE: This is a *mistake-prevention* gate, not a security boundary.
set -uo pipefail
# shellcheck source=lib/active-plan.sh
source "$(dirname "$0")/lib/active-plan.sh"

input=$(cat)

require_jq_or_block "pretooluse-bash"

cmd=$(extract_tool_input_command "$input")
if [ $? -ne 0 ]; then
  echo "BLOCKED: failed to parse hook input JSON" >&2
  exit 2
fi
if [ -z "$cmd" ] && [ -n "$input" ]; then
  echo "BLOCKED: could not extract command field from hook input" >&2
  exit 2
fi

# Block Claude from clearing markers that require human judgement to resolve
# (humans bypass this hook by running from terminal directly)
if printf '%s' "$cmd" | grep -qE "plan-file\\.sh[\"'[:space:]].*clear-marker"; then
  if printf '%s' "$cmd" | grep -qE 'BLOCKED-AMBIGUOUS|BLOCKED\] (protocol-violation|category:|parse:|integration:|preflight:)|: session-timeout|: script-failure|: no timeout binary|: plan unchanged'; then
    echo "BLOCKED: this marker cannot be cleared by Claude — human must run plan-file.sh clear-marker directly from terminal" >&2
    exit 2
  fi
fi

# Block Claude from using 'unblock' — human-only convenience command
if printf '%s' "$cmd" | grep -qE "plan-file\\.sh[\"'[:space:]].*unblock[[:space:]]"; then
  echo "BLOCKED: 'unblock' is a human-only command — run plan-file.sh unblock from terminal" >&2
  exit 2
fi

# rm -rf / rm -fr
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

# git clean -f
if printf '%s' "$cmd" | grep -iqE \
  'git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*f'; then
  echo "BLOCKED: git clean -f detected" >&2
  exit 2
fi

# SQL DDL: DROP/TRUNCATE TABLE|DATABASE|SCHEMA
if printf '%s' "$cmd" | grep -iqE \
  '(^|[[:space:]])(DROP|TRUNCATE)[[:space:]]+(TABLE|DATABASE|SCHEMA)([[:space:]]|$)'; then
  echo "BLOCKED: destructive SQL DDL detected" >&2
  exit 2
fi

# git commit --amend: block if HEAD is already pushed
if printf '%s' "$cmd" | grep -iqE \
  'git[[:space:]]+commit[[:space:]]+.*--amend'; then
  if git branch -r --contains HEAD 2>/dev/null | grep -q .; then
    echo "BLOCKED: git commit --amend on a commit already pushed to remote. Create a new commit instead to avoid requiring force-push." >&2
    exit 2
  fi
  echo "WARNING: git commit --amend detected — commit is not yet pushed (safe to amend)" >&2
fi

# git -c core.hooksPath bypass
if printf '%s' "$cmd" | grep -iqE \
  'git[[:space:]]+-c[[:space:]]+[^=]*[Hh]ooks[Pp]ath'; then
  echo "BLOCKED: git -c hooksPath override detected (hook bypass attempt)" >&2
  exit 2
fi

# Pipe-to-shell
if printf '%s' "$cmd" | grep -iqE \
  '\|[[:space:]]*(ba)?sh([[:space:]]+-[[:alpha:]]+)*([[:space:]]|$)'; then
  echo "BLOCKED: pipe-to-shell detected" >&2
  exit 2
fi

# chmod world-writable
if printf '%s' "$cmd" | grep -iqE \
  'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?[0-7]{2,3}[2367]([[:space:]]|$)' \
  || printf '%s' "$cmd" | grep -iqE \
  'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?(o|a)\+[rwx]*w'; then
  echo "BLOCKED: world-writable chmod detected" >&2
  exit 2
fi

# eval / source with command substitution
if printf '%s' "$cmd" | grep -iqE \
  '(^|[;|&[:space:]])[[:space:]]*eval[[:space:]]+[^[:space:]]*\$\(' \
  || printf '%s' "$cmd" | grep -iqE \
  '(^|[;|&[:space:]])[[:space:]]*source[[:space:]]+<\('; then
  echo "BLOCKED: eval/source with command substitution detected" >&2
  exit 2
fi

# awk internal redirect to src/ or tests/
if printf '%s' "$cmd" | grep -iqE \
  '(^|[;|&[:space:]])([[:space:]]*)awk[[:space:]]'; then
  if printf '%s' "$cmd" | grep -iqE \
    'print[[:space:]]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?src/' \
    || printf '%s' "$cmd" | grep -iqE \
    'print[[:space:]]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?tests/' \
    || printf '%s' "$cmd" | grep -iqE \
    'printf[[:space:]]+[^>]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?src/' \
    || printf '%s' "$cmd" | grep -iqE \
    'printf[[:space:]]+[^>]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?tests/'; then
    echo "BLOCKED: awk internal redirect to src/ or tests/ detected — use Write/Edit tool instead" >&2
    exit 2
  fi
fi

# Phase-aware bash write detection
# shellcheck source=phase-policy.sh
source "$(dirname "$0")/phase-policy.sh"
PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"

_bash_dest_paths() {
  local c="$1"
  printf '%s' "$c" | grep -oE '>{1,2} *[^[:space:]]+' | sed 's/^>* *//'
  printf '%s' "$c" | grep -oE '\btee( +[^[:space:]]+)+' | sed 's/^tee *//' | tr ' ' '\n' | grep -v '^-'
  printf '%s' "$c" | grep -oE '\bcp +[^[:space:]]+ +[^[:space:]]+' | awk '{print $NF}'
  printf '%s' "$c" | grep -oE '\bmv +[^[:space:]]+ +[^[:space:]]+' | awk '{print $NF}'
  printf '%s' "$c" | grep -oE '\bsed +-i[^ ]*( +[^[:space:];|&]+)+' | awk '{print $NF}'
}

if [ -f "$PLAN_FILE_SH" ]; then
  BLOCKED_LABEL="phase-gate/bash"
  if resolve_active_plan_and_phase _active_plan _current_phase; then
    # [BLOCKED-AMBIGUOUS] → block all bash writes (consistent with phase-gate.sh)
    if grep -qF "[BLOCKED-AMBIGUOUS]" "$_active_plan" 2>/dev/null; then
      _ba_write=0
      while IFS= read -r _ba_p; do [ -n "$_ba_p" ] && _ba_write=1 && break; done < <(_bash_dest_paths "$cmd")
      [ "$_ba_write" -eq 1 ] && { echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — write prohibited; human must resolve the question and clear the marker from terminal" >&2; exit 2; }
      # Also block interpreter inline execution (python3 -c, perl -e, etc.) — not caught by _bash_dest_paths
      if printf '%s' "$cmd" | grep -qE '(python3?|perl|ruby|node)[[:space:]]+-[ceE][[:space:]]'; then
        echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — interpreter inline execution prohibited; human must resolve the question and clear the marker from terminal" >&2
        exit 2
      fi
    fi
    while IFS= read -r _dest_p; do
      [ -z "$_dest_p" ] && continue
      apply_phase_block "$_dest_p" "$_current_phase" "phase-gate/bash" || exit 2
    done < <(_bash_dest_paths "$cmd")
  else
    while IFS= read -r _dest_p; do
      [ -z "$_dest_p" ] && continue
      bootstrap_block_if_strict "$_dest_p" || exit 2
    done < <(_bash_dest_paths "$cmd")
  fi
fi

exit 0
