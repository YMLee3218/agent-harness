#!/usr/bin/env bash
# PreToolUse hook for Skill tool.
# Blocks codex:* plugin skills when a human-must-clear marker is present.
# Exit 2 = blocked; exit 0 = allowed.
set -euo pipefail
# shellcheck source=lib/active-plan.sh
source "$(dirname "$0")/lib/active-plan.sh"
# shellcheck source=phase-policy.sh
source "$(dirname "$0")/phase-policy.sh"

input=$(cat)

require_jq_or_block "pretooluse-skill"

if ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
  echo "BLOCKED [phase-gate/skill]: malformed hook payload — cannot evaluate marker gate; failing closed" >&2
  exit 2
fi

[[ "${CLAUDE_PLAN_CAPABILITY:-}" == "human" ]] && exit 0

skill=$(printf '%s' "$input" | jq -r '.tool_input.skill // ""')
[[ "$skill" == codex:* ]] || exit 0

PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"
plan=""; phase=""
resolve_active_plan_and_phase plan phase || plan=""
[[ -z "$plan" ]] && exit 0

if _hmc=$(marker_present_human_must_clear "$plan" 2>/dev/null); then
  echo "BLOCKED [phase-gate/skill]: $_hmc present — codex plugin skill '$skill' prohibited; human must resolve and clear the marker from terminal" >&2
  exit 2
fi
