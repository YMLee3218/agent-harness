#!/usr/bin/env bash
# PreToolUse write target helpers — destination extraction from bash commands.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PRETOOLUSE_TARGET_BLOCKS_LIB_LOADED:-}" ]] && return 0
_PRETOOLUSE_TARGET_BLOCKS_LIB_LOADED=1

# _decode_ansi_c INPUT — decode ANSI-C quote escapes and Unicode/octal escapes.
# Handles: $'...' wrapper, \xNN hex, \NNN octal, \uNNNN/\UNNNNNNNN Unicode,
# adjacent $'...' segments, and common \n \t \\ escapes.
# Falls back to printf '%b' if python3 is unavailable. Returns original on failure.
_decode_ansi_c() {
  local _p="$1"
  # Strip surrounding $'...' wrapper if present, then join adjacent segment pairs.
  if [[ "$_p" == \$\'*\' ]]; then
    _p="${_p#\$\'}"
    _p="${_p%\'}"
  fi
  # Join adjacent $'...' segments: $'CLA''UDE_PLAN_CAPABILITY=harness' → CLA UDE_...
  # Remove '' join points: replace "'" "$'" with nothing (strip segment boundary)
  _p=$(printf '%s' "$_p" | sed "s/'\\\$'//g")
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$_p" <<'PY' 2>/dev/null || printf '%s' "$_p"
import sys, codecs
try:
    raw = sys.argv[1]
    # unicode_escape handles \xNN, \NNN, \uNNNN, \UNNNNNNNN, \n, \t, \\
    result = raw.encode('raw_unicode_escape').decode('unicode_escape')
    print(result, end='')
except Exception:
    print(sys.argv[1], end='')
PY
  else
    printf '%b' "$_p" 2>/dev/null || printf '%s' "$_p"
  fi
}

# _extract_cp_mv_dest CMD — extracts destination from cp/mv invocations.
_extract_cp_mv_dest() {
  local _argv="$1" _t=""
  # case A: --target-directory=DIR or -t=DIR (equals form)
  _t=$(printf '%s' "$_argv" | grep -oE -- '(--target-directory|-t)=[^[:space:];|&]+' | head -1 | sed 's/^[^=]*=//' || true)
  if [[ -n "$_t" ]]; then
    _t=$(printf '%s' "$_t" | sed "s/^\\\$'//; s/'\$//" | tr -d '"'"'")
    _decode_ansi_c "$_t"
    return 0
  fi
  # case B: --target-directory DIR or -t DIR (space form)
  _t=$(printf '%s' "$_argv" | grep -oE -- '(--target-directory|-t)[[:space:]]+[^[:space:];|&][^[:space:];|&]*' | head -1 | awk '{print $NF}' || true)
  if [[ -n "$_t" ]]; then
    _t=$(printf '%s' "$_t" | sed "s/^\\\$'//; s/'\$//" | tr -d '"'"'")
    _decode_ansi_c "$_t"
    return 0
  fi
  # case C: last non-flag token
  _t=$(printf '%s' "$_argv" | tr ' ' '\n' | grep -vE '^-' | tail -1 | sed "s/^\\\$'//; s/'\$//" | tr -d '"'"'" || true)
  _decode_ansi_c "$_t"
}

# _bash_dest_paths CMD — extracts write-destination paths from a bash command string.
# uses bash_get_redirect_targets (bash-parser.sh) when available; falls back to grep extraction.
_bash_dest_paths() {
  local c="$1" _raw_path _decoded
  # prefer bash-parser tokenizer for redirect target extraction (more accurate for quoted paths)
  local _use_parser=0
  if declare -F bash_get_redirect_targets >/dev/null 2>&1; then
    _use_parser=1
    while IFS= read -r _raw_path; do
      [[ -z "$_raw_path" ]] && continue
      _decoded=$(_decode_ansi_c "$_raw_path")
      printf '%s\n' "$_decoded"
    done < <(bash_get_redirect_targets "$c" 2>/dev/null || true)
  fi
  if [[ "$_use_parser" -eq 0 ]]; then
    # fallback: grep-based extraction (parser unavailable)
    while IFS= read -r _raw_path; do
      _decoded=$(_decode_ansi_c "$_raw_path")
      printf '%s\n' "$_decoded"
    done < <(printf '%s' "$c" | grep -oE '>{1,2} *[^[:space:]]+' | sed 's/^>* *//' | tr -d '"'"'" || true)
  fi
  while IFS= read -r _raw_path; do
    [[ "$_raw_path" == -* ]] && continue
    _decoded=$(_decode_ansi_c "$_raw_path")
    printf '%s\n' "$_decoded"
  done < <(printf '%s' "$c" | grep -oE '\btee( +[^[:space:]]+)+' | sed 's/^tee *//' | tr ' ' '\n' | grep -v '^-' || true)
  local _cpmv
  while IFS= read -r _cpmv; do
    if [[ -n "$_cpmv" ]]; then
      _extract_cp_mv_dest "$_cpmv"
      printf '\n'
    fi
  done < <(printf '%s' "$c" | grep -oE '(^|[;|&[:space:]])(cp|mv)([[:space:]]+(-[[:alpha:]]+|--[a-zA-Z-]+=?[^[:space:];|&]*|[^[:space:];|&]+))+' || true)
  while IFS= read -r _raw_path; do
    _decoded=$(_decode_ansi_c "$_raw_path")
    printf '%s\n' "$_decoded"
  done < <(printf '%s' "$c" | grep -oE '\bsed +-i[^ ]*( +[^[:space:];|&]+)+' | awk '{print $NF}' || true)
  # skip grep-based dd of= extraction when parser already covered it via DD_OF_TARGET tokens
  if [[ "$_use_parser" -eq 0 ]]; then
    while IFS= read -r _raw_path; do
      _decoded=$(_decode_ansi_c "$_raw_path")
      printf '%s\n' "$_decoded"
    done < <(printf '%s' "$c" | grep -oE '\bdd\b[^|]*\bof=[^[:space:]]+' | grep -oE '\bof=[^[:space:]]+' | sed 's/^of=//' || true)
  fi
  if printf '%s' "$c" | grep -qE '(python3?|perl|ruby|node|php|lua|R)[[:space:]]+-[ceEr][^[:alpha:]]'; then
    printf '%s' "$c" | \
      grep -oE "(open|write|writeFileSync|appendFileSync|createWriteStream|write_text)\(['\"][^'\"]+['\"]" | \
      grep -oE "['\"][^'\"]+['\"]" | tr -d "'\""  || true
  fi
}
