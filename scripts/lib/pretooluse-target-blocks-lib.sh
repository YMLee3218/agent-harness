#!/usr/bin/env bash
# PreToolUse write target helpers — destination extraction from bash commands.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PRETOOLUSE_TARGET_BLOCKS_LIB_LOADED:-}" ]] && return 0
_PRETOOLUSE_TARGET_BLOCKS_LIB_LOADED=1

# _extract_cp_mv_dest CMD — extracts destination from cp/mv invocations.
_extract_cp_mv_dest() {
  local _argv="$1" _t=""
  # case A: --target-directory=DIR or -t=DIR (equals form)
  _t=$(printf '%s' "$_argv" | grep -oE -- '(--target-directory|-t)=[^[:space:];|&]+' | head -1 | sed 's/^[^=]*=//' | tr -d '"'"'" || true)
  [[ -n "$_t" ]] && { printf '%s' "$_t"; return 0; }
  # case B: --target-directory DIR or -t DIR (space form)
  _t=$(printf '%s' "$_argv" | grep -oE -- '(--target-directory|-t)[[:space:]]+[^[:space:];|&][^[:space:];|&]*' | head -1 | awk '{print $NF}' | tr -d '"'"'" || true)
  [[ -n "$_t" ]] && { printf '%s' "$_t"; return 0; }
  # case C: last non-flag token
  printf '%s' "$_argv" | tr ' ' '\n' | grep -vE '^-' | tail -1 | tr -d '"'"'" || true
}

# _normalize_dest_token TOKEN — tokens containing unresolved variable expansion
# ($VAR, ${VAR}, $(...), `...`) cannot be safely evaluated here; treat them as
# sidecar paths so callers fail-closed rather than silently bypass.
_normalize_dest_token() {
  local t="$1"
  case "$t" in
    *'$'*|*'`'*) printf 'plans/__unexpanded__.state/__bypass__\n' ;;
    *)           printf '%s\n' "$t" ;;
  esac
}

# _bash_dest_paths CMD — extracts write-destination paths from a bash command string.
# Uses bash_get_redirect_targets when available; falls back to grep extraction.
_bash_dest_paths() {
  local c="$1"
  local _use_parser=0
  if declare -F bash_get_redirect_targets >/dev/null 2>&1; then
    _use_parser=1
    bash_get_redirect_targets "$c" 2>/dev/null | grep -v '^$' | while IFS= read -r _t; do _normalize_dest_token "$_t"; done || true
  fi
  if [[ "$_use_parser" -eq 0 ]]; then
    printf '%s' "$c" | grep -oE '>{1,2} *[^[:space:]]+' | sed 's/^>* *//' | tr -d '"'"'" | while IFS= read -r _t; do _normalize_dest_token "$_t"; done || true
  fi
  printf '%s' "$c" | grep -oE '\btee( +[^[:space:]]+)+' | sed 's/^tee *//' | tr ' ' '\n' | grep -v '^-' | while IFS= read -r _t; do _normalize_dest_token "$_t"; done || true
  local _cpmv _dest
  while IFS= read -r _cpmv; do
    [[ -n "$_cpmv" ]] || continue
    _dest=$(_extract_cp_mv_dest "$_cpmv")
    _normalize_dest_token "$_dest"
  done < <(printf '%s' "$c" | grep -oE '(^|[;|&[:space:]])(cp|mv)([[:space:]]+(-[[:alpha:]]+|--[a-zA-Z-]+=?[^[:space:];|&]*|[^[:space:];|&]+))+' || true)
  printf '%s' "$c" | grep -oE '\bsed +-i[^ ]*( +[^[:space:];|&]+)+' | awk '{print $NF}' | while IFS= read -r _t; do _normalize_dest_token "$_t"; done || true
  if [[ "$_use_parser" -eq 0 ]]; then
    printf '%s' "$c" | grep -oE '\bdd\b[^|]*\bof=[^[:space:]]+' | grep -oE '\bof=[^[:space:]]+' | sed 's/^of=//' | while IFS= read -r _t; do _normalize_dest_token "$_t"; done || true
  fi
  if printf '%s' "$c" | grep -qE '(python3?|perl|ruby|node|php|lua|R)[[:space:]]+-[ceEr][^[:alpha:]]'; then
    printf '%s' "$c" | \
      grep -oE "(open|write|writeFileSync|appendFileSync|createWriteStream|write_text)\(['\"][^'\"]+['\"]" | \
      grep -oE "['\"][^'\"]+['\"]" | tr -d "'\"" | while IFS= read -r _t; do _normalize_dest_token "$_t"; done || true
  fi
}
