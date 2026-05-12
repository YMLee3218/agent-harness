#!/usr/bin/env bash
# trap body invariant lint — detect variable interpolation inside trap bodies.
# Usage: bash lint-traps.sh [DIRECTORY]
# Exits 0 if no violations found, 1 if violations found.
# Variable interpolation in trap bodies is unsafe: the variable value at trap-set time
# is captured, not at signal-fire time. Use stack arrays or global refs instead.
set -euo pipefail

_SCAN_DIR="${1:-scripts}"
_VIOLATIONS=0

_lint_file() {
  local _file="$1"
  # Only flag double-quoted trap bodies with $VAR interpolation.
  # Single-quoted trap bodies like trap 'rm -f "$VAR"' are SAFE:
  # $VAR is evaluated at fire-time, not set-time, which is the correct pattern.
  # Double-quoted trap "cmd $VAR" captures $VAR at set-time — unsafe if VAR changes.
  # Also flag ${VAR}, ${!VAR} (indirect), and $$ (PID at set-time) in double-quoted bodies.
  local _lineno=0
  while IFS= read -r _line; do
    _lineno=$(( _lineno + 1 ))
    printf '%s' "$_line" | grep -qE '^[[:space:]]*#' && continue
    if printf '%s' "$_line" | grep -qE 'trap[[:space:]]+"[^"]*\$(\{?[A-Za-z_{!]|\$)'; then
      echo "VIOLATION: ${_file}:${_lineno}: trap body contains variable interpolation (double-quoted \$VAR/\${VAR}/\${!VAR}/\$\$ — expanded at trap-set time):"
      echo "  $_line"
      _VIOLATIONS=$(( _VIOLATIONS + 1 ))
    fi
  done < "$_file"
}

# L6: self-check first — catch our own violations before reporting others.
_lint_file "${BASH_SOURCE[0]}"

while IFS= read -r -d '' _f; do
  # Skip self — already linted above.
  [[ "$_f" -ef "${BASH_SOURCE[0]}" ]] && continue
  _lint_file "$_f"
done < <(find "$_SCAN_DIR" -name '*.sh' -type f -print0 2>/dev/null)

if [[ "$_VIOLATIONS" -gt 0 ]]; then
  echo "[lint-traps] FAIL: ${_VIOLATIONS} violation(s) found" >&2
  exit 1
fi
echo "[lint-traps] OK: no trap body interpolation violations found" >&2
exit 0
