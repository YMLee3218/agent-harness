#!/usr/bin/env bash
# PreToolUse Bash hook — all blocking rules in 5 categories.
# Each function receives the command string as $1 and calls exit 2 on match.
# Source this file; do not execute directly.
# Mistake-prevention only; authoritative gate is the PPID-chain check in capability.sh::_check_parent_env.
set -euo pipefail
[[ -n "${_PRETOOLUSE_BLOCKS_LOADED:-}" ]] && return 0
_PRETOOLUSE_BLOCKS_LOADED=1

# _bash_dest_paths CMD — extracts write-destination paths from a bash command string.
# Tokens containing unresolved variable expansion ($VAR, ${VAR}, $(...), `...`) are
# returned as a sidecar path so callers fail-closed rather than silently bypass.
_bash_dest_paths() {
  local c="$1" _t
  printf '%s' "$c" | grep -oE '>{1,2} *[^[:space:]]+' | sed 's/^>* *//' | tr -d '"'"'" | while IFS= read -r _t; do
    case "$_t" in *'$'*|*'`'*) echo 'plans/__unexpanded__.state/__bypass__' ;; *) echo "$_t" ;; esac
  done || true
  printf '%s' "$c" | grep -oE '\btee( +[^[:space:]]+)+' | sed 's/^tee *//' | tr ' ' '\n' | grep -v '^-' | while IFS= read -r _t; do
    case "$_t" in *'$'*|*'`'*) echo 'plans/__unexpanded__.state/__bypass__' ;; *) echo "$_t" ;; esac
  done || true
  # cp/mv destination: last non-flag token (simplified; handles common forms)
  # Also captures -t TARGET and --target-directory=TARGET (GNU/BSD explicit-dest flags).
  printf '%s' "$c" | grep -oE '(^|[;|&[:space:]])(cp|mv)([[:space:]]+(-[[:alpha:]]+|--[a-zA-Z-]+=?[^[:space:];|&]*|[^[:space:];|&]+))+' | while IFS= read -r _cpmv; do
    [[ -n "$_cpmv" ]] || continue
    _t=$(printf '%s' "$_cpmv" | tr ' ' '\n' | grep -vE '^-' | tail -1 | tr -d '"'"'" 2>/dev/null || true)
    case "$_t" in *'$'*|*'`'*) echo 'plans/__unexpanded__.state/__bypass__' ;; *) echo "$_t" ;; esac
    _t2=$(printf '%s' "$_cpmv" | grep -oE '(-t[[:space:]]+|--target-directory=)[^[:space:];|&]+' \
      | sed 's/^-t[[:space:]]*//' | sed 's/^--target-directory=//' | tail -1 | tr -d '"'"'" 2>/dev/null || true)
    [[ -n "$_t2" ]] || continue
    case "$_t2" in *'$'*|*'`'*) echo 'plans/__unexpanded__.state/__bypass__' ;; *) echo "$_t2" ;; esac
  done || true
  printf '%s' "$c" | grep -oE '\bsed +-i[^ ]*( +[^[:space:];|&]+)+' | awk '{print $NF}' | while IFS= read -r _t; do
    case "$_t" in *'$'*|*'`'*) echo 'plans/__unexpanded__.state/__bypass__' ;; *) echo "$_t" ;; esac
  done || true
  printf '%s' "$c" | grep -oE '\bdd\b[^|]*\bof=[^[:space:]]+' | grep -oE '\bof=[^[:space:]]+' | sed 's/^of=//' | while IFS= read -r _t; do
    case "$_t" in *'$'*|*'`'*) echo 'plans/__unexpanded__.state/__bypass__' ;; *) echo "$_t" ;; esac
  done || true
  # awk -i inplace: last non-flag word is the target file
  printf '%s' "$c" | grep -oE 'awk[[:space:]]+-i[[:space:]]*(in-?place)?[^|;&]*' \
    | awk '{print $NF}' | while IFS= read -r _t; do
    case "$_t" in *'$'*|*'`'*) echo 'plans/__unexpanded__.state/__bypass__' ;; *) echo "$_t" ;; esac
  done || true
}

# ── 1. block_destructive ──────────────────────────────────────────────────────
# Combines: rm, truncate/clobber, disk, git-clean, git-amend, cp-clobber, find-exec-rm
block_destructive() {
  local cmd="$1"
  # rm -rf/-fr variants (merged regex)
  if printf '%s' "$cmd" | grep -iqE \
    '(^|[;|&[:space:]])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*(rf|fr)[a-zA-Z]*([[:space:]/]|$)'; then
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
  if printf '%s' "$cmd" | grep -iqE '\bfind\b[[:space:]].*-exec[[:space:]]+(sudo[[:space:]]+)?rm[[:space:]]'; then
    echo "BLOCKED: find -exec rm detected — use explicit targeted rm instead" >&2; exit 2
  fi
}

