#!/usr/bin/env bash
# PreToolUse Bash hook — blocking rule orchestrator; sources capability, sidecar, and destructive rules.
# Each function receives the command string as $1 and calls exit 2 on match.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PRETOOLUSE_BLOCKS_LOADED:-}" ]] && return 0
_PRETOOLUSE_BLOCKS_LOADED=1

# NOTE: This is a *mistake-prevention* gate, not a security boundary.
# Known bypass classes not coverable by text-pattern matching:
#   1. base64-encoded payloads decoded at runtime
#   2. dynamic variable-name construction (e.g. local -x v=CLAUDE_PLAN_CAPABILITY; ${v}=x)
#   3. nested heredoc / process substitution depth
# Real enforcement requires a capability launcher token (deferred — requires launcher-token isolation).

# shellcheck source=lib/pretooluse-target-blocks-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pretooluse-target-blocks-lib.sh"
# shellcheck source=pretooluse-capability-blocks.sh
source "$(dirname "${BASH_SOURCE[0]}")/pretooluse-capability-blocks.sh"
# shellcheck source=pretooluse-sidecar-blocks.sh
source "$(dirname "${BASH_SOURCE[0]}")/pretooluse-sidecar-blocks.sh"

block_destructive_rm() {
  local cmd="$1"
  # also check ANSI-C decoded form
  local _decoded; _decoded=$(_decode_ansi_c "$cmd")
  if printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f([[:space:]/]|$)' \
    || printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*r([[:space:]/]|$)'; then
    echo "BLOCKED: destructive rm detected" >&2
    exit 2
  fi
  # rm -rf $PWD / rm -rf $(pwd)
  if printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+(\$PWD|\$\(pwd\)|`pwd`)'; then
    echo "BLOCKED: destructive rm targeting current directory detected" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+(--[a-zA-Z-]+[[:space:]]+)*(--recursive|--force)[[:space:]]+(--[a-zA-Z-]+[[:space:]]+)*(/|~|\$\{?HOME\}?|\.\.|\.\/|\*|\$\{[A-Z_]+:[-=][^}]*\})' ; then
    echo "BLOCKED: destructive rm (long-option --recursive/--force) detected" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '\bfind\b[[:space:]].*\-delete\b'; then
    echo "BLOCKED: find -delete detected — use rm on specific paths instead" >&2
    exit 2
  fi
  # shred or gio trash (destructive alternatives to rm)
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?shred[[:space:]]+-[a-zA-Z]*[uz]'; then
    echo "BLOCKED: shred -u/-z detected — destructive file deletion not permitted" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?gio[[:space:]]+trash[[:space:]]'; then
    echo "BLOCKED: gio trash detected — destructive file deletion not permitted" >&2
    exit 2
  fi
  # single-quoted tilde path (rm -rf '~/path')
  if printf '%s' "$cmd" | grep -iqE \
    "(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f[[:space:]]+'~/"; then
    echo "BLOCKED: destructive rm with single-quoted tilde path detected" >&2
    exit 2
  fi
  # Also check decoded form for any rm variant
  if printf '%s' "$_decoded" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f([[:space:]/]|$)'; then
    echo "BLOCKED: destructive rm detected (decoded)" >&2
    exit 2
  fi
}

block_disk_commands() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*dd[[:space:]]+if=' \
    || printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*mkfs[[:space:]./]' \
    || printf '%s' "$cmd" | grep -iqE '>[[:space:]]*/dev/[sh]d[a-z]'; then
    echo "BLOCKED: destructive disk command detected" >&2
    exit 2
  fi
}

block_git_clean() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*f'; then
    echo "BLOCKED: git clean -f detected" >&2
    exit 2
  fi
  # additional git destructive operations
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+reset[[:space:]]+--hard'; then
    echo "BLOCKED: git reset --hard detected — destructive history operation not permitted" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+checkout[[:space:]]+(--|[^[:space:]]*[[:space:]]+--)[[:space:]]+[.\/]'; then
    echo "BLOCKED: git checkout -- (discard changes) detected" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+checkout[[:space:]]+(--|\.)[[:space:]]*(|$)' || \
     printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+checkout[[:space:]]+\.[[:space:]]*(;|$|&&|\|\|)'; then
    echo "BLOCKED: git checkout . (discard all changes) detected" >&2
    exit 2
  fi
}

block_destructive_truncate() {
  local cmd="$1"
  # redirect-based file clobber (: > file, cat /dev/null > file, true > file)
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(:|true|false|cat[[:space:]]+/dev/null)[[:space:]]*>[[:space:]]*[^>]'; then
    echo "BLOCKED: redirect-based file clobber detected (: > file or cat /dev/null > file)" >&2
    exit 2
  fi
  # truncate command
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?truncate[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-s[[:space:]]*0'; then
    echo "BLOCKED: truncate -s 0 (zero-out file) detected" >&2
    exit 2
  fi
  # tar --remove-files and rsync --delete
  if printf '%s' "$cmd" | grep -iqE 'tar[[:space:]]+[^;|&]*--remove-files'; then
    echo "BLOCKED: tar --remove-files detected — source file removal not permitted" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'rsync[[:space:]]+[^;|&]*--delete(-[a-z]+)?'; then
    echo "BLOCKED: rsync --delete detected — destructive sync not permitted" >&2
    exit 2
  fi
}

block_sql_ddl() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE \
    '(^|[[:space:]])(DROP|TRUNCATE)[[:space:]]+(TABLE|DATABASE|SCHEMA)([[:space:]]|$)'; then
    echo "BLOCKED: destructive SQL DDL detected" >&2
    exit 2
  fi
}

block_new_destructive_patterns() {
  local cmd="$1"
  # cp /dev/null → zero-out file
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?cp[[:space:]]+/dev/null[[:space:]]+'; then
    echo "BLOCKED: cp /dev/null (file clobber) detected — destructive file deletion not permitted" >&2
    exit 2
  fi
  # dd if=/dev/null or if=/dev/zero → zero-out or truncate a file
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*dd[[:space:]]+.*if=/dev/(null|zero)[[:space:]]+of='; then
    echo "BLOCKED: dd if=/dev/null|zero of=... (file clobber) detected — not permitted" >&2
    exit 2
  fi
  # find -exec rm (destructive recursive deletion via find)
  if printf '%s' "$cmd" | grep -iqE '\bfind\b[[:space:]].*-exec[[:space:]]+(sudo[[:space:]]+)?rm[[:space:]]'; then
    echo "BLOCKED: find -exec rm detected — use explicit targeted rm instead" >&2
    exit 2
  fi
  # shred with -u (any flag combination containing u)
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?shred[[:space:]]+-[a-zA-Z]*u'; then
    echo "BLOCKED: shred -u detected — destructive file deletion not permitted" >&2
    exit 2
  fi
  # wipe command (secure file deletion)
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?wipe[[:space:]]+'; then
    echo "BLOCKED: wipe command detected — destructive file deletion not permitted" >&2
    exit 2
  fi
  # rm -P (secure overwrite before delete, BSD)
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*P'; then
    echo "BLOCKED: rm -P (secure unlink) detected — destructive file deletion not permitted" >&2
    exit 2
  fi
  # osascript with rm/delete/empty (macOS file deletion via AppleScript)
  if printf '%s' "$cmd" | grep -iqE 'osascript[[:space:]]+-e[[:space:]]+["\x27].*\b(rm|delete|empty|trash)\b'; then
    echo "BLOCKED: osascript with file deletion — macOS destructive operation not permitted" >&2
    exit 2
  fi
}
