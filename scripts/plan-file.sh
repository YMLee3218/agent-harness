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
#   plan-file.sh append-note <plan-file> <note>
#       Appends <note> to ## Open Questions in the plan file.
#       Exit 0 = success; exit 1 = error
#
#   plan-file.sh find-active
#       Prints the path of the newest plan file whose Phase is not "done"
#       Exit 0 = found; exit 2 = none found or ambiguous (2+ candidates without disambiguation)
#
#   plan-file.sh record-verdict
#       Reads SubagentStop JSON from stdin; extracts agent name + last PASS/FAIL line;
#       appends verdict to the active plan file. Detects consecutive same-category FAILs
#       and writes [BLOCKED-CATEGORY] to ## Open Questions when detected.
#       Exit 0 = success; exit 1 = error; exit 2 = no active plan
#
#   plan-file.sh flush-before-compact
#       Called by PreCompact hook; reads JSON from stdin (compact_trigger field);
#       appends a [PRE-COMPACT] marker to ## Open Questions in the active plan file.
#       Exit 0 always (no active plan → silent skip).
#
#   plan-file.sh record-stopfail
#       Called by StopFailure hook; reads JSON from stdin (error_type field);
#       appends a [STOPFAIL] marker to ## Open Questions in the active plan file.
#       Exit 0 always (no active plan → silent skip).
#
#   plan-file.sh add-task <plan-file> <task-id> <layer>
#       Adds a row to ## Task Ledger with status=pending.
#       Exit 0 = success; exit 1 = error
#
#   plan-file.sh update-task <plan-file> <task-id> <status> [commit-sha]
#       Updates an existing row in ## Task Ledger. Status: pending|in_progress|completed|blocked.
#       Exit 0 = success; exit 1 = error

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

