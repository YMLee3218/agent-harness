#!/usr/bin/env bash
# PreToolUse hook for Bash tool.
# Reads JSON from stdin, extracts .tool_input.command, blocks destructive patterns.
# Exit 2 = blocked; exit 0 = allowed.
#
# NOTE: This is a *mistake-prevention* gate, not a security boundary.
set -uo pipefail
# shellcheck source=lib/active-plan.sh
source "$(dirname "$0")/lib/active-plan.sh"
# shellcheck source=phase-policy.sh
source "$(dirname "$0")/phase-policy.sh"

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

# Block CLAUDE_PLAN_CAPABILITY= spoofing — only harness scripts may set this env var.
# Covers: VAR=val, read -r VAR, printf -v VAR, export VAR, declare/typeset/local/readonly VAR (all assignment forms).
if printf '%s' "$cmd" | grep -qE 'CLAUDE_PLAN_CAPABILITY[[:space:]]*=' || \
   printf '%s' "$cmd" | grep -qE 'read[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+CLAUDE_PLAN_CAPABILITY' || \
   printf '%s' "$cmd" | grep -qE 'printf[[:space:]]+-v[[:space:]]+CLAUDE_PLAN_CAPABILITY' || \
   printf '%s' "$cmd" | grep -qE 'export[[:space:]]+CLAUDE_PLAN_CAPABILITY([[:space:]]|$)' || \
   printf '%s' "$cmd" | grep -qE '(declare|typeset|local|readonly)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?CLAUDE_PLAN_CAPABILITY([[:space:]]|=|$)'; then
  echo "BLOCKED: CLAUDE_PLAN_CAPABILITY assignment in agent Bash command — capability spoofing is not permitted" >&2
  exit 2
fi
# Coarse literal block — catches indirect assignment via variable indirection
# (e.g. V=CLAUDE_PLAN_CAPABILITY; export "$V=harness"). Bypasses via eval+string-concat
# or split-turn source (which produce no literal) require P1 PPID chain validation.
if printf '%s' "$cmd" | grep -qF 'CLAUDE_PLAN_CAPABILITY'; then
  echo "BLOCKED: command references CLAUDE_PLAN_CAPABILITY — agents must not name this capability" >&2
  exit 2
fi

# Block BASH_ENV/ENV/PROMPT_COMMAND assignment — these env vars source arbitrary files on shell startup.
if printf '%s' "$cmd" | grep -qE '(BASH_ENV|^ENV|[[:space:]]ENV|PROMPT_COMMAND)[[:space:]]*='; then
  echo "BLOCKED: BASH_ENV/ENV/PROMPT_COMMAND assignment — these source files before commands run" >&2
  exit 2
fi

# Block Claude from clearing markers that require human judgement to resolve.
# Pattern list: HUMAN_MUST_CLEAR_MARKERS in scripts/phase-policy.sh (single source of truth).
# Humans bypass this hook by running from terminal directly.
if printf '%s' "$cmd" | grep -qE "(plan-file\\.sh|\\\$PLAN_FILE_SH|\\\$\{PLAN_FILE_SH\})[\"'[:space:]].*clear-marker"; then
  for _hm in "${HUMAN_MUST_CLEAR_MARKERS[@]}"; do
    if printf '%s' "$cmd" | grep -qF "$_hm"; then
      echo "BLOCKED: this marker cannot be cleared by Claude — human must run plan-file.sh clear-marker directly from terminal" >&2
      exit 2
    fi
  done
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

# git checkout/restore/apply targeting plans/*.state (sidecar write)
if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+(checkout|restore|apply)[[:space:]]' && \
   printf '%s' "$cmd" | grep -qE 'plans/[^[:space:]'"'"'"]*\.state'; then
  echo "BLOCKED: git write operation targeting plans/*.state/ — sidecar is harness-exclusive" >&2
  exit 2
fi

