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
  # Accept both lowercase and uppercase phase values; trim leading/trailing whitespace
  phase=$(awk '/^## Phase$/{found=1; next} found && /^[A-Za-z]/{print; exit} found && /^##/{exit}' "$plan_file" \
          | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
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
  # Replace the line after ## Phase (handles both lowercase and uppercase existing values)
  awk -v phase="$phase" '
    /^## Phase$/ { print; found=1; next }
    found && /^[A-Za-z]/ { print phase; found=0; next }
    found && !/^[A-Za-z]/ { print phase; print; found=0; next }
    { print }
  ' "$plan_file" > "${plan_file}.tmp" && mv "${plan_file}.tmp" "$plan_file"
  # Also sync frontmatter phase: field if present
  if grep -q "^phase:" "$plan_file"; then
    awk -v phase="$phase" '
      /^phase:/ { print "phase: " phase; next }
      { print }
    ' "$plan_file" > "${plan_file}.tmp" && mv "${plan_file}.tmp" "$plan_file"
  fi
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
  local plans_dir="${CLAUDE_PROJECT_DIR:-$PWD}/plans"
  [ -d "$plans_dir" ] || { exit 2; }

  _read_phase() {
    awk '/^## Phase$/{found=1; next} found && /^[A-Za-z]/{print; exit}' "$1" 2>/dev/null \
      | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' || true
  }

  # 1. Explicit env override (highest priority — use in multi-plan or CI scenarios)
  if [ -n "${CLAUDE_PLAN_FILE:-}" ]; then
    if [ -f "$CLAUDE_PLAN_FILE" ]; then
      local envphase
      envphase=$(_read_phase "$CLAUDE_PLAN_FILE")
      if [ -n "$envphase" ] && [ "$envphase" != "done" ]; then
        echo "$CLAUDE_PLAN_FILE"
        return 0
      fi
    fi
    # CLAUDE_PLAN_FILE set but not usable → fall through to other strategies
  fi

  # 2. Branch-based lookup: plans/{branch-slug}.md
  local branch
  branch=$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" symbolic-ref --short HEAD 2>/dev/null \
           | sed 's|.*/||; s|[^A-Za-z0-9_-]|-|g' || true)
  if [ -n "$branch" ] && [ -f "$plans_dir/${branch}.md" ]; then
    local bphase
    bphase=$(_read_phase "$plans_dir/${branch}.md")
    if [ -n "$bphase" ] && [ "$bphase" != "done" ]; then
      echo "$plans_dir/${branch}.md"
      return 0
    fi
  fi

  # 3. Fallback: newest plan file where Phase != done
  local found=""
  while IFS= read -r f; do
    local phase
    phase=$(_read_phase "$f")
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

cmd_find_latest() {
  local plans_dir="${CLAUDE_PROJECT_DIR:-$PWD}/plans"
  [ -d "$plans_dir" ] || { exit 2; }
  local f
  f=$(ls -t "$plans_dir"/*.md 2>/dev/null | head -1)
  [ -n "$f" ] && echo "$f" || exit 2
}

cmd_record_verdict() {
  require_jq
  local input
  input=$(cat)
  # Extract agent/subagent name and output
  # Field names per Claude Code SubagentStop payload; include fallback aliases
  local agent_name output
  agent_name=$(printf '%s' "$input" | jq -r '.agent_type // .subagent_type // "unknown"' 2>/dev/null || echo "unknown")
  output=$(printf '%s' "$input" | jq -r '.last_assistant_message // .tool_response // ""' 2>/dev/null || echo "")

  # Only record for critic-* agents
  case "$agent_name" in
    critic-*) ;;
    *) exit 0 ;;
  esac

  # Find active plan file
  local plan_file
  plan_file=$(cmd_find_active 2>/dev/null) || exit 2

  # Extract verdict from mandatory HTML marker: <!-- verdict: PASS --> or <!-- verdict: FAIL -->
  local verdict=""
  if printf '%s' "$output" | grep -q '<!-- verdict: PASS -->'; then
    verdict="PASS"
  elif printf '%s' "$output" | grep -q '<!-- verdict: FAIL -->'; then
    verdict="FAIL"
  fi

  local current_phase
  current_phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "unknown")

  if [ -z "$verdict" ]; then
    echo "[record-verdict] missing verdict marker from ${agent_name}" >&2
    cmd_append_verdict "$plan_file" "${current_phase}/${agent_name}: PARSE_ERROR"
    exit 2  # Signal hook failure so Claude Code can flag the missing marker
  else
    cmd_append_verdict "$plan_file" "${current_phase}/${agent_name}: ${verdict}"
  fi
}

cmd_context() {
  # Outputs JSON additionalContext for SessionStart hook injection.
  # If no active plan exists, exits 0 with no output (no context to inject).
  local plan_file
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0

  local phase
  phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "unknown")

  # Extract last 3 verdict lines from ## Critic Verdicts section
  local verdicts
  verdicts=$(awk '/^## Critic Verdicts$/{found=1; next} found && /^## /{found=0} found && /^- /{print}' \
    "$plan_file" 2>/dev/null | tail -3 | sed 's/^- //' | tr '\n' '|' | sed 's/|$//' || echo "none")

  # Extract open questions (non-blank lines in ## Open Questions section)
  local questions
  questions=$(awk '/^## Open Questions$/{found=1; next} found && /^## /{found=0} found && /[^[:space:]]/{print}' \
    "$plan_file" 2>/dev/null | head -5 | tr '\n' '|' | sed 's/|$//' || echo "none")

  # Emit JSON for hook additionalContext injection
  # Newlines inside JSON strings must be escaped; use printf with \n literal
  local body
  body="$(printf 'Active plan: %s | Phase: %s | Recent verdicts: %s | Open questions: %s' \
    "$plan_file" "$phase" "${verdicts:-none}" "${questions:-none}")"

  printf '{"additionalContext":"%s"}\n' \
    "$(printf '%s' "$body" | sed 's/"/\\"/g')"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

[ $# -ge 1 ] || die "Usage: plan-file.sh <command> [args...]"

case "$1" in
  get-phase)      [ $# -eq 2 ] || die "Usage: plan-file.sh get-phase <plan-file>"; cmd_get_phase "$2" ;;
  set-phase)      [ $# -eq 3 ] || die "Usage: plan-file.sh set-phase <plan-file> <phase>"; cmd_set_phase "$2" "$3" ;;
  append-verdict) [ $# -eq 3 ] || die "Usage: plan-file.sh append-verdict <plan-file> <label>"; cmd_append_verdict "$2" "$3" ;;
  find-active)    cmd_find_active ;;
  find-latest)    cmd_find_latest ;;
  record-verdict) cmd_record_verdict ;;
  context)        cmd_context ;;
  *) die "Unknown command: $1" ;;
esac
