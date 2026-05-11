#!/usr/bin/env bash
# PreToolUse Bash hook — git, write-level, and path-extraction guards.
# Each function receives the command string as $1 and calls exit 2 on match.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PRETOOLUSE_WRITE_GUARDS_LOADED:-}" ]] && return 0
_PRETOOLUSE_WRITE_GUARDS_LOADED=1

# shellcheck source=pretooluse-ambiguous-blocks.sh
source "$(dirname "${BASH_SOURCE[0]}")/pretooluse-ambiguous-blocks.sh"
# D2: hook input AST normalization helper
source "$(dirname "${BASH_SOURCE[0]}")/lib/hook-input.sh" 2>/dev/null || true

block_git_amend() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+commit[[:space:]]+.*--amend'; then
    if git branch -r --contains HEAD 2>/dev/null | grep -q .; then
      echo "BLOCKED: git commit --amend on a commit already pushed to remote. Create a new commit instead to avoid requiring force-push." >&2
      exit 2
    fi
    echo "WARNING: git commit --amend detected — commit is not yet pushed (safe to amend)" >&2
  fi
}

block_git_hooks_bypass() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+-c[[:space:]]+[^=]*[Hh]ooks[Pp]ath'; then
    echo "BLOCKED: git -c hooksPath override detected (hook bypass attempt)" >&2
    exit 2
  fi
}

# _SHELL_INVOCATION_RE matches shell binaries with optional absolute/relative path prefix,
# env/nice/nohup/exec prefix, and multi-flag forms including split -i -c tokens.
_SHELL_INVOCATION_RE='(^|[[:space:]])(env[[:space:]]+(-S[[:space:]]+|-i[[:space:]]+)?|nice[[:space:]]+(-n[[:space:]]+[0-9]+[[:space:]]+)?|nohup[[:space:]]+|exec[[:space:]]+|/[^[:space:]]+/)?(bash|sh|dash|zsh|ksh)([[:space:]]+-[a-zA-Z]+)?'

# Table-driven patterns for block_pipe_to_shell: "regex|||message" pairs.
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

_dispatch_patterns() {
  local cmd="$1" entry pat msg
  for entry in "${@:2}"; do
    pat="${entry%|||*}"; msg="${entry##*|||}"
    if printf '%s' "$cmd" | grep -iqE "$pat"; then
      echo "BLOCKED: ${msg}" >&2; exit 2
    fi
  done
}

block_pipe_to_shell() {
  _dispatch_patterns "$1" "${_PIPE_TO_SHELL_PATTERNS[@]}"
}

block_world_writable_chmod() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE \
    'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?[0-7]{2,3}[2367]([[:space:]]|$)' \
    || printf '%s' "$cmd" | grep -iqE \
    'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?(o|a)\+[rwx]*w'; then
    echo "BLOCKED: world-writable chmod detected" >&2
    exit 2
  fi
}

block_eval_source() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*eval[[:space:]]+[^[:space:]]*\$\(' \
    || printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*source[[:space:]]+<\('; then
    echo "BLOCKED: eval/source with command substitution detected" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*eval[[:space:]].*\$\('; then
    echo "BLOCKED: eval with command substitution detected" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*(eval|source|\\.)[[:space:]]+[^[:space:]]*`'; then
    echo "BLOCKED: eval/source with backtick command substitution detected" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*\.[[:space:]]+<\('; then
    echo "BLOCKED: dot-source with process substitution detected" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '<<<[[:space:]]*[^|;&]*(\$\(|`)'; then
    echo "BLOCKED: here-string with command substitution detected" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -qE \
    '(bash|sh|zsh|ksh|dash|python3?|perl|ruby|node(js)?|php|lua|R)[[:space:]]+(-[a-zA-Z][^[:space:]]*[[:space:]]+)*-[ceE][^[:alpha:]].*(\$\(|<\()'; then
    echo "BLOCKED: interpreter inline-exec with command substitution detected" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -qE \
    '\|[[:space:]]*(\.|source)[[:space:]]+/dev/(stdin|fd/0)\b'; then
    echo "BLOCKED: pipe to dot/source /dev/stdin detected" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -qE \
    '\b(bash|sh|zsh|ksh|dash|ash)[[:space:]]+(-[a-zA-Z][^[:space:]]*[[:space:]]+)*-c[[:space:]]+["\x27]?\$\(cat[[:space:]]+'; then
    echo "BLOCKED: interpreter -c with \$(cat ...) substitution detected" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -qE '/dev/(tcp|udp)/'; then
    echo "BLOCKED: /dev/tcp or /dev/udp shell-builtin path detected" >&2
    exit 2
  fi
}

# shellcheck source=lib/pretooluse-target-blocks-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pretooluse-target-blocks-lib.sh"