# ln / ln -s targeting plans/*.state (symlink redirect attack — C1-5th)
if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*ln[[:space:]]'; then
  if printf '%s' "$cmd" | grep -qE 'plans/[^[:space:]'"'"'"]*\.state'; then
    echo "BLOCKED: ln operation targeting plans/*.state/ — symlink redirect attacks are not permitted" >&2
    exit 2
  fi
fi

# rm targeting plans/*.state or the critic loop lock file alongside plan files
if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]'; then
  if printf '%s' "$cmd" | grep -qE 'plans/[^[:space:]'"'"'"]*\.state'; then
    echo "BLOCKED: rm targeting plans/*.state/ — sidecar is harness-exclusive" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -qE 'plans/[^[:space:]'"'"'"]*\.critic\.lock'; then
    echo "BLOCKED: rm targeting plans/*.critic.lock — critic loop lock is harness-exclusive" >&2
    exit 2
  fi
fi

# awk -i inplace targeting plans/*.state
if printf '%s' "$cmd" | grep -iqE 'awk[[:space:]]+-i[[:space:]]*(inplace|in-place)' && \
   printf '%s' "$cmd" | grep -qE 'plans/[^[:space:]'"'"'"]*\.state'; then
  echo "BLOCKED: awk -i inplace targeting plans/*.state/ — sidecar is harness-exclusive" >&2
  exit 2
fi

# rsync/install/patch/unzip/tar targeting plans/*.state (unconditional — not just under BLOCKED-AMBIGUOUS)
if printf '%s' "$cmd" | grep -qE 'plans/[^[:space:]'"'"'"]*\.state'; then
  if printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*(rsync[[:space:]]|install[[:space:]]|patch[[:space:]]|unzip[[:space:]]|tar[[:space:]]+-[[:alpha:]]*[xX])'; then
    echo "BLOCKED: write tool targeting plans/*.state/ — sidecar is harness-exclusive" >&2
    exit 2
  fi
fi

# Interpreter inline execution or redirect targeting plans/*.state
if printf '%s' "$cmd" | grep -qE 'plans/[^[:space:]'"'"'"]*\.state/'; then
  if printf '%s' "$cmd" | grep -qE \
    '(python3?|perl|ruby|node|php|lua|R)[[:space:]]+-[ceEr][^[:alpha:]]|>{1,2}[[:space:]]*[^[:space:]]*plans/[^[:space:]'"'"'"]*\.state/'; then
    echo "BLOCKED: write operation targeting plans/*.state/ — sidecar is harness-exclusive" >&2
    exit 2
  fi
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
PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"

_bash_dest_paths() {
  local c="$1"
  printf '%s' "$c" | grep -oE '>{1,2} *[^[:space:]]+' | sed 's/^>* *//'
  printf '%s' "$c" | grep -oE '\btee( +[^[:space:]]+)+' | sed 's/^tee *//' | tr ' ' '\n' | grep -v '^-'
  printf '%s' "$c" | grep -oE '\bcp +[^[:space:]]+ +[^[:space:]]+' | awk '{print $NF}'
  printf '%s' "$c" | grep -oE '\bmv +[^[:space:]]+ +[^[:space:]]+' | awk '{print $NF}'
  printf '%s' "$c" | grep -oE '\bsed +-i[^ ]*( +[^[:space:];|&]+)+' | awk '{print $NF}'
  printf '%s' "$c" | grep -oE '\bdd\b[^|]*\bof=[^[:space:]]+' | grep -oE '\bof=[^[:space:]]+' | sed 's/^of=//'
  # Best-effort: extract write-target paths from interpreter inline execution for phase enforcement.
  # Covers: python3 -c "open('path','w')", node -e "fs.writeFileSync('path',...)",
  #         ruby -e "File.open('path','w')", perl -e "open(FH,'>','path')"
  # Sidecar paths are caught independently by the full-command-text patterns above (lines 109-115).
  if printf '%s' "$c" | grep -qE '(python3?|perl|ruby|node|php|lua|R)[[:space:]]+-[ceEr][^[:alpha:]]'; then
    printf '%s' "$c" | \
      grep -oE "(open|write|writeFileSync|appendFileSync|createWriteStream|write_text)\(['\"][^'\"]+['\"]" | \
      grep -oE "['\"][^'\"]+['\"]" | tr -d "'\""
  fi
}

