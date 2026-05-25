#!/usr/bin/env bash
# PreToolUse hook for Agent tool.
# Blocks subagent spawning when a human-must-clear marker is present.
# Exit 2 = blocked; exit 0 = allowed.
set -euo pipefail
# shellcheck source=lib/active-plan.sh
source "$(dirname "$0")/lib/active-plan.sh"
# shellcheck source=phase-policy.sh
source "$(dirname "$0")/phase-policy.sh"

input=$(cat)

require_jq_or_block "pretooluse-agent"

[[ "${CLAUDE_PLAN_CAPABILITY:-}" == "human" ]] && exit 0

subagent=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""')

PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"
plan=""; phase=""
resolve_active_plan_and_phase plan phase 2>/dev/null || plan=""
[[ -z "$plan" ]] && exit 0

if _hmc=$(marker_present_human_must_clear "$plan" 2>/dev/null); then
  echo "BLOCKED [phase-gate/agent]: $_hmc present — spawning subagent '${subagent:-unknown}' prohibited; human must resolve and clear the marker from terminal" >&2
  exit 2
fi
