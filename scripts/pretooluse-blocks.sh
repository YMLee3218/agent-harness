#!/usr/bin/env bash
# PreToolUse Bash hook — all blocking rules in 6 categories.
# Each function receives the command string as $1 and calls exit 2 on match.
# Source this file; do not execute directly.
#
# NOTE: This is a *mistake-prevention* gate, not a security boundary.
# Known bypass classes not coverable by text-pattern matching:
#   1. base64-encoded payloads decoded at runtime
#   2. dynamic variable-name construction (e.g. local -x v=CLAUDE_PLAN_CAPABILITY; ${v}=x)
#   3. nested heredoc / process substitution depth
set -euo pipefail
[[ -n "${_PRETOOLUSE_BLOCKS_LOADED:-}" ]] && return 0
_PRETOOLUSE_BLOCKS_LOADED=1

# shellcheck source=lib/pretooluse-target-blocks-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pretooluse-target-blocks-lib.sh"
# shellcheck source=capability.sh (provides shared _RING_C_FILES constant)
source "$(dirname "${BASH_SOURCE[0]}")/capability.sh"

# _dispatch_patterns CMD PATTERN... — test CMD against "regex|||message" patterns.
# Exits 2 with "BLOCKED: <message>" on first match. Each entry must contain exactly one '|||'.
_dispatch_patterns() {
  local cmd="$1" entry pat msg
  for entry in "${@:2}"; do
    pat="${entry%|||*}"; msg="${entry##*|||}"
    if printf '%s' "$cmd" | grep -iqE "$pat"; then
      echo "BLOCKED: ${msg}" >&2; exit 2
    fi
  done
}

# ── 1. block_destructive ──────────────────────────────────────────────────────
# Combines: rm, truncate/clobber, disk, git-clean, git-amend, cp-clobber, find-exec-rm
block_destructive() {
  local cmd="$1"
  # rm -rf variants
  if printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f([[:space:]/]|$)' \
    || printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*r([[:space:]/]|$)'; then
    echo "BLOCKED: destructive rm detected" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '\bfind\b[[:space:]].*\-delete\b'; then
    echo "BLOCKED: find -delete detected — use rm on specific paths instead" >&2; exit 2
  fi
  # disk commands
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*dd[[:space:]]+if=' \
    || printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*mkfs[[:space:]./]' \
    || printf '%s' "$cmd" | grep -iqE '>[[:space:]]*/dev/[sh]d[a-z]'; then
    echo "BLOCKED: destructive disk command detected" >&2; exit 2
  fi
  # git destructive operations
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*f'; then
    echo "BLOCKED: git clean -f detected" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+reset[[:space:]]+--hard'; then
    echo "BLOCKED: git reset --hard detected — destructive history operation not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+checkout[[:space:]]+(--|[^[:space:]]*[[:space:]]+--)[[:space:]]+[.\/]'; then
    echo "BLOCKED: git checkout -- (discard changes) detected" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '\bfind\b[[:space:]].*-exec[[:space:]]+(sudo[[:space:]]+)?rm[[:space:]]'; then
    echo "BLOCKED: find -exec rm detected — use explicit targeted rm instead" >&2; exit 2
  fi
}

# ── 2. block_execution ────────────────────────────────────────────────────────
# Combines: pipe-to-shell, awk-redirect-src-tests-plans
_PIPE_TO_SHELL_PATTERNS=(
  '\|[[:space:]]*(/[^[:space:]]*/)?((ba|z|k|da|a)?sh|dash)([[:space:]]+-[[:alpha:]]+)*([[:space:]]|$)|||pipe-to-shell detected'
  '(^|[;|&[:space:]])[[:space:]]*(/[^[:space:]]*/)?((ba|z|k|da|a|bu)?sh|dash)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[ic][a-zA-Z]*([[:space:]]|$)|||interactive/command-flag shell invocation detected'
  '\|[[:space:]]*(python3?|perl|ruby|node)[[:space:]]*(-[[:space:]])?([[:space:]]|$)|||pipe-to-interpreter detected'
)

block_execution() {
  local cmd="$1"
  _dispatch_patterns "$cmd" "${_PIPE_TO_SHELL_PATTERNS[@]}"
  # awk internal redirect to src/, tests/, or plans/
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])([[:space:]]*)awk[[:space:]]'; then
    if printf '%s' "$cmd" | grep -iqE 'print[[:space:]]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?src/' \
      || printf '%s' "$cmd" | grep -iqE 'print[[:space:]]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?tests/' \
      || printf '%s' "$cmd" | grep -iqE 'printf[[:space:]]+[^>]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?src/' \
      || printf '%s' "$cmd" | grep -iqE 'printf[[:space:]]+[^>]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?tests/' \
      || printf '%s' "$cmd" | grep -iqE '>{1,2}[[:space:]]*"?[^"[:space:]]*plans/[^"[:space:]]*\.state' \
      || printf '%s' "$cmd" | grep -iqE '>{1,2}[[:space:]]*"?plans/[^"[:space:]]*\.md'; then
      echo "BLOCKED: awk internal redirect to src/, tests/, or plans/ detected — use Write/Edit tool instead" >&2
      exit 2
    fi
  fi
}

# ── 3. block_sidecar_writes ───────────────────────────────────────────────────
# Combines: git-sidecar, ln, rm, awk-inplace, write-tools, interpreter targeting sidecar

