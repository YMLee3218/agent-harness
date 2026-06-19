#!/usr/bin/env bash
# Shell invariant lint. Two checks:
#   1. Trap body interpolation — variable interpolation inside double-quoted trap bodies is
#      unsafe: the value at trap-set time is captured, not at signal-fire time. Use stack
#      arrays or global refs instead.
#   2. Raw engine spawn — every LLM/agent spawn must go through run_engine
#      (scripts/lib/engine-runner.sh) so the fail-closed sandbox gate cannot be bypassed.
#      A `codex exec`/`claude` spawn outside the dispatcher is a missed migration.
# Usage: bash lint-traps.sh [DIRECTORY]
# Exits 0 if no violations found, 1 if violations found.
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

# Raw-engine-spawn invariant: flag the two real spawn signatures anywhere outside the
# engine-runner.sh dispatcher (comments excluded). Both signatures legitimately live only
# in engine-runner.sh; any other match is a spawn site that bypasses the central gate.
_lint_engine_spawn() {
  local _file="$1"
  [[ "$(basename "$_file")" == "engine-runner.sh" ]] && return 0
  local _lineno=0
  while IFS= read -r _line; do
    _lineno=$(( _lineno + 1 ))
    printf '%s' "$_line" | grep -qE '^[[:space:]]*#' && continue
    if printf '%s' "$_line" | grep -qE 'codex exec --dangerously-bypass-approvals-and-sandbox|claude --permission-mode auto --dangerously-skip-permissions'; then
      echo "VIOLATION: ${_file}:${_lineno}: raw engine spawn — route through run_engine (scripts/lib/engine-runner.sh) so the fail-closed sandbox gate is not bypassed:"
      echo "  $_line"
      _VIOLATIONS=$(( _VIOLATIONS + 1 ))
    fi
  done < "$_file"
}

# L6: self-check first — catch our own violations before reporting others.
_lint_file "${BASH_SOURCE[0]}"

while IFS= read -r -d '' _f; do
  # Skip self — already linted above (and our regex strings would self-match the spawn check).
  [[ "$_f" -ef "${BASH_SOURCE[0]}" ]] && continue
  _lint_file "$_f"
  _lint_engine_spawn "$_f"
done < <(find "$_SCAN_DIR" -name '*.sh' -type f -print0 2>/dev/null)

if [[ "$_VIOLATIONS" -gt 0 ]]; then
  echo "[lint-traps] FAIL: ${_VIOLATIONS} violation(s) found" >&2
  exit 1
fi
echo "[lint-traps] OK: no trap body interpolation violations found" >&2
exit 0
