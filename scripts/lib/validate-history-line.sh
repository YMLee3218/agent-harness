#!/usr/bin/env bash
# Validates history.md lines from stdin against the 5 permitted formats.
# Exit 0: all lines valid (or only headers/blank lines).
# Exit 1: first invalid data line found (message on stderr).
#
# Permitted formats (harness-builder/CLAUDE.md §Bounded Context Policy):
#   YYYY-MM-DD HH:MM | iter=N | result=FIX      | file:line before→after
#   YYYY-MM-DD HH:MM | iter=N | result=RESIDUAL  | file:line or criterion-name | desc
#   YYYY-MM-DD HH:MM | iter=N | result=DISCARD   | <agent> | <file-hint> | <keyword>
#   YYYY-MM-DD HH:MM | iter=N | result=UNCITED   | <agent> | <file-hint> | <keyword>
#   YYYY-MM-DD HH:MM | iter=N | result=NOISSUE   | <agent> | <file:line> | <keyword>
#
# Lines starting with '#' and blank lines are always permitted.

set -euo pipefail

_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} \| iter=[^ |]+ \| result=(FIX|RESIDUAL|DISCARD|UNCITED|NOISSUE) \|'

_lineno=0
while IFS= read -r _line || [[ -n "${_line:-}" ]]; do
  _lineno=$((_lineno + 1))
  [[ -z "$_line" || "${_line:0:1}" == "#" ]] && continue
  if [[ ! "$_line" =~ $_PATTERN ]]; then
    printf 'history-format: invalid line %d: %s\n' "$_lineno" "$_line" >&2
    printf '  required: YYYY-MM-DD HH:MM | iter=N | result=FIX|RESIDUAL|DISCARD|UNCITED|NOISSUE | ...\n' >&2
    printf '  common mistake: date-only timestamp (missing HH:MM) or wrong result type\n' >&2
    exit 1
  fi
done

exit 0
