#!/usr/bin/env bash
# Helper for reading/writing plan files under plans/
#
# Usage:
#   plan-file.sh get-phase <plan-file>
#       Prints the current phase value (brainstorm|spec|red|green|refactor|integration|done)
#       Exit 0 = success; exit 2 = file not found or Phase section missing
#
#   plan-file.sh set-phase <plan-file> <phase>
#       Replaces the value under ## Phase with <phase>
#       Exit 0 = success; exit 1 = error
#
#   plan-file.sh append-verdict <plan-file> <label>
#       Appends <label> (e.g. "spec/critic-spec: PASS") to ## Critic Verdicts
#       Exit 0 = success; exit 1 = error
#
#   plan-file.sh find-active
#       Prints the path of the newest plan file whose Phase is not "done"
#       Exit 0 = found; exit 2 = none found
#
#   plan-file.sh record-verdict
#       Reads SubagentStop JSON from stdin; extracts agent name + last PASS/FAIL line;
#       appends verdict to the active plan file.
#       Exit 0 = success; exit 1 = error; exit 2 = no active plan

set -euo pipefail

VALID_PHASES="brainstorm spec red green refactor integration done"

# ── Helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required but not found"
}

require_file() {
  [ -f "$1" ] || { echo "ERROR: plan file not found: $1" >&2; exit 2; }
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_get_phase() {
  local plan_file="$1"
  require_file "$plan_file"
  local phase
  phase=$(awk '/^## Phase$/{found=1; next} found && /^[a-z]/{print; exit} found && /^##/{exit}' "$plan_file")
  if [ -z "$phase" ]; then
    echo "ERROR: '## Phase' section not found or empty in $plan_file" >&2
    exit 2
  fi
  echo "$phase"
}

cmd_set_phase() {
  local plan_file="$1" phase="$2"
  require_file "$plan_file"
  # Validate phase
  local valid=0
  for p in $VALID_PHASES; do
    [ "$p" = "$phase" ] && valid=1 && break
  done
  [ "$valid" -eq 1 ] || die "invalid phase: $phase (must be one of: $VALID_PHASES)"
  # Replace the line after ## Phase
  awk -v phase="$phase" '
    /^## Phase$/ { print; found=1; next }
    found && /^[a-z]/ { print phase; found=0; next }
    found && /^[^a-z]/ { print phase; print; found=0; next }
    { print }
  ' "$plan_file" > "${plan_file}.tmp" && mv "${plan_file}.tmp" "$plan_file"
}

cmd_append_verdict() {
  local plan_file="$1" label="$2"
  require_file "$plan_file"
  # Find ## Critic Verdicts and append after its last entry
  if grep -q "^## Critic Verdicts$" "$plan_file"; then
    awk -v label="- $label" '
      /^## Critic Verdicts$/ { print; in_section=1; next }
      in_section && /^## / { print label; print ""; print; in_section=0; next }
      { print }
      END { if (in_section) print label }
    ' "$plan_file" > "${plan_file}.tmp" && mv "${plan_file}.tmp" "$plan_file"
  else
    echo "" >> "$plan_file"
    echo "## Critic Verdicts" >> "$plan_file"
    echo "- $label" >> "$plan_file"
  fi
}

cmd_find_active() {
  local plans_dir="plans"
  [ -d "$plans_dir" ] || { exit 2; }
  # Find newest plan file where Phase != done
  local found=""
  while IFS= read -r f; do
    local phase
    phase=$(awk '/^## Phase$/{found=1; next} found && /^[a-z]/{print; exit}' "$f" 2>/dev/null || true)
    if [ -n "$phase" ] && [ "$phase" != "done" ]; then
      found="$f"
      break
    fi
  done < <(ls -t "$plans_dir"/*.md 2>/dev/null)
  if [ -n "$found" ]; then
    echo "$found"
  else
    exit 2
  fi
}

cmd_record_verdict() {
  require_jq
  local input
  input=$(cat)
  # Extract agent/subagent name and output
  local agent_name output
  agent_name=$(printf '%s' "$input" | jq -r '.agent_name // .subagent_type // "unknown"' 2>/dev/null || echo "unknown")
  output=$(printf '%s' "$input" | jq -r '.output // .result // ""' 2>/dev/null || echo "")

  # Only record for critic-* agents
  case "$agent_name" in
    critic-*) ;;
    *) exit 0 ;;
  esac

  # Find active plan file
  local plan_file
  plan_file=$(cmd_find_active 2>/dev/null) || exit 2

  # Extract verdict line (last PASS or FAIL line)
  local verdict
  verdict=$(printf '%s' "$output" | grep -E '^(PASS|FAIL)' | tail -1 || true)
  [ -z "$verdict" ] && verdict="(no verdict line found)"

  local current_phase
  current_phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "unknown")
  cmd_append_verdict "$plan_file" "${current_phase}/${agent_name}: ${verdict}"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

[ $# -ge 1 ] || die "Usage: plan-file.sh <command> [args...]"

case "$1" in
  get-phase)      [ $# -eq 2 ] || die "Usage: plan-file.sh get-phase <plan-file>"; cmd_get_phase "$2" ;;
  set-phase)      [ $# -eq 3 ] || die "Usage: plan-file.sh set-phase <plan-file> <phase>"; cmd_set_phase "$2" "$3" ;;
  append-verdict) [ $# -eq 3 ] || die "Usage: plan-file.sh append-verdict <plan-file> <label>"; cmd_append_verdict "$2" "$3" ;;
  find-active)    cmd_find_active ;;
  record-verdict) cmd_record_verdict ;;
  *) die "Unknown command: $1" ;;
esac
