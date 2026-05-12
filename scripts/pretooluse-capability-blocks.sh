#!/usr/bin/env bash
# PreToolUse Bash hook — capability-spoofing blocking rules.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PRETOOLUSE_CAPABILITY_BLOCKS_LOADED:-}" ]] && return 0
_PRETOOLUSE_CAPABILITY_BLOCKS_LOADED=1

# NOTE: This is a *mistake-prevention* gate, not a security boundary.
# Real enforcement requires a capability launcher token (deferred — requires launcher-token isolation).
# detect eval/source with decoder (base64, rot13, xxd, openssl, python base64) — fail-closed.
# This blocks legitimate base64 use in eval; accept the false-positive rate as the security tradeoff.
_detect_decoder_in_eval() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -qE \
    '(eval|source|\.)[[:space:]]+[^|;&]*\b(base64[[:space:]]+(-d|--decode)|tr[[:space:]]+'"'"'?[A-Za-z-]+'"'"'?[[:space:]]+'"'"'?[A-Za-z-]+'"'"'?|xxd[[:space:]]+-r|openssl[[:space:]]+(base64|enc)[[:space:]]+-d|python3?[[:space:]]+-c[[:space:]]+.*(import[[:space:]]+base64|b64decode))'; then
    return 0
  fi
  return 1
}

