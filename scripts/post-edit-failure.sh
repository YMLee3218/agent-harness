#!/usr/bin/env bash
# PostToolUseFailure hook — records Write|Edit failures in the active plan file.
#
# Called when a Write or Edit tool call fails. Reads the tool payload from stdin
# and delegates to plan-file.sh record-tool-failure.
#
# Exit 0 always — recording a failure is advisory; hook must never block recovery.

set -euo pipefail

PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"

bash "$PLAN_FILE_SH" record-tool-failure || true
exit 0
