#!/usr/bin/env bash
# D5: bash command tokenizer — minimal redirect/pipe/subshell analysis without execution.
# Uses bash -n for syntax validation and grep-based token extraction for redirect targets.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_BASH_PARSER_LOADED:-}" ]] && return 0
_BASH_PARSER_LOADED=1

# parse_bash_command CMD → prints JSON-like token summary to stdout.
# Format: one token per line: TYPE:VALUE (REDIRECT_TARGET, PIPE, SUBSHELL, HEREDOC)
parse_bash_command() {
  local _cmd="$1"
  # Redirect targets (>, >>)
  printf '%s' "$_cmd" | grep -oE '>{1,2}[[:space:]]*[^[:space:];|&]+' | \
    sed 's/^>*[[:space:]]*//' | while IFS= read -r _t; do
      [[ -n "$_t" ]] && printf 'REDIRECT_TARGET:%s\n' "$_t"
    done || true
  # dd of= targets
  printf '%s' "$_cmd" | grep -oE '\bof=[^[:space:]]+' | sed 's/^of=//' | while IFS= read -r _t; do
    [[ -n "$_t" ]] && printf 'DD_OF_TARGET:%s\n' "$_t"
  done || true
  # Pipe presence
  printf '%s' "$_cmd" | grep -qE '[^|]\|[^|]' && printf 'PIPE:present\n' || true
  # Subshell presence
  printf '%s' "$_cmd" | grep -qE '\$\(' && printf 'SUBSHELL:command_substitution\n' || true
  printf '%s' "$_cmd" | grep -qE '\(.*\)' && printf 'SUBSHELL:grouping\n' || true
  # Heredoc presence
  printf '%s' "$_cmd" | grep -qE '<<' && printf 'HEREDOC:present\n' || true
}

# bash_get_redirect_targets CMD → prints redirect target paths, one per line.
bash_get_redirect_targets() {
  local _cmd="$1"
  parse_bash_command "$_cmd" | grep '^REDIRECT_TARGET:\|^DD_OF_TARGET:' | cut -d: -f2- | tr -d '"'"'" || true
}