if [ -f "$PLAN_FILE_SH" ]; then
  BLOCKED_LABEL="phase-gate/bash"
  if resolve_active_plan_and_phase _active_plan _current_phase; then
    # [BLOCKED-AMBIGUOUS] → block all bash writes (consistent with phase-gate.sh)
    if grep -qF "[BLOCKED-AMBIGUOUS]" "$_active_plan" 2>/dev/null; then
      _ba_write=0
      while IFS= read -r _ba_p; do [ -n "$_ba_p" ] && _ba_write=1 && break; done < <(_bash_dest_paths "$cmd")
      [ "$_ba_write" -eq 1 ] && { echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — write prohibited; human must resolve the question and clear the marker from terminal" >&2; exit 2; }
      # A) Standard inline flag: -c/-e/-E/-r (python, perl, ruby, node, php, lua, R)
      # [^[:alpha:]] catches both `python3 -c 'code'` and `python3 -c'code'` (no space).
      if printf '%s' "$cmd" | grep -qE \
        '(python3?|perl|ruby|node|php|lua|R)[[:space:]]+-[ceEr][^[:alpha:]]'; then
        echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — interpreter inline execution prohibited" >&2; exit 2
      fi
      # B) Heredoc execution — space before << is optional in bash.
      if printf '%s' "$cmd" | grep -qE \
        '(python3?|perl|ruby|node|php|lua|R)[[:space:]]*(<<|<<-)'; then
        echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — interpreter heredoc execution prohibited" >&2; exit 2
      fi
      # C) Shell inline execution — [^[:alpha:]] catches both `-c cmd` and `-c'cmd'`.
      if printf '%s' "$cmd" | grep -qE \
        '(bash|sh|zsh|ksh|dash)[[:space:]]+-c[^[:alpha:]]'; then
        echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — shell inline execution prohibited" >&2; exit 2
      fi
      # D) File install/copy tools not caught by _bash_dest_paths (rsync, git apply, patch, unzip, install)
      if printf '%s' "$cmd" | grep -qE \
        '(^|[;|&[:space:]])[[:space:]]*(rsync|git[[:space:]]+apply|patch[[:space:]]|unzip[[:space:]]|install[[:space:]])'; then
        echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — file-install command prohibited" >&2; exit 2
      fi
      # E) tar extraction (x/X flags)
      if printf '%s' "$cmd" | grep -qE \
        '(^|[;|&[:space:]])[[:space:]]*tar[[:space:]]+-[[:alpha:]]*[xX]'; then
        echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — tar extraction prohibited" >&2; exit 2
      fi
    fi
    while IFS= read -r _dest_p; do
      [ -z "$_dest_p" ] && continue
      if is_sidecar_path "$_dest_p"; then
        echo "BLOCKED [phase-gate/bash]: plans/{slug}.state/ is harness-exclusive — write denied" >&2; exit 2
      fi
      apply_phase_block "$_dest_p" "$_current_phase" "phase-gate/bash" || exit 2
    done < <(_bash_dest_paths "$cmd")
  else
    while IFS= read -r _dest_p; do
      [ -z "$_dest_p" ] && continue
      if is_sidecar_path "$_dest_p"; then
        echo "BLOCKED [phase-gate/bash]: plans/{slug}.state/ is harness-exclusive — write denied" >&2; exit 2
      fi
      bootstrap_block_if_strict "$_dest_p" || exit 2
    done < <(_bash_dest_paths "$cmd")
  fi
fi

exit 0