_cmd_targets_sidecar() {
  local _raw="$1"
  printf '%s' "$_raw" | grep -qE 'plans/[^[:space:]'"'"'"]*\.state'
}

_cmd_targets_critic_lock() {
  local _raw="$1"
  printf '%s' "$_raw" | grep -qE 'plans/[^[:space:]'"'"'"]*\.critic\.lock'
}

block_sidecar_writes() {
  local cmd="$1"
  # A4: block mv/cp -r targeting the plans/ directory itself
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(mv|cp[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*)([[:space:]]+-[a-zA-Z]+)*[[:space:]]+(\.\/)?plans(/[[:space:]]|[[:space:]]|/$)'; then
    echo "BLOCKED: mv/cp -r targeting plans/ directory — plan directory structure is harness-exclusive" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+(checkout|restore|apply|am|revert|cherry-pick|update-ref|update-index|hash-object)[[:space:]]' && \
     _cmd_targets_sidecar "$cmd"; then
    echo "BLOCKED: git write operation targeting plans/*.state/ — sidecar is harness-exclusive" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]'; then
    if _cmd_targets_sidecar "$cmd"; then
      echo "BLOCKED: rm targeting plans/*.state/ — sidecar is harness-exclusive" >&2; exit 2
    fi
    if _cmd_targets_critic_lock "$cmd"; then
      echo "BLOCKED: rm targeting plans/*.critic.lock — critic loop lock is harness-exclusive" >&2; exit 2
    fi
  fi
  local _sw_p
  while IFS= read -r _sw_p; do
    [ -z "$_sw_p" ] && continue
    if is_sidecar_path "$_sw_p"; then
      echo "BLOCKED: write operation targeting plans/*.state/ — sidecar is harness-exclusive" >&2; exit 2
    fi
  done < <(_bash_dest_paths "$cmd")
}

# ── 4. block_capability ───────────────────────────────────────────────────────
# Combines: capability-spoofing, env-injection, unblock-command

block_capability() {
  local cmd="$1"
  # capability-spoofing: direct/export assignment and natural read form
  if printf '%s' "$cmd" | grep -qE 'CLAUDE_PLAN_CAPABILITY[[:space:]]*=' || \
     printf '%s' "$cmd" | grep -qE 'export[[:space:]]+CLAUDE_PLAN_CAPABILITY([[:space:]]|;|$)' || \
     printf '%s' "$cmd" | grep -qE '\bread[[:space:]]+([^[:space:]<]+[[:space:]]+)*CLAUDE_PLAN_CAPABILITY([[:space:]]|<|$)'; then
    echo "BLOCKED: CLAUDE_PLAN_CAPABILITY assignment in agent Bash command — capability spoofing is not permitted" >&2; exit 2
  fi
  # project-dir hijack: prevent agent from spawning child claude with detached hook root
  if printf '%s' "$cmd" | grep -qE 'CLAUDE_PROJECT_DIR[[:space:]]*=' || \
     printf '%s' "$cmd" | grep -qE 'export[[:space:]]+CLAUDE_PROJECT_DIR([[:space:]]|;|$)' || \
     printf '%s' "$cmd" | grep -qE '\bread[[:space:]]+([^[:space:]<]+[[:space:]]+)*CLAUDE_PROJECT_DIR([[:space:]]|<|$)'; then
    echo "BLOCKED: CLAUDE_PROJECT_DIR assignment in agent Bash command — would spawn child claude with detached hook root" >&2; exit 2
  fi
  # env-injection
  if printf '%s' "$cmd" | grep -qwE \
    'BASH_ENV|PROMPT_COMMAND|PS4|SHELLOPTS|BASHOPTS|LD_PRELOAD|LD_AUDIT|DYLD_INSERT_LIBRARIES|PHASE_GATE_STRICT'; then
    echo "BLOCKED: shell startup / library-injection env var detected" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -qE '(^|[[:space:];|&])[[:space:]]*ENV[[:space:]]*='; then
    echo "BLOCKED: ENV= assignment — sources file before commands run" >&2; exit 2
  fi
}

# ── 5. block_plan_revert ─────────────────────────────────────────────────────
# Blocks git revert/stash/reset operations targeting plan files when a
# HUMAN_MUST_CLEAR_MARKERS entry is active (marker-conditional).
block_plan_revert() {
  local cmd="$1"
  [[ -z "${PLAN_FILE_SH:-}" ]] && return 0
  local _active_plan="" _phase=""
  resolve_active_plan_and_phase _active_plan _phase 2>/dev/null || return 0
  marker_present_human_must_clear "$_active_plan" >/dev/null 2>&1 || return 0
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+(checkout|restore|apply|am|revert|cherry-pick)[[:space:]]' && \
     printf '%s' "$cmd" | grep -qE 'plans/[^[:space:]]*\.md'; then
    echo "BLOCKED: git operation targeting plans/*.md while human-must-clear marker active — resolve the block first" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[[:space:];|&])git[[:space:]]+stash([[:space:];|&]|$)'; then
    echo "BLOCKED: git stash while human-must-clear marker active — resolve the block first" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+reset[[:space:]]+--[[:space:]]*(soft|mixed)[[:space:]]'; then
    echo "BLOCKED: git reset --soft/--mixed while human-must-clear marker active — resolve the block first" >&2; exit 2
  fi
}
