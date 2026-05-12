#!/usr/bin/env bash
# PreToolUse Bash hook — all blocking rules in 7 categories.
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
# shellcheck source=lib/hook-dispatch.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/hook-dispatch.sh" 2>/dev/null || true
# shellcheck source=capability.sh (provides shared _RING_C_FILES constant)
source "$(dirname "${BASH_SOURCE[0]}")/capability.sh"

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
  if printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+(\$PWD|\$\(pwd\)|`pwd`)'; then
    echo "BLOCKED: destructive rm targeting current directory detected" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '\bfind\b[[:space:]].*\-delete\b'; then
    echo "BLOCKED: find -delete detected — use rm on specific paths instead" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'rsync[[:space:]]+[^;|&]*--delete(-[a-z]+)?'; then
    echo "BLOCKED: rsync --delete detected — destructive sync not permitted" >&2; exit 2
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
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+checkout[[:space:]]+(--|\.)[[:space:]]*(|$)' || \
     printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+checkout[[:space:]]+\.[[:space:]]*(;|$|&&|\|\|)'; then
    echo "BLOCKED: git checkout . (discard all changes) detected" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?cp[[:space:]]+/dev/null[[:space:]]+'; then
    echo "BLOCKED: cp /dev/null (file clobber) detected — destructive file deletion not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '\bfind\b[[:space:]].*-exec[[:space:]]+(sudo[[:space:]]+)?rm[[:space:]]'; then
    echo "BLOCKED: find -exec rm detected — use explicit targeted rm instead" >&2; exit 2
  fi
}

# ── 2. block_execution ────────────────────────────────────────────────────────
# Combines: pipe-to-shell, eval/source, world-writable-chmod, awk-redirect-src-tests
_PIPE_TO_SHELL_PATTERNS=(
  '\|[[:space:]]*(command[[:space:]]+|exec[[:space:]]+|env([[:space:]]+-[a-zA-Z]+)*[[:space:]]+)?(/[^[:space:]]*/)?((ba|z|k|da|a)?sh|dash)([[:space:]]+-[[:alpha:]]+)*([[:space:]]|$)|||pipe-to-shell detected'
  '(^|[;|&[:space:]])[[:space:]]*(env[[:space:]]+(-[iSu0]+[[:space:]]+|[A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]+)*|nice[[:space:]]+[^|&;]*|nohup[[:space:]]+[^|&;]*|exec[[:space:]]+)?(/[^[:space:]]*/)?((ba|z|k|da|a|bu)?sh|dash)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[ic][a-zA-Z]*([[:space:]]|$)|||interactive/command-flag shell invocation detected'
  '\|[[:space:]]*(command[[:space:]]+|exec[[:space:]]+)?busybox[[:space:]]+sh([[:space:]]|$)|||pipe-to-busybox-sh detected'
  '\|[[:space:]]*(python3?|perl|ruby|node(js)?|php|lua|R|deno|tsx?)[[:space:]]*(-[[:space:]])?([[:space:]]|$)|||pipe-to-interpreter detected'
)

_EVAL_SOURCE_PATTERNS=(
  '(^|[;|&[:space:]])[[:space:]]*eval[[:space:]].*\$\(|||eval with command substitution detected'
  '(^|[;|&[:space:]])[[:space:]]*source[[:space:]]+<\(|||source with process substitution detected'
  '(^|[;|&[:space:]])[[:space:]]*(eval|source|\.)[[:space:]]+[^[:space:]]*`|||eval/source with backtick detected'
)