# ── 2. block_execution ────────────────────────────────────────────────────────
# Combines: pipe-to-shell, awk-redirect-src-tests-plans
block_execution() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE '\|[[:space:]]*(/[^[:space:]]*/)?((ba|z|k|da|a)?sh|dash)([[:space:]]+-[[:alpha:]]+)*([[:space:]]|$)'; then
    echo "BLOCKED: pipe-to-shell detected" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '\|[[:space:]]*(python3?|perl|ruby|node)[[:space:]]*(-[[:space:]])?([[:space:]]|$)'; then
    echo "BLOCKED: pipe-to-interpreter detected" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -qE '\b(python3?|perl|ruby|node)\b[[:space:]]+(-[A-Za-z]*[ceE]([[:space:]]|=)|--?command|--?eval)'; then
    echo "BLOCKED: inline interpreter script — use Read/Write/Edit tools instead of python/perl/ruby/node -c/-e" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -qE '\b(python3?|perl|ruby|node)\b[^|;&]*<<-?[[:space:]]*[A-Za-z_]'; then
    echo "BLOCKED: interpreter heredoc detected — use Write/Edit tool instead of python/perl/ruby/node << HEREDOC" >&2; exit 2
  fi
  # awk internal redirect to src/, tests/, or plans/
  if printf '%s' "$cmd" | grep -iqE 'awk[[:space:]]' && \
     printf '%s' "$cmd" | grep -iqE '(print(f)?[[:space:]][^>]*)?>{1,2}[[:space:]]*"?([^"[:space:]]*/)?(src|tests)/'; then
    echo "BLOCKED: awk internal redirect to src/ or tests/ detected — use Write/Edit tool instead" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'awk[[:space:]]' && \
     printf '%s' "$cmd" | grep -iqE '>{1,2}[[:space:]]*"?[^"[:space:]]*plans/[^"[:space:]]*(\.state|\.md)\b'; then
    echo "BLOCKED: awk internal redirect to plans/*.state/ or plans/*.md detected — use Write/Edit tool instead" >&2; exit 2
  fi
}

# ── 3. block_sidecar_writes ───────────────────────────────────────────────────
# Combines: git-sidecar, ln, rm, write-tools, interpreter targeting sidecar
#           (awk-inplace covered by _bash_dest_paths extractor)

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
  local _dest_list _sw_p
  # A4: block mv/cp -r targeting the plans/ directory itself
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(mv|cp[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*)([[:space:]]+-[a-zA-Z]+)*[[:space:]]+(\.\/)?plans(/[[:space:]]|[[:space:]]|/$)'; then
    echo "BLOCKED: mv/cp -r targeting plans/ directory — plan directory structure is harness-exclusive" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])git[[:space:]]+rm([[:space:]]+-[a-zA-Z]+)*[[:space:]]+[^[:space:]]*plans/[^[:space:]]*\.md\b'; then
    echo "BLOCKED: git rm targeting plans/*.md" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -qE '(^|[;|&])[[:space:]]*cd[[:space:]]+([./]*)?plans([/[:space:];|&]|$)' \
    && printf '%s' "$cmd" | grep -qE '\b(sed[[:space:]]+-i|rm|cp|mv|tee|cat[[:space:]]+>|printf|echo)[[:space:]]'; then
    echo "BLOCKED: cd plans && write — use plan-file.sh harness commands" >&2; exit 2
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
    if printf '%s' "$cmd" | grep -qE 'plans/[^[:space:]]*\.md\b'; then
      echo "BLOCKED: rm targeting plans/*.md — plan file deletion not permitted" >&2; exit 2
    fi
  fi
  if [ $# -lt 2 ]; then
    _dest_list=$(_bash_dest_paths "$cmd")
  else
    _dest_list="${2-}"
  fi
  while IFS= read -r _sw_p; do
    [ -z "$_sw_p" ] && continue
    if is_sidecar_path "$_sw_p"; then
      echo "BLOCKED: write operation targeting plans/*.state/ — sidecar is harness-exclusive" >&2; exit 2
    fi
    case "$_sw_p" in *.critic.lock)
      echo "BLOCKED: write targeting plans/*.critic.lock — critic lock is harness-exclusive" >&2; exit 2 ;;
    esac
  done <<< "$_dest_list"
}

# ── 4. block_capability ───────────────────────────────────────────────────────
# Combines: capability-spoofing, env-injection, unblock-command

_block_var_assign() {
  local cmd="$1" var="$2" msg="$3"
  if printf '%s' "$cmd" | grep -qE "${var}[[:space:]]*=" || \
     printf '%s' "$cmd" | grep -qE "export[[:space:]]+${var}([[:space:]]|;|$)" || \
     printf '%s' "$cmd" | grep -qE "\bread[[:space:]]+([^[:space:]<]+[[:space:]]+)*${var}([[:space:]]|<|$)" || \
     printf '%s' "$cmd" | grep -qE "(declare|typeset)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*${var}\b"; then
    echo "BLOCKED: ${msg}" >&2; exit 2
  fi
}

block_capability() {
  local cmd="$1"
  _block_var_assign "$cmd" "CLAUDE_PLAN_CAPABILITY" "CLAUDE_PLAN_CAPABILITY assignment in agent Bash command — capability spoofing is not permitted"
  _block_var_assign "$cmd" "CLAUDE_PLAN_FILE" "CLAUDE_PLAN_FILE assignment in agent Bash command — active plan is set by the launcher"
  _block_var_assign "$cmd" "CLAUDE_PROJECT_DIR" "CLAUDE_PROJECT_DIR assignment in agent Bash command — would spawn child claude with detached hook root"
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
  local _active_plan=""
  # Use find-active directly: any non-zero (no plan, ambiguous rc=3, malformed rc=4)
  # means we cannot determine which plan to guard, so skip this check.
  _active_plan=$(bash "$PLAN_FILE_SH" find-active 2>/dev/null) || return 0
  [[ -z "$_active_plan" ]] && return 0
  marker_present_human_must_clear "$_active_plan" >/dev/null 2>&1 || return 0
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+(checkout|restore|apply|am|revert|cherry-pick)[[:space:]]' && \
     printf '%s' "$cmd" | grep -qE 'plans/[^[:space:]]*\.md'; then
    echo "BLOCKED: git operation targeting plans/*.md while human-must-clear marker active — resolve the block first" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'git[[:space:]]+reset[[:space:]]+--[[:space:]]*(soft|mixed)[[:space:]]'; then
    echo "BLOCKED: git reset --soft/--mixed while human-must-clear marker active — resolve the block first" >&2; exit 2
  fi
}
