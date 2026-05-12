#!/usr/bin/env bash
# PreToolUse Bash hook — all blocking rules in 8 categories.
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

# ── 1. block_destructive ──────────────────────────────────────────────────────
# Combines: rm, truncate/clobber, disk, git-clean, git-amend, git-hooks-bypass
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
  if printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+(--[a-zA-Z-]+[[:space:]]+)*(--recursive|--force)[[:space:]]+(--[a-zA-Z-]+[[:space:]]+)*(/|~|\$\{?HOME\}?|\.\.|\.\/|\*|\$\{[A-Z_]+:[-=][^}]*\})'; then
    echo "BLOCKED: destructive rm (long-option --recursive/--force) detected" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '\bfind\b[[:space:]].*\-delete\b'; then
    echo "BLOCKED: find -delete detected — use rm on specific paths instead" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?shred[[:space:]]+-[a-zA-Z]*[uz]'; then
    echo "BLOCKED: shred -u/-z detected — destructive file deletion not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?gio[[:space:]]+trash[[:space:]]'; then
    echo "BLOCKED: gio trash detected — destructive file deletion not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE \
    "(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f[[:space:]]+'~/"; then
    echo "BLOCKED: destructive rm with single-quoted tilde path detected" >&2; exit 2
  fi
  # redirect-based file clobber
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(:|true|false|cat[[:space:]]+/dev/null)[[:space:]]*>[[:space:]]*[^>]'; then
    echo "BLOCKED: redirect-based file clobber detected (: > file or cat /dev/null > file)" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?truncate[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-s[[:space:]]*0'; then
    echo "BLOCKED: truncate -s 0 (zero-out file) detected" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'tar[[:space:]]+[^;|&]*--remove-files'; then
    echo "BLOCKED: tar --remove-files detected — source file removal not permitted" >&2; exit 2
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
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+commit[[:space:]]+.*--amend'; then
    if git branch -r --contains HEAD 2>/dev/null | grep -q .; then
      echo "BLOCKED: git commit --amend on a commit already pushed to remote. Create a new commit instead to avoid requiring force-push." >&2
      exit 2
    fi
    echo "WARNING: git commit --amend detected — commit is not yet pushed (safe to amend)" >&2
  fi
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+-c[[:space:]]+[^=]*[Hh]ooks[Pp]ath'; then
    echo "BLOCKED: git -c hooksPath override detected (hook bypass attempt)" >&2; exit 2
  fi
}

# ── 2. block_execution ────────────────────────────────────────────────────────
# Combines: pipe-to-shell, eval/source, new-exec-vectors, world-writable-chmod, awk-redirect-src-tests
_PIPE_TO_SHELL_PATTERNS=(
  '\|[[:space:]]*(command[[:space:]]+|exec[[:space:]]+|env([[:space:]]+-[a-zA-Z]+)*[[:space:]]+)?(/[^[:space:]]*/)?((ba|z|k|da|a)?sh|dash)([[:space:]]+-[[:alpha:]]+)*([[:space:]]|$)|||pipe-to-shell detected'
  '(^|[;|&[:space:]])[[:space:]]*(env[[:space:]]+(-[iSu0]+[[:space:]]+|[A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]+)*|nice[[:space:]]+[^|&;]*|nohup[[:space:]]+[^|&;]*|exec[[:space:]]+)?(/[^[:space:]]*/)?((ba|z|k|da|a|bu)?sh|dash)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[ic][a-zA-Z]*([[:space:]]|$)|||interactive/command-flag shell invocation detected'
  '(^|[;|&[:space:]])[[:space:]]*(/[^[:space:]]*/)?((ba|z|k|da)?sh|dash)[[:space:]]+(--?[a-zA-Z][a-zA-Z0-9_-]*[[:space:]]+)+-c([[:space:]]|$)|||split-flag shell -c invocation detected'
  '\b(ba|z|k|da|a|bu)?sh[[:space:]]+(-[a-zA-Z][^[:space:]]*[[:space:]]+)*<<<|||here-string to shell detected'
  '\|[[:space:]]*(command[[:space:]]+|exec[[:space:]]+)?busybox[[:space:]]+sh([[:space:]]|$)|||pipe-to-busybox-sh detected'
  '\|[[:space:]]*(python3?|perl|ruby|node(js)?|php|lua|R|deno|tsx?)[[:space:]]*(-[[:space:]])?([[:space:]]|$)|||pipe-to-interpreter detected'
  '\bxargs\b[^|&;]*\b(bash|sh|zsh|ksh|dash|ash|busybox)[^|&;]*-c\b|||xargs shell inline-exec detected'
  '\bfind\b[^|&;]*-exec[[:space:]]+(/[^[:space:]]*/)?( ?command[[:space:]]+|exec[[:space:]]*)?(ba|z|k|da|a)?sh([[:space:]]|$)|||find -exec shell detected'
  '\bfind\b[^|&;]*-exec[[:space:]]+(/[^[:space:]]*/)?busybox[[:space:]]+sh([[:space:]]|$)|||find -exec busybox sh detected'
  '\|[[:space:]]*(sudo([[:space:]]+-[a-zA-Z]+)*[[:space:]]+)+(ba|z|k|da|a)?sh([[:space:]]|$)|||pipe-to-shell via sudo detected'
  '>\([[:space:]]*(/?[^[:space:]/]*/)?(bash|sh|zsh|ksh|dash|ash|busybox[[:space:]]+sh)\b|||process-substitution pipe-to-shell detected'
  '\b(bash|sh|zsh|ksh|dash|ash)[[:space:]]+(-[a-zA-Z][^[:space:]]*[[:space:]]+)*<[[:space:]]*[^<]|||shell reading from redirection detected'
  '\benv\b[[:space:]]+(-[iu0]+[[:space:]]+|[A-Z_][A-Z0-9_]*=[^[:space:]]+[[:space:]]+)*(/?[^[:space:]]*/)?( ?bash|sh|python3?|perl|ruby|node|php|lua|R|deno|tsx?|busybox)\b|||env-prefixed interpreter execution detected'
  '(^|[;|&[:space:]])[[:space:]]*(deno[[:space:]]+eval|tsx[[:space:]]+-e|npx[[:space:]]+-y[[:space:]].*-[ce][[:space:]])|||deno/tsx/npx inline-exec detected'
  '\b(bash|sh|zsh|ksh|dash|ash)[[:space:]]+(-[a-zA-Z][^[:space:]]*[[:space:]]+)*<<-[A-Z_]*EOF|||tab-stripped here-doc to shell detected'
  '\b(builtin|command)[[:space:]]+(\.[[:space:]]|source[[:space:]])|||builtin/command bypass for dot/source detected'
  '~[^[:space:]]*/( ?bash|sh|zsh|ksh|dash|ash)\b|||tilde-path shell invocation detected'
  '\bpython3?[[:space:]]+-c[[:space:]]+["\x27][^"'"'"']*\b(os\.system|subprocess\.run|subprocess\.call|subprocess\.Popen)[^"'"'"']*shell[[:space:]]*=|||python -c with os.system/subprocess shell=True detected'
  '(^|[;|&[:space:]])[[:space:]]*coproc[[:space:]]+(ba|z|k|da|a)?sh([[:space:]]|$)|||coproc shell invocation detected'
  '(^|[[:space:];|&])[[:space:]]*\\(bash|sh|zsh|ksh|dash|ash)([[:space:]]|$)|||backslash-escaped shell name detected'
)

_EVAL_SOURCE_PATTERNS=(
  '(^|[;|&[:space:]])[[:space:]]*eval[[:space:]]+[^[:space:]]*\$\(|||eval/source with command substitution detected'
  '(^|[;|&[:space:]])[[:space:]]*source[[:space:]]+<\(|||eval/source with command substitution detected'
  '(^|[;|&[:space:]])[[:space:]]*eval[[:space:]].*\$\(|||eval with command substitution detected'
  '(^|[;|&[:space:]])[[:space:]]*(eval|source|\.)[[:space:]]+[^[:space:]]*`|||eval/source with backtick command substitution detected'
  '(^|[;|&[:space:]])[[:space:]]*\.[[:space:]]+<\(|||dot-source with process substitution detected'
  '<<<[[:space:]]*[^|;&]*(\$\(|`)|||here-string with command substitution detected'
  '(bash|sh|zsh|ksh|dash|python3?|perl|ruby|node(js)?|php|lua|R)[[:space:]]+(-[a-zA-Z][^[:space:]]*[[:space:]]+)*-[ceE][^[:alpha:]].*(\$\(|<\()|||interpreter inline-exec with command substitution detected'
  '\|[[:space:]]*(\.|source)[[:space:]]+/dev/(stdin|fd/0)\b|||pipe to dot/source /dev/stdin detected'
  '\b(bash|sh|zsh|ksh|dash|ash)[[:space:]]+(-[a-zA-Z][^[:space:]]*[[:space:]]+)*-c[[:space:]]+["\x27]?\$\(cat[[:space:]]+|||interpreter -c with $(cat ...) substitution detected'
  '/dev/(tcp|udp)/|||/dev/tcp or /dev/udp shell-builtin path detected'
)

_NEW_EXEC_VECTOR_PATTERNS=(
  '(^|[;|&[:space:]])[[:space:]]*socat[[:space:]]+[^|]*EXEC|||socat EXEC — remote shell execution vector not permitted'
  '(^|[;|&[:space:]])[[:space:]]*(nc|ncat)[[:space:]]+[^|]*-e[[:space:]]|||nc/ncat -e — pipe-to-shell vector not permitted'
  'osascript[[:space:]]+-e[[:space:]]+["\x27].*do[[:space:]]+shell[[:space:]]+script|||osascript do shell script — macOS shell execution vector not permitted'
  '(gunzip|bzcat|zstdcat|lz4cat|xzcat|gzcat|uncompress)[[:space:]]+[^|]*\|[[:space:]]*(bash|sh|eval|source|\.)|||compressed-stream pipe-to-shell — security policy denies pipe-to-shell vectors'
  'awk[[:space:]].*BEGIN[[:space:]]*\{[[:space:]]*system[[:space:]]*\(|||awk BEGIN{system(...)} — shell execution vector not permitted'
  '(^|[;|&[:space:]])[[:space:]]*script[[:space:]]+-[a-z]*q[a-z]*c[[:space:]]+["\x27]?(bash|sh|zsh)|||script -qc shell — execution vector not permitted'
)

block_execution() {
  local cmd="$1"
  # static integrity check on pipe-to-shell table
  local _entry _sep_count
  for _entry in "${_PIPE_TO_SHELL_PATTERNS[@]}"; do
    _sep_count=$(printf '%s' "$_entry" | grep -oF '|||' | wc -l | tr -d '[:space:]')
    if [[ "$_sep_count" -ne 1 ]]; then
      echo "BUG: _PIPE_TO_SHELL_PATTERNS entry has ${_sep_count} '|||' separators (expected 1): ${_entry}" >&2
      exit 1
    fi
  done
  _dispatch_patterns "$cmd" "${_PIPE_TO_SHELL_PATTERNS[@]}"
  _dispatch_patterns "$cmd" "${_EVAL_SOURCE_PATTERNS[@]}"
  # pipe-to-shell compound checks
  if printf '%s' "$cmd" | grep -iqE 'mkfifo' && \
     printf '%s' "$cmd" | grep -iqE '(bash|sh|zsh)[[:space:]]*<'; then
    echo "BLOCKED: mkfifo with shell redirection — pipe-to-shell vector not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(perl|ruby|php|node|deno)[[:space:]]+.*-(e|r)[[:space:]].*base64' && \
     printf '%s' "$cmd" | grep -iqE '\|[[:space:]]*(bash|sh|eval|source)'; then
    echo "BLOCKED: interpreter base64-decode pipe-to-shell — security policy denies this vector" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(expect|gdb)[[:space:]]+.*-c[[:space:]].*shell' || \
     printf '%s' "$cmd" | grep -iqE '(expect|gdb)[[:space:]].*spawn[[:space:]]+(bash|sh)'; then
    echo "BLOCKED: expect/gdb shell spawn — execution vector not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'vim[[:space:]].*-c[[:space:]].*![^!]' && \
     printf '%s' "$cmd" | grep -iqE 'vim[[:space:]].*-c[[:space:]]q'; then
    echo "BLOCKED: vim -c !cmd shell execution — not permitted" >&2; exit 2
  fi
  _dispatch_patterns "$cmd" "${_NEW_EXEC_VECTOR_PATTERNS[@]}"
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
# Combines: capability-spoofing, env-injection, human-marker-commands

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
    'BASH_ENV|PROMPT_COMMAND|PS4|SHELLOPTS|BASHOPTS|LD_PRELOAD|LD_AUDIT|DYLD_INSERT_LIBRARIES'; then
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
      '(^|[[:space:];|&])[[:space:]]*(GIT_SSH_COMMAND|GIT_EXTERNAL_DIFF|GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM|LESSOPEN|LESSCLOSE|MANOPT|LD_BIND_NOW|DYLD_FORCE_FLAT_NAMESPACE|ELECTRON_RUN_AS_NODE)[[:space:]]*=[^=]'; then
      echo "BLOCKED: git/pager execution-vector env var detected — use CLAUDE_PLAN_CAPABILITY=human to override" >&2; exit 2
    fi
  fi
  # human-marker-commands
  if printf '%s' "$cmd" | grep -qE "(plan-file\\.sh|\\\$PLAN_FILE_SH|\\\$\{PLAN_FILE_SH\})[\"'[:space:]].*clear-marker"; then
    local _hm
    for _hm in "${HUMAN_MUST_CLEAR_MARKERS[@]}"; do
      if printf '%s' "$cmd" | grep -qF "$_hm"; then
        echo "BLOCKED: this marker cannot be cleared by Claude — human must run plan-file.sh clear-marker directly from terminal" >&2; exit 2
      fi
    done
  fi
  if printf '%s' "$cmd" | grep -qE "plan-file\\.sh[\"'[:space:]].*unblock[[:space:]]"; then
    echo "BLOCKED: 'unblock' is a human-only command — run plan-file.sh unblock from terminal" >&2; exit 2
  fi
}

# ── 5. block_ambiguous ────────────────────────────────────────────────────────
# Used only when [BLOCKED-AMBIGUOUS] is present in the active plan

block_ambiguous() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -qE \
    '(python3?|perl|ruby|node|php|lua|R)[[:space:]]+-[ceEr][^[:alpha:]]'; then
    echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — interpreter inline execution prohibited" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -qE \
    '(python3?|perl|ruby|node|php|lua|R)[[:space:]]*(<<|<<-)'; then
    echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — interpreter heredoc execution prohibited" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -qE \
    '(bash|sh|zsh|ksh|dash)[[:space:]]+-c[^[:alpha:]]'; then
    echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — shell inline execution prohibited" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -qE \
    '(^|[;|&[:space:]])[[:space:]]*(rsync|git[[:space:]]+apply|patch[[:space:]]|unzip[[:space:]]|install[[:space:]])'; then
    echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — file-install command prohibited" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -qE \
    '(^|[;|&[:space:]])[[:space:]]*tar[[:space:]]+-[[:alpha:]]*[xX]'; then
    echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — tar extraction prohibited" >&2; exit 2
  fi
}