block_execution() {
  local cmd="$1"
  _dispatch_patterns "$cmd" "${_PIPE_TO_SHELL_PATTERNS[@]}"
  _dispatch_patterns "$cmd" "${_EVAL_SOURCE_PATTERNS[@]}"
  # world-writable chmod
  if printf '%s' "$cmd" | grep -iqE \
    'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?[0-7]{2,3}[2367]([[:space:]]|$)' \
    || printf '%s' "$cmd" | grep -iqE \
    'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?(o|a)\+[rwx]*w'; then
    echo "BLOCKED: world-writable chmod detected" >&2; exit 2
  fi
  # awk internal redirect to src/ or tests/
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])([[:space:]]*)awk[[:space:]]'; then
    if printf '%s' "$cmd" | grep -iqE 'print[[:space:]]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?src/' \
      || printf '%s' "$cmd" | grep -iqE 'print[[:space:]]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?tests/' \
      || printf '%s' "$cmd" | grep -iqE 'printf[[:space:]]+[^>]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?src/' \
      || printf '%s' "$cmd" | grep -iqE 'printf[[:space:]]+[^>]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?tests/'; then
      echo "BLOCKED: awk internal redirect to src/ or tests/ detected — use Write/Edit tool instead" >&2
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
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+(checkout|restore|apply)[[:space:]]' && \
     _cmd_targets_sidecar "$cmd"; then
    echo "BLOCKED: git write operation targeting plans/*.state/ — sidecar is harness-exclusive" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*ln[[:space:]]'; then
    if _cmd_targets_sidecar "$cmd"; then
      echo "BLOCKED: ln operation targeting plans/*.state/ — symlink redirect attacks are not permitted" >&2; exit 2
    fi
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]'; then
    if _cmd_targets_sidecar "$cmd"; then
      echo "BLOCKED: rm targeting plans/*.state/ — sidecar is harness-exclusive" >&2; exit 2
    fi
    if _cmd_targets_critic_lock "$cmd"; then
      echo "BLOCKED: rm targeting plans/*.critic.lock — critic loop lock is harness-exclusive" >&2; exit 2
    fi
  fi
  if printf '%s' "$cmd" | grep -iqE 'awk[[:space:]]+-i[[:space:]]*(inplace|in-place)' && \
     _cmd_targets_sidecar "$cmd"; then
    echo "BLOCKED: awk -i inplace targeting plans/*.state/ — sidecar is harness-exclusive" >&2; exit 2
  fi
  if _cmd_targets_sidecar "$cmd"; then
    if printf '%s' "$cmd" | grep -iqE \
      '(^|[;|&[:space:]])[[:space:]]*(rsync[[:space:]]|install[[:space:]]|patch[[:space:]]|unzip[[:space:]]|tar[[:space:]]+-[[:alpha:]]*[xX]|cp[[:space:]]|mv[[:space:]])'; then
      echo "BLOCKED: write tool targeting plans/*.state/ — sidecar is harness-exclusive" >&2; exit 2
    fi
    if printf '%s' "$cmd" | grep -qE \
      '(python3?|perl|ruby|node|php|lua|R)[[:space:]]+-[ceEr][^[:alpha:]]|>{1,2}[[:space:]]*[^[:space:]]*plans/[^[:space:]'"'"'"]*\.state/'; then
      echo "BLOCKED: write operation targeting plans/*.state/ — sidecar is harness-exclusive" >&2; exit 2
    fi
  fi
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
  # env-injection
  if printf '%s' "$cmd" | grep -qwE \
    'BASH_ENV|PROMPT_COMMAND|PS4|SHELLOPTS|BASHOPTS|LD_PRELOAD|LD_AUDIT|DYLD_INSERT_LIBRARIES|PHASE_GATE_STRICT'; then
    echo "BLOCKED: shell startup / library-injection env var detected" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -qE '(^|[[:space:];|&])[[:space:]]*ENV[[:space:]]*='; then
    echo "BLOCKED: ENV= assignment — sources file before commands run" >&2; exit 2
  fi
  if [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "harness" ]]; then
    if printf '%s' "$cmd" | grep -qE \
      '(^|[[:space:];|&])[[:space:]]*(PATH|PYTHONSTARTUP|PYTHONPATH|PYTHONHOME|PERL5LIB|RUBYOPT|NODE_OPTIONS|LD_LIBRARY_PATH|DYLD_LIBRARY_PATH|DYLD_INSERT_LIBRARIES|BASH_ENV)[[:space:]]*=[^=]'; then
      echo "BLOCKED: interpreter environment injection variable detected (PATH/PYTHONSTARTUP/etc) — use CLAUDE_PLAN_CAPABILITY=human to override" >&2; exit 2
    fi
    if printf '%s' "$cmd" | grep -qE \
      '(^|[[:space:];|&])[[:space:]]*(GIT_SSH_COMMAND|GIT_EXTERNAL_DIFF|GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM|LESSOPEN|LESSCLOSE|ELECTRON_RUN_AS_NODE)[[:space:]]*=[^=]'; then
      echo "BLOCKED: git/pager execution-vector env var detected — use CLAUDE_PLAN_CAPABILITY=human to override" >&2; exit 2
    fi
  fi
}

# ── 5. block_ambiguous ────────────────────────────────────────────────────────
# Used only when [BLOCKED-AMBIGUOUS] is present in the active plan.
# General file-write blocking is handled by _bash_dest_paths + the write freeze.
# block_execution covers shell inline (bash -c) and pipe-to-interpreter.
# Only keep extraction commands that bypass the redirect-based write detection.