block_capability_spoofing() {
  local cmd="$1"
  if _detect_decoder_in_eval "$cmd"; then
    echo "BLOCKED: eval/source with decoder (base64/rot13/xxd/openssl) — encoded capability bypass not permitted" >&2
    exit 2
  fi
  # base64 decode-and-exec patterns (not wrapped in eval/source — raw decode piped to shell).
  if printf '%s' "$cmd" | grep -qE \
    '\$\([^)]*base64[[:space:]]+(--decode|-d|-D)[^)]*\)|\$\([^)]*xxd[[:space:]]+-r[[:space:]]+-p[^)]*\)'; then
    echo "BLOCKED: base64/xxd decode in command substitution — encoded execution not permitted" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -qE \
    "eval[[:space:]]+\"\\\$\(|eval[[:space:]]+'\\$\("; then
    echo "BLOCKED: eval with \$(subshell) — dynamic execution not permitted" >&2
    exit 2
  fi
  local _decoded; _decoded=$(_decode_ansi_c "$cmd")
  # Assignment forms — raw + decoded check for = form
  if printf '%s' "$cmd" | grep -qE 'CLAUDE_PLAN_CAPABILITY[[:space:]]*=' || \
     printf '%s' "$_decoded" | grep -qE 'CLAUDE_PLAN_CAPABILITY[[:space:]]*=' || \
     printf '%s' "$cmd" | grep -qE 'read[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+CLAUDE_PLAN_CAPABILITY' || \
     printf '%s' "$cmd" | grep -qE 'printf[[:space:]]+-v[[:space:]]*["\x27]?CLAUDE_PLAN_CAPABILITY' || \
     printf '%s' "$cmd" | grep -qE 'export[[:space:]]+CLAUDE_PLAN_CAPABILITY([[:space:]]|;|$)' || \
     printf '%s' "$cmd" | grep -qE '(declare|typeset|local|readonly)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?CLAUDE_PLAN_CAPABILITY([[:space:]]|=|$)' || \
     printf '%s' "$cmd" | grep -qE '(mapfile|readarray)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?CLAUDE_PLAN_CAPABILITY'; then
    echo "BLOCKED: CLAUDE_PLAN_CAPABILITY assignment in agent Bash command — capability spoofing is not permitted" >&2
    exit 2
  fi
  printf '%s' "$cmd" | grep -qE '\bfor[[:space:]]+CLAUDE_PLAN_CAPABILITY([[:space:]]|$)' && \
    { echo "BLOCKED: for-loop assigns CLAUDE_PLAN_CAPABILITY — capability spoofing is not permitted" >&2; exit 2; } || true
  printf '%s' "$cmd" | grep -qE '\bprintf[[:space:]]+-v["\x27]?CLAUDE_PLAN_CAPABILITY' && \
    { echo "BLOCKED: printf -vCLAUDE_PLAN_CAPABILITY — capability spoofing is not permitted" >&2; exit 2; } || true
  printf '%s' "$cmd" | grep -qE '\bprintf[[:space:]]+[^;|&]*-v[[:space:]]+"?CLAUDE_PLAN_CAPABILITY"?' && \
    { echo "BLOCKED: printf -v CLAUDE_PLAN_CAPABILITY — capability spoofing is not permitted" >&2; exit 2; } || true
  printf '%s' "$cmd" | grep -qE \
    '\b(declare|local|typeset|export)[[:space:]]+(-[a-zA-Z][^[:space:]]*[[:space:]]+)*-n[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*=["'"'"']?CLAUDE_PLAN_CAPABILITY["'"'"']?' && \
    { echo "BLOCKED: nameref to CLAUDE_PLAN_CAPABILITY — capability spoofing is not permitted" >&2; exit 2; } || true
  printf '%s' "$cmd" | grep -qE \
    '\b(mapfile|readarray)[[:space:]]+([^[:space:]]+[[:space:]]+)*CLAUDE_PLAN_CAPABILITY([[:space:]]|$)' && \
    { echo "BLOCKED: mapfile/readarray into CLAUDE_PLAN_CAPABILITY — capability spoofing is not permitted" >&2; exit 2; } || true
  printf '%s' "$cmd" | grep -qE \
    '\bgetopts[[:space:]]+[^[:space:]]+[[:space:]]+CLAUDE_PLAN_CAPABILITY([[:space:]]|$)' && \
    { echo "BLOCKED: getopts CLAUDE_PLAN_CAPABILITY — capability spoofing is not permitted" >&2; exit 2; } || true
  # eval with quoted assignment — check raw and decoded
  if printf '%s' "$cmd" | grep -qE \
     '(^|[[:space:];|&])eval[[:space:]]+["\x27][^"\x27]*CLAUDE_PLAN_CAPABILITY[[:space:]]*=' || \
     printf '%s' "$_decoded" | grep -qE \
     '(^|[[:space:];|&])eval[[:space:]]+["\x27][^"\x27]*CLAUDE_PLAN_CAPABILITY[[:space:]]*='; then
    echo "BLOCKED: eval with quoted CLAUDE_PLAN_CAPABILITY assignment — capability spoofing is not permitted" >&2
    exit 2
  fi
  # eval referencing capability substring — check raw and decoded
  if printf '%s' "$cmd" | grep -qE '(^|[[:space:];|&])eval[[:space:]].*LAN_CAPABILITY' || \
     printf '%s' "$_decoded" | grep -qE '(^|[[:space:];|&])eval[[:space:]].*LAN_CAPABILITY'; then
    echo "BLOCKED: eval referencing CLAUDE_PLAN_CAPABILITY — capability spoofing is not permitted" >&2
    exit 2
  fi
  printf '%s' "$cmd" | grep -qE '(^|[[:space:];|&])eval[[:space:]]+["\x27]?\$\(.*LAN_CAPABILITY' && \
    { echo "BLOCKED: eval \$(...) referencing CLAUDE_PLAN_CAPABILITY — capability spoofing is not permitted" >&2; exit 2; } || true
  { printf '%s' "$cmd" | grep -qE 'CLAUDE"+"_PLAN"+"_CAPABILITY' || \
    printf '%s' "$cmd" | grep -qE "CLAUDE'+'_PLAN'+'_CAPABILITY"; } && \
    { echo "BLOCKED: string-concat form of CLAUDE_PLAN_CAPABILITY — capability spoofing is not permitted" >&2; exit 2; } || true
  printf '%s' "$cmd" | grep -qE \
    '(declare|typeset|export)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*"?\$\{?[a-zA-Z_][a-zA-Z0-9_]*\}?"?[[:space:]]*=' && \
    { echo "BLOCKED: indirect variable assignment via declare/typeset/export — potential capability spoofing" >&2; exit 2; } || true
  printf '%s' "$cmd" | grep -qE \
    '\bread[[:space:]]+([^[:space:]<]+[[:space:]]+)*CLAUDE_PLAN_CAPABILITY([[:space:]]|<<<|<[[:space:]]|$)' && \
    { echo "BLOCKED: read into CLAUDE_PLAN_CAPABILITY — capability spoofing is not permitted" >&2; exit 2; } || true
  printf '%s' "$cmd" | grep -qE '<<<[^|;&]*CLAUDE_PLAN_CAPABILITY' && \
    { echo "BLOCKED: here-string referencing CLAUDE_PLAN_CAPABILITY — capability spoofing is not permitted" >&2; exit 2; } || true
  # Substring guard for quote-evasion variants — check raw and decoded
  if printf '%s' "$cmd" | grep -qE 'LAN_CAPABILITY[[:space:]]*=' || \
     printf '%s' "$_decoded" | grep -qE 'LAN_CAPABILITY[[:space:]]*='; then
    echo "BLOCKED: command references CLAUDE_PLAN_CAPABILITY — agents must not name this capability" >&2
    exit 2
  fi
}