# ── 6. block_ring_c ───────────────────────────────────────────────────────────
# Protects CLAUDE.md and reference policy docs from bash write vectors

_RING_C_FILES='CLAUDE\.md|reference/(markers|critics|phase-gate-config|layers)\.md'

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
  if printf '%s' "$_cmd" | grep -qE "(python[23]?|perl|ruby|node)[[:space:]]+-[ceE][^|;]*(open|write)[^|;]*(${_RING_C_FILES})"; then return 0; fi
  if printf '%s' "$_cmd" | grep -qE "(^|[;|&[:space:]])[[:space:]]*(ed|vim?[[:space:]]+(-e[[:space:]]|-s[[:space:]]))[^|;]*(${_RING_C_FILES})\b"; then return 0; fi
  if printf '%s' "$_cmd" | grep -qE "awk[[:space:]]+[^|;]*>[[:space:]]*(${_RING_C_FILES})\b"; then return 0; fi
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

# ── 7. block_sql_ddl ──────────────────────────────────────────────────────────
block_sql_ddl() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE \
    '(^|[[:space:]])(DROP|TRUNCATE)[[:space:]]+(TABLE|DATABASE|SCHEMA)([[:space:]]|$)'; then
    echo "BLOCKED: destructive SQL DDL detected" >&2; exit 2
  fi
}

# ── 8. block_new_destructive_patterns ─────────────────────────────────────────
block_new_destructive_patterns() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?cp[[:space:]]+/dev/null[[:space:]]+'; then
    echo "BLOCKED: cp /dev/null (file clobber) detected — destructive file deletion not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*dd[[:space:]]+.*if=/dev/(null|zero)[[:space:]]+of='; then
    echo "BLOCKED: dd if=/dev/null|zero of=... (file clobber) detected — not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '\bfind\b[[:space:]].*-exec[[:space:]]+(sudo[[:space:]]+)?rm[[:space:]]'; then
    echo "BLOCKED: find -exec rm detected — use explicit targeted rm instead" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?shred[[:space:]]+-[a-zA-Z]*u'; then
    echo "BLOCKED: shred -u detected — destructive file deletion not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?wipe[[:space:]]+'; then
    echo "BLOCKED: wipe command detected — destructive file deletion not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*P'; then
    echo "BLOCKED: rm -P (secure unlink) detected — destructive file deletion not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'osascript[[:space:]]+-e[[:space:]]+["\x27].*\b(rm|delete|empty|trash)\b'; then
    echo "BLOCKED: osascript with file deletion — macOS destructive operation not permitted" >&2; exit 2
  fi
}