# Appends <note> to the ## Open Questions section of <plan_file>.
# Creates the section if absent.
_append_to_open_questions() {
  local plan_file="$1" note="$2"
  if grep -q "^## Open Questions$" "$plan_file"; then
    awk -v note="$note" '
      /^## Open Questions$/ { print; in_section=1; next }
      in_section && /^## / { print note; print ""; print; in_section=0; next }
      { print }
      END { if (in_section) print note }
    ' "$plan_file" > "${plan_file}.tmp" && mv "${plan_file}.tmp" "$plan_file"
  else
    { echo ""; echo "## Open Questions"; echo "$note"; } >> "$plan_file"
  fi
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
  # Fail-closed when 2+ candidates exist — ambiguous without CLAUDE_PLAN_FILE or branch-slug.
  local found="" count=0
  while IFS= read -r f; do
    local phase
    phase=$(_read_phase "$f")
    if [ -n "$phase" ] && [ "$phase" != "done" ]; then
      count=$((count + 1))
      [ -z "$found" ] && found="$f"
    fi
  done < <(ls -t "$plans_dir"/*.md 2>/dev/null)
  if [ "$count" -eq 0 ]; then
    exit 2
  elif [ "$count" -ge 2 ]; then
    echo "ERROR: ${count} active plan files found with no CLAUDE_PLAN_FILE or branch-slug match. Set CLAUDE_PLAN_FILE=plans/{slug}.md or align branch name with plan file name." >&2
    exit 2
  else
    echo "[plan-file] WARNING: falling back to newest plan ($found). Set CLAUDE_PLAN_FILE or use worktrees to disambiguate when running multiple features in parallel." >&2
    echo "$found"
  fi
}

cmd_find_latest() {
  local plans_dir="${CLAUDE_PROJECT_DIR:-$PWD}/plans"
  [ -d "$plans_dir" ] || { exit 2; }
  local f
  f=$(ls -t "$plans_dir"/*.md 2>/dev/null | head -1)
  [ -n "$f" ] && echo "$f" || exit 2
}

cmd_append_note() {
  local plan_file="$1" note="$2"
  require_file "$plan_file"
  _append_to_open_questions "$plan_file" "$note"
}

cmd_flush_before_compact() {
  # PreCompact hook: records a marker in the active plan so the next session knows a compact occurred.
  require_jq
  local input
  input=$(cat)
  local compact_trigger
  compact_trigger=$(printf '%s' "$input" | jq -r '.compact_trigger // "unknown"' 2>/dev/null || echo "unknown")

  local plan_file
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0  # no active plan → nothing to do

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
  local note="[PRE-COMPACT @${ts}] trigger=${compact_trigger} — SessionStart will re-inject plan summary; review open items after restart"
  _append_to_open_questions "$plan_file" "$note"
  echo "[flush-before-compact] recorded pre-compact marker (trigger=${compact_trigger}) in ${plan_file}" >&2
}

cmd_record_stopfail() {
  # StopFailure hook: records a resumable marker when the session is interrupted.
  require_jq
  local input
  input=$(cat)
  local error_type
  error_type=$(printf '%s' "$input" | jq -r '.error_type // "unknown"' 2>/dev/null || echo "unknown")

  local plan_file
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0  # no active plan → nothing to do

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
  local note="[STOPFAIL] error_type=${error_type} @${ts} — session interrupted; resume with /implementing or check plan phase"
  _append_to_open_questions "$plan_file" "$note"
  echo "[record-stopfail] recorded stop-failure marker (error_type=${error_type}) in ${plan_file}" >&2
}

cmd_record_verdict() {
  require_jq
  local input
  input=$(cat)
  # Extract agent name from canonical SubagentStop payload field
  local agent_name
  agent_name=$(printf '%s' "$input" | jq -r '.agent_type // "unknown"' 2>/dev/null || echo "unknown")

  # Only record for critic-* agents
  case "$agent_name" in
    critic-*) ;;
    *) exit 0 ;;
  esac

  # Extract output text — three strategies in priority order:
  # 1. agent_transcript_path: subagent-only transcript (canonical SubagentStop field); no
  #    cross-critic contamination risk, so read the full file.
  # 2. transcript_path: full session transcript (fallback); limit to tail -200 to reduce
  #    risk of picking up a different critic's verdict from an earlier subagent in the same session.
  # 3. last_assistant_message: in-payload field (canonical SubagentStop field); used when
  #    no transcript file is present (e.g. test fixtures, CI environments without file I/O).
  local output=""
  local agent_transcript transcript
  agent_transcript=$(printf '%s' "$input" | jq -r '.agent_transcript_path // empty' 2>/dev/null || true)
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
  if [ -n "$agent_transcript" ] && [ -f "$agent_transcript" ]; then
    output=$(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text // empty' \
             "$agent_transcript" 2>/dev/null || true)
  elif [ -n "$transcript" ] && [ -f "$transcript" ]; then
    output=$(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text // empty' \
             "$transcript" 2>/dev/null | tail -200 || true)
  fi
  if [ -z "$output" ]; then
    output=$(printf '%s' "$input" | jq -r '.last_assistant_message // ""' 2>/dev/null || echo "")
  fi

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
    local input_keys
    input_keys=$(printf '%s' "$input" | jq -r 'keys | join(", ")' 2>/dev/null || echo "unknown")
    echo "[record-verdict] missing verdict marker from ${agent_name} (payload keys: ${input_keys})" >&2
    cmd_append_verdict "$plan_file" "${current_phase}/${agent_name}: PARSE_ERROR"
    # Mark plan as blocked so phase-gate can surface this to the next session
    local blocked_marker="[BLOCKED] critic verdict missing — investigate ${agent_name}"
    if grep -q "^## Open Questions$" "$plan_file"; then
      awk -v marker="$blocked_marker" '
        /^## Open Questions$/ { print; in_section=1; next }
        in_section && /^## / { print marker; print ""; print; in_section=0; next }
        { print }
        END { if (in_section) print marker }
      ' "$plan_file" > "${plan_file}.tmp" && mv "${plan_file}.tmp" "$plan_file"
    fi
    exit 2  # Signal hook failure so Claude Code can flag the missing marker
  fi

  # Extract category from <!-- category: X --> marker (required on FAIL, optional on PASS)
  local category=""
  category=$(printf '%s' "$output" | grep -o '<!-- category: [A-Z_]* -->' | head -1 \
             | sed 's/<!-- category: //; s/ -->//' || true)

  # Build verdict label (include category if present)
  local verdict_label="${current_phase}/${agent_name}: ${verdict}"
  if [ -n "$category" ]; then
    verdict_label="${verdict_label} [category: ${category}]"
  fi

  # Consecutive same-category FAIL detection
  if [ "$verdict" = "FAIL" ] && [ -n "$category" ]; then
    # Look at the last verdict line for this agent in the plan file
    local last_verdict_line
    last_verdict_line=$(grep "/${agent_name}: FAIL" "$plan_file" 2>/dev/null | tail -1 || true)
    if [ -n "$last_verdict_line" ]; then
      local last_category
      last_category=$(printf '%s' "$last_verdict_line" | grep -o '\[category: [A-Z_]*\]' \
                      | sed 's/\[category: //; s/\]//' || true)
      if [ -n "$last_category" ] && [ "$last_category" = "$category" ]; then
        local blocked_marker="[BLOCKED-CATEGORY] ${agent_name}: category ${category} failed twice — fix the root cause before retrying"
        if grep -q "^## Open Questions$" "$plan_file"; then
          awk -v marker="$blocked_marker" '
            /^## Open Questions$/ { print; in_section=1; next }
            in_section && /^## / { print marker; print ""; print; in_section=0; next }
            { print }
            END { if (in_section) print marker }
          ' "$plan_file" > "${plan_file}.tmp" && mv "${plan_file}.tmp" "$plan_file"
        fi
        cmd_append_verdict "$plan_file" "$verdict_label"
        echo "[record-verdict] consecutive same-category FAIL (${category}) from ${agent_name} — blocked" >&2
        exit 2
      fi
    fi
  fi

  cmd_append_verdict "$plan_file" "$verdict_label"
}

cmd_add_task() {
  local plan_file="$1" task_id="$2" layer="$3"
  require_file "$plan_file"
  local row="| ${task_id} | ${layer} | pending | - |"
  if grep -q "^## Task Ledger$" "$plan_file"; then
    # Append row before the next ## section (or at end)
    awk -v row="$row" '
      /^## Task Ledger$/ { print; in_section=1; next }
      in_section && /^\| task-id/ { print; next }
      in_section && /^\|---/ { print; next }
      in_section && /^## / { print row; print ""; print; in_section=0; next }
      { print }
      END { if (in_section) print row }
    ' "$plan_file" > "${plan_file}.tmp" && mv "${plan_file}.tmp" "$plan_file"
  else
    # Create Task Ledger section at end of file
    {
      echo ""
      echo "## Task Ledger"
      echo "| task-id | layer | status | commit-sha |"
      echo "|---------|-------|--------|------------|"
      echo "$row"
    } >> "$plan_file"
  fi
}

cmd_update_task() {
  local plan_file="$1" task_id="$2" status="$3" commit_sha="${4:--}"
  require_file "$plan_file"
  local valid_statuses="pending in_progress completed blocked"
  local valid=0
  for s in $valid_statuses; do [ "$s" = "$status" ] && valid=1 && break; done
  [ "$valid" -eq 1 ] || die "invalid status: $status (must be one of: $valid_statuses)"
  # Replace the matching row
  awk -v tid="$task_id" -v status="$status" -v sha="$commit_sha" '
    /^\| / {
      # Extract task-id field (second | delimited field)
      n = split($0, fields, "|")
      if (n >= 5) {
        id = fields[2]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
        if (id == tid) {
          layer = fields[3]
          printf "| %s |%s| %s | %s |\n", tid, layer, status, sha
          next
        }
      }
    }
    { print }
  ' "$plan_file" > "${plan_file}.tmp" && mv "${plan_file}.tmp" "$plan_file"
}

cmd_context() {
  # Outputs canonical SessionStart hook JSON for plan context injection.
  # Format: {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}
  # If no active plan exists, exits 0 with no output (no context to inject).
  require_jq
  local plan_file
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0

  local phase
  phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "unknown")

  # Extract last 3 verdict lines from ## Critic Verdicts section
  local verdicts
  verdicts=$(awk '/^## Critic Verdicts$/{found=1; next} found && /^## /{found=0} found && /^- /{print}' \
    "$plan_file" 2>/dev/null | tail -3 | sed 's/^- //' | tr '\n' '|' | sed 's/|$//' || echo "none")

  # Extract open questions: [BLOCKED*] items first (up to 3), then others (up to 2)
  local blocked_items other_items questions
  blocked_items=$(awk '/^## Open Questions$/{found=1; next} found && /^## /{found=0} found && /\[BLOCKED/{print}' \
    "$plan_file" 2>/dev/null | head -3 | tr '\n' '|' | sed 's/|$//' || true)
  other_items=$(awk '/^## Open Questions$/{found=1; next} found && /^## /{found=0} found && /[^[:space:]]/ && !/\[BLOCKED/{print}' \
    "$plan_file" 2>/dev/null | head -2 | tr '\n' '|' | sed 's/|$//' || true)

  if [ -n "$blocked_items" ] && [ -n "$other_items" ]; then
    questions="${blocked_items}|${other_items}"
  elif [ -n "$blocked_items" ]; then
    questions="$blocked_items"
  elif [ -n "$other_items" ]; then
    questions="$other_items"
  else
    questions="none"
  fi

  # Build body and cap at 800 chars to prevent context bloat
  local body_raw body
  body_raw="$(printf 'Active plan: %s | Phase: %s | Recent verdicts: %s | Open questions: %s' \
    "$plan_file" "$phase" "${verdicts:-none}" "$questions")"
  if [ "${#body_raw}" -gt 800 ]; then
    body="${body_raw:0:797}..."
  else
    body="$body_raw"
  fi

  # jq --arg handles all escaping; $ctx is inserted as a properly escaped JSON string
  jq -nc --arg ctx "$body" \
    '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$ctx}}'
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

[ $# -ge 1 ] || die "Usage: plan-file.sh <command> [args...]"

case "$1" in
  get-phase)            [ $# -eq 2 ] || die "Usage: plan-file.sh get-phase <plan-file>"; cmd_get_phase "$2" ;;
  set-phase)            [ $# -eq 3 ] || die "Usage: plan-file.sh set-phase <plan-file> <phase>"; cmd_set_phase "$2" "$3" ;;
  append-verdict)       [ $# -eq 3 ] || die "Usage: plan-file.sh append-verdict <plan-file> <label>"; cmd_append_verdict "$2" "$3" ;;
  append-note)          [ $# -eq 3 ] || die "Usage: plan-file.sh append-note <plan-file> <note>"; cmd_append_note "$2" "$3" ;;
  find-active)          cmd_find_active ;;
  find-latest)          cmd_find_latest ;;
  record-verdict)       cmd_record_verdict ;;
  flush-before-compact) cmd_flush_before_compact ;;
  record-stopfail)      cmd_record_stopfail ;;
  context)              cmd_context ;;
  add-task)             [ $# -eq 4 ] || die "Usage: plan-file.sh add-task <plan-file> <task-id> <layer>"; cmd_add_task "$2" "$3" "$4" ;;
  update-task)          [ $# -ge 4 ] || die "Usage: plan-file.sh update-task <plan-file> <task-id> <status> [commit-sha]"; cmd_update_task "$2" "$3" "$4" "${5:--}" ;;
  *) die "Unknown command: $1" ;;
esac
