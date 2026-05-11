#!/usr/bin/env bash
# Hook input normalization — extract and syntactically validate tool commands.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_HOOK_INPUT_LOADED:-}" ]] && return 0
_HOOK_INPUT_LOADED=1

# hook_normalize_command JSON → prints extracted command string; returns 1 on failure.
# Uses jq to extract .tool_input.command, then bash -n for syntax check (no execution).
hook_normalize_command() {
  local _json="$1" _cmd=""
  command -v jq >/dev/null 2>&1 || { echo "" ; return 1; }
  _cmd=$(printf '%s' "$_json" | jq -r '.tool_input.command // empty' 2>/dev/null) || return 1
  [[ -n "$_cmd" ]] || return 1
  # Syntactic validation: bash -n parses but does not execute.
  # Failure here means the command string is not valid bash syntax.
  # We do NOT block on syntax errors — some valid commands may confuse the parser
  # (e.g. here-docs in single-line strings). We only use this for normalization.
  local _norm_cmd="$_cmd"
  if bash -n <(printf '%s\n' "$_cmd") 2>/dev/null; then
    _norm_cmd="$_cmd"
  fi
  printf '%s' "$_norm_cmd"
}

# hook_get_redirect_targets CMD → prints one redirect target path per line.
# Parses redirect operators (>, >>, dd of=) from the command string.
hook_get_redirect_targets() {
  local _cmd="$1"
  printf '%s' "$_cmd" | grep -oE '>{1,2} *[^[:space:]]+' | sed 's/^>* *//' | tr -d '"'"'" || true
  printf '%s' "$_cmd" | grep -oE '\bdd\b[^|]*\bof=[^[:space:]]+' | sed 's/.*of=//' || true
}