block_env_injection() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -qwE \
    'BASH_ENV|PROMPT_COMMAND|PS4|SHELLOPTS|BASHOPTS|LD_PRELOAD|LD_AUDIT|DYLD_INSERT_LIBRARIES'; then
    echo "BLOCKED: shell startup / library-injection env var detected" >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -qE '(^|[[:space:];|&])[[:space:]]*ENV[[:space:]]*='; then
    echo "BLOCKED: ENV= assignment — sources file before commands run" >&2
    exit 2
  fi
  # block interpreter environment injection vars (PATH hijack, startup files, preloads).
  # In harness mode only — human capability is allowed to manipulate PATH normally.
  if [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "harness" ]]; then
    if printf '%s' "$cmd" | grep -qE \
      '(^|[[:space:];|&])[[:space:]]*(PATH|PYTHONSTARTUP|PYTHONPATH|PYTHONHOME|PERL5LIB|RUBYOPT|NODE_OPTIONS|LD_LIBRARY_PATH|DYLD_LIBRARY_PATH|DYLD_INSERT_LIBRARIES|BASH_ENV)[[:space:]]*=[^=]'; then
      echo "BLOCKED: interpreter environment injection variable detected (PATH/PYTHONSTARTUP/etc) — use CLAUDE_PLAN_CAPABILITY=human to override" >&2
      exit 2
    fi
    # block git child-execution vectors and pager/preprocessor execution vectors
    if printf '%s' "$cmd" | grep -qE \
      '(^|[[:space:];|&])[[:space:]]*(GIT_SSH_COMMAND|GIT_EXTERNAL_DIFF|GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM|LESSOPEN|LESSCLOSE|MANOPT|LD_BIND_NOW|DYLD_FORCE_FLAT_NAMESPACE|ELECTRON_RUN_AS_NODE)[[:space:]]*=[^=]'; then
      echo "BLOCKED: git/pager execution-vector env var detected — use CLAUDE_PLAN_CAPABILITY=human to override" >&2
      exit 2
    fi
  fi
}

block_human_marker_commands() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -qE "(plan-file\\.sh|\\\$PLAN_FILE_SH|\\\$\{PLAN_FILE_SH\})[\"'[:space:]].*clear-marker"; then
    local _hm
    for _hm in "${HUMAN_MUST_CLEAR_MARKERS[@]}"; do
      if printf '%s' "$cmd" | grep -qF "$_hm"; then
        echo "BLOCKED: this marker cannot be cleared by Claude — human must run plan-file.sh clear-marker directly from terminal" >&2
        exit 2
      fi
    done
  fi
  if printf '%s' "$cmd" | grep -qE "plan-file\\.sh[\"'[:space:]].*unblock[[:space:]]"; then
    echo "BLOCKED: 'unblock' is a human-only command — run plan-file.sh unblock from terminal" >&2
    exit 2
  fi
}