block_ambiguous() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -qE \
    '(python3?|perl|ruby|node|php|lua|R)[[:space:]]*(<<|<<-)'; then
    echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — interpreter heredoc execution prohibited" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -qE \
    '(^|[;|&[:space:]])[[:space:]]*tar[[:space:]]+-[[:alpha:]]*[xX]'; then
    echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — tar extraction prohibited" >&2; exit 2
  fi
}

# ── 6. block_ring_c ───────────────────────────────────────────────────────────
# Protects CLAUDE.md and reference policy docs from bash write vectors
# _RING_C_FILES constant is defined in capability.sh (sourced above).

_paths_in_workspace() {
  local _p
  while IFS= read -r _p; do
    [[ -z "$_p" ]] && continue
    if [[ "$_p" == /* ]] && [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && \
       [[ "$_p" != "${CLAUDE_PROJECT_DIR}/"* ]]; then
      continue
    fi
    printf '%s\n' "$_p"
  done
}

_ring_c_target() {
  local _cmd="$1"
  local _target_pat="(\./|\.\./|/)?(${_RING_C_FILES})\b"
  if printf '%s' "$_cmd" | grep -oE '>{1,2} *[^[:space:]]+' | sed 's/^>* *//' | tr -d '"'"'" \
      | _paths_in_workspace | grep -qE "$_target_pat"; then return 0; fi
  if printf '%s' "$_cmd" | grep -oE '\btee( +[^[:space:]]+)+' | sed 's/^tee *//' | tr ' ' '\n' \
      | _paths_in_workspace | grep -qE "$_target_pat"; then return 0; fi
  if printf '%s' "$_cmd" | grep -oE '\bdd\b[^|]*\bof=[^[:space:]]+' | sed 's/.*of=//' \
      | _paths_in_workspace | grep -qE "$_target_pat"; then return 0; fi
  if printf '%s' "$_cmd" | grep -oE '\bsed +-i[^ ]*( +[^[:space:];|&]+)+' | awk '{print $NF}' \
      | _paths_in_workspace | grep -qE "$_target_pat"; then return 0; fi
  if printf '%s' "$_cmd" | grep -iqE "truncate[[:space:]]+[^|;]*(${_RING_C_FILES})"; then return 0; fi
  local _cpmv _dest
  while IFS= read -r _cpmv; do
    [[ -n "$_cpmv" ]] || continue
    _dest=$(_extract_cp_mv_dest "$_cpmv")
    if [[ "$_dest" == /* ]] && [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && \
       [[ "$_dest" != "${CLAUDE_PROJECT_DIR}/"* ]]; then
      continue
    fi
    printf '%s' "$_dest" | grep -qE "$_target_pat" && return 0
  done < <(printf '%s' "$_cmd" | grep -oE '(^|[;|&[:space:]])(cp|mv)([[:space:]]+(-[[:alpha:]]+|--[a-zA-Z-]+=?[^[:space:];|&]*|[^[:space:];|&]+))+' || true)
  if printf '%s' "$_cmd" | grep -qE "printf[[:space:]]+[^|;]*>[[:space:]]*(${_RING_C_FILES})\b"; then return 0; fi
  return 1
}

block_ring_c() {
  local cmd="$1"
  [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "human" ]] && return 0
  if _ring_c_target "$cmd"; then
    echo "BLOCKED [phase-gate]: Ring C file (CLAUDE.md / reference policy docs) is protected — only human edits accepted (set CLAUDE_PLAN_CAPABILITY=human to override)" >&2
    exit 2
  fi
}

# ── 7. block_plan_revert ─────────────────────────────────────────────────────
# Blocks git revert/stash/reset operations targeting plan files when a
# HUMAN_MUST_CLEAR_MARKERS entry is active (marker-conditional).
block_plan_revert() {
  local cmd="$1"
  [[ -z "${PLAN_FILE_SH:-}" ]] && return 0
  local _active_plan="" _phase=""
  resolve_active_plan_and_phase _active_plan _phase 2>/dev/null || return 0
  marker_present_human_must_clear "$_active_plan" >/dev/null 2>&1 || return 0
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+(checkout|restore)[[:space:]]' && \
     printf '%s' "$cmd" | grep -qE 'plans/[^[:space:]]*\.md'; then
    echo "BLOCKED: git checkout/restore targeting plans/*.md while human-must-clear marker active — resolve the block first" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[[:space:];|&])git[[:space:]]+stash([[:space:];|&]|$)'; then
    echo "BLOCKED: git stash while human-must-clear marker active — resolve the block first" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+reset[[:space:]]+--[[:space:]]*(soft|mixed)[[:space:]]'; then
    echo "BLOCKED: git reset --soft/--mixed while human-must-clear marker active — resolve the block first" >&2; exit 2
  fi
}
