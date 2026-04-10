#!/usr/bin/env bash
# Helper for reading/writing plan files under plans/
#
# Usage:
#   plan-file.sh get-phase <plan-file>
#       Prints the current phase value (brainstorm|spec|red|green|integration|done)
#       Exit 0 = success; exit 2 = file not found or Phase section missing
#
#   plan-file.sh set-phase <plan-file> <phase>
#       Replaces the value under ## Phase (and frontmatter phase: field) with <phase>.
#       Also writes to <plan-file%.md>.state.json for machine-read durability.
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
#   plan-file.sh record-critic-start
#       Called by SubagentStart hook for critic-.* agents; reads JSON from stdin;
#       appends a [START] entry to ## Critic Runs (created if absent) with phase + timestamp.
#       Exit 0 always (non-critic agents ignored; no active plan → silent skip).
#
#   plan-file.sh flush-before-compact
#       Called by PreCompact hook; reads JSON from stdin (compact_trigger field);
#       appends a [PRE-COMPACT] marker to ## Open Questions in the active plan file.
#       Exit 0 always (no active plan → silent skip).
#
#   plan-file.sh log-post-compact
#       Called by PostCompact hook; appends a [POST-COMPACT] sanity log entry with
#       current phase and open-question count to ## Open Questions in the active plan file.
#       Exit 0 always (no active plan → silent skip).
#
#   plan-file.sh flush-on-end
#       Called by SessionEnd hook; reads JSON from stdin (reason field);
#       appends a [SESSION-END] marker to ## Open Questions in the active plan file.
#       Exit 0 always (no active plan → silent skip).
#
#   plan-file.sh record-stopfail
#       Called by StopFailure hook; reads JSON from stdin (error_type field);
#       appends a [STOPFAIL] marker to ## Open Questions in the active plan file.
#       Exit 0 always (no active plan → silent skip).
#
#   plan-file.sh record-tool-failure
#       Called by PostToolUseFailure hook for Write|Edit tools; reads JSON from stdin;
#       appends a [TOOL-FAIL] marker to ## Open Questions in the active plan file.
#       Exit 0 always (no active plan → silent skip).
#
#   plan-file.sh add-task <plan-file> <task-id> <layer>
#       Adds a row to ## Task Ledger with status=pending.
#       Exit 0 = success; exit 1 = error
#
#   plan-file.sh update-task <plan-file> <task-id> <status> [commit-sha]
#       Updates an existing row in ## Task Ledger. Status: pending|in_progress|completed|blocked.
#       Exit 0 = success; exit 1 = error
#
#   plan-file.sh gc-events
#       Compacts ## Open Questions in the active plan: keeps [BLOCKED*] items,
#       the last [SESSION-END] and [POST-COMPACT] entry; discards other audit markers.
#       Exit 0 always (no active plan → silent skip).
#
#   plan-file.sh migrate-to-json [plan-file]
#       Creates a .state.json sidecar from an existing Markdown plan file.
#       Exit 0 = success; exit 1 = error

set -euo pipefail

VALID_PHASES="brainstorm spec red green integration done"

# ── Helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

# Atomic awk-in-place: runs awk with given args on plan_file, writes result back
# atomically using mktemp + advisory lock to prevent lost-update when parallel hooks
# write concurrently. Uses flock(1) when available (Linux), otherwise falls back to
# mkdir-based advisory lock (POSIX-atomic; works on macOS and any POSIX filesystem).
# Usage: _awk_inplace <plan_file> [awk-args...] <awk-script>
_awk_inplace() {
  local plan_file="$1"; shift
  local tmp_file
  tmp_file=$(mktemp "${plan_file}.XXXXXX")

  if command -v flock >/dev/null 2>&1; then
    local lock_file="${plan_file}.lock"
    (
      flock -w 5 200 || { rm -f "$tmp_file"; return 1; }
      if awk "$@" "$plan_file" > "$tmp_file"; then
        mv "$tmp_file" "$plan_file"
      else
        rm -f "$tmp_file"
        return 1
      fi
    ) 200>"$lock_file"
  else
    # mkdir is atomic on POSIX: only one caller succeeds, others spin-wait
    local lock_dir="${plan_file}.lock"
    local retries=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
      # Stale lock recovery: if the holding process is dead, remove the lock
      if [ -f "${lock_dir}/pid" ]; then
        local holder_pid
        holder_pid=$(cat "${lock_dir}/pid" 2>/dev/null || echo "")
        if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
          rm -f "${lock_dir}/pid" 2>/dev/null || true
          rmdir "$lock_dir" 2>/dev/null || true
          continue
        fi
      fi
      retries=$((retries + 1))
      [ "$retries" -ge 50 ] && { rm -f "$tmp_file"; echo "ERROR: lock timeout for ${plan_file}" >&2; return 1; }
      sleep 0.1
    done
    # Record PID so other waiters can detect if we die while holding the lock
    echo $$ > "${lock_dir}/pid" 2>/dev/null || true
    if awk "$@" "$plan_file" > "$tmp_file"; then
      mv "$tmp_file" "$plan_file"
      rm -f "${lock_dir}/pid" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null
    else
      rm -f "$tmp_file"
      rm -f "${lock_dir}/pid" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null
      return 1
    fi
  fi
}

# ── JSON state helpers (P1-1) ─────────────────────────────────────────────────
# Machine-readable phase state is stored in {slug}.state.json alongside the
# Markdown plan file. This prevents awk-parsed phase from being silently
# overwritten when LLM edits adjacent Markdown sections.
# Anthropic "Effective Harnesses": JSON format for machine state prevents model overwrites.

_state_file() { printf '%s' "${1%.md}.state.json"; }

_state_get_phase() {
  local state_file
  state_file=$(_state_file "$1")
  [ -f "$state_file" ] && jq -r '.phase // empty' "$state_file" 2>/dev/null || true
}

_state_set_phase() {
  local plan_file="$1" phase="$2"
  require_jq
  local state_file
  state_file=$(_state_file "$plan_file")
  local tmp_file
  tmp_file=$(mktemp "${state_file}.XXXXXX")
  if [ -f "$state_file" ]; then
    jq --arg phase "$phase" '.phase = $phase' "$state_file" > "$tmp_file"
  else
    jq -nc --arg phase "$phase" '{"schema":2,"phase":$phase}' > "$tmp_file"
  fi
  mv "$tmp_file" "$state_file"
}

# ── Schema validation ─────────────────────────────────────────────────────────

# Validates plan file schema version from frontmatter (schema: N field).
# schema 0 / missing → warning only. schema 1 → OK. schema > 1 → hard-fail.
_check_schema() {
  local plan_file="$1"
  local schema_ver
  schema_ver=$(awk '/^---$/{in_fm=!in_fm; next} in_fm && /^schema:/{print $2; exit}' "$plan_file" 2>/dev/null \
              | tr -d '[:space:]' || echo "")
  case "${schema_ver:-0}" in
    0) echo "[plan-file] WARNING: plan file has no schema version; treating as schema 0" >&2 ;;
    1) ;;  # current version, OK
    *) die "unsupported plan file schema version: ${schema_ver} (supported: 0, 1)" ;;
  esac
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required but not found"
}

require_file() {
  [ -f "$1" ] || { echo "ERROR: plan file not found: $1" >&2; exit 2; }
}

# ── Section-append helpers ────────────────────────────────────────────────────

# Appends <note> to the ## Open Questions section of <plan_file>.
# Creates the section if absent.
_append_to_open_questions() {
  local plan_file="$1" note="$2"
  if grep -q "^## Open Questions$" "$plan_file"; then
    _awk_inplace "$plan_file" -v note="$note" '
      /^## Open Questions$/ { print; in_section=1; next }
      in_section && /^## / { print note; print ""; print; in_section=0; next }
      { print }
      END { if (in_section) print note }
    '
  else
    { echo ""; echo "## Open Questions"; echo "$note"; } >> "$plan_file"
  fi
}

# Appends <entry> to the ## Critic Runs section of <plan_file>.
# Creates the section if absent. Used for SubagentStart audit entries.
_append_to_critic_runs() {
  local plan_file="$1" entry="$2"
  if grep -q "^## Critic Runs$" "$plan_file"; then
    _awk_inplace "$plan_file" -v entry="- $entry" '
      /^## Critic Runs$/ { print; in_section=1; next }
      in_section && /^## / { print entry; print ""; print; in_section=0; next }
      { print }
      END { if (in_section) print entry }
    '
  else
    { echo ""; echo "## Critic Runs"; echo "- $entry"; } >> "$plan_file"
  fi
}

# Common event-recording helper: appends a timestamped marker to ## Open Questions.
# Usage: _append_event_to_plan <plan_file> <MARKER> <detail-text>
_append_event_to_plan() {
  local plan_file="$1" marker="$2" detail="$3"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
  _append_to_open_questions "$plan_file" "[${marker} @${ts}] ${detail}"
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_get_phase() {
  local plan_file="$1"
  require_file "$plan_file"
  # Prefer JSON state file (authoritative for machine reads — not subject to LLM overwrites)
  local phase
  phase=$(_state_get_phase "$plan_file")
  if [ -n "$phase" ]; then
    echo "$phase"
    return 0
  fi
  # Fall back to Markdown parsing for plan files without a state sidecar
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
  _check_schema "$plan_file"
  # Validate phase
  local valid=0
  for p in $VALID_PHASES; do
    [ "$p" = "$phase" ] && valid=1 && break
  done
  [ "$valid" -eq 1 ] || die "invalid phase: $phase (must be one of: $VALID_PHASES)"

  # Write to JSON state (authoritative; atomic via mktemp)
  _state_set_phase "$plan_file" "$phase"

  # Also update Markdown for human visibility — single awk pass handles both
  # frontmatter phase: field and ## Phase body (P1-2: eliminates double-write race).
  _awk_inplace "$plan_file" -v phase="$phase" '
    BEGIN { in_fm=0; fm_done=0; in_phase_section=0 }
    /^---$/ && !fm_done { in_fm = !in_fm; if (!in_fm) fm_done=1; print; next }
    in_fm && /^phase:/ { print "phase: " phase; next }
    /^## Phase$/ { print; in_phase_section=1; next }
    in_phase_section && /^[[:space:]]*$/ { next }
    in_phase_section && /^[A-Za-z]/ { print phase; in_phase_section=0; next }
    in_phase_section && !/^[A-Za-z]/ { print phase; print; in_phase_section=0; next }
    { print }
  '
}

cmd_append_verdict() {
  local plan_file="$1" label="$2"
  require_file "$plan_file"
  # Find ## Critic Verdicts and append after its last entry
  if grep -q "^## Critic Verdicts$" "$plan_file"; then
    _awk_inplace "$plan_file" -v label="- $label" '
      /^## Critic Verdicts$/ { print; in_section=1; next }
      in_section && /^## / { print label; print ""; print; in_section=0; next }
      { print }
      END { if (in_section) print label }
    '
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
    local pf="$1"
    # Prefer JSON state sidecar when present
    local sf p=""
    sf=$(_state_file "$pf")
    if [ -f "$sf" ]; then
      p=$(jq -r '.phase // empty' "$sf" 2>/dev/null || true)
    fi
    if [ -z "$p" ]; then
      p=$(awk '/^## Phase$/{found=1; next} found && /^[A-Za-z]/{print; exit}' "$pf" 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' || true)
    fi
    echo "$p"
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
  # Strip feature/ prefix only (not all path components) to preserve nested slugs.
  # e.g. feature/api/add-todo → api-add-todo, hotfix/fix-login → hotfix-fix-login
  local branch
  branch=$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" symbolic-ref --short HEAD 2>/dev/null \
           | sed 's|^feature/||; s|/|-|g; s|[^A-Za-z0-9_-]|-|g' || true)
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
  local input compact_trigger plan_file
  input=$(cat)
  compact_trigger=$(printf '%s' "$input" | jq -r '.trigger // "unknown"' 2>/dev/null || echo "unknown")
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0
  _append_event_to_plan "$plan_file" "PRE-COMPACT" "trigger=${compact_trigger} — SessionStart will re-inject plan summary; review open items after restart"
  echo "[flush-before-compact] recorded pre-compact marker (trigger=${compact_trigger}) in ${plan_file}" >&2
}

cmd_log_post_compact() {
  # PostCompact hook: sanity-checks that context was preserved after compaction.
  local plan_file
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0

  local current_phase
  current_phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "unknown")

  local open_q_count=0
  if grep -q "^## Open Questions$" "$plan_file"; then
    open_q_count=$(awk '/^## Open Questions$/{in_s=1;next} in_s && /^## /{exit} in_s && /\S/{count++} END{print count+0}' "$plan_file")
  fi

  _append_event_to_plan "$plan_file" "POST-COMPACT" "phase=${current_phase} open_questions=${open_q_count}"
  echo "[log-post-compact] phase=${current_phase} open_questions=${open_q_count} in ${plan_file}" >&2
}

cmd_record_stopfail() {
  # StopFailure hook: records a resumable marker when the session is interrupted.
  require_jq
  local input error_type plan_file
  input=$(cat)
  error_type=$(printf '%s' "$input" | jq -r '.error // "unknown"' 2>/dev/null || echo "unknown")
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0
  _append_event_to_plan "$plan_file" "STOPFAIL" "error_type=${error_type} — session interrupted; resume with /implementing or check plan phase"
  echo "[record-stopfail] recorded stop-failure marker (error_type=${error_type}) in ${plan_file}" >&2
}

cmd_record_task_created() {
  # TaskCreated hook: auto-registers a native TaskCreate call in the plan Task Ledger.
  # Payload fields: task_id, task_subject, task_description, teammate_name, team_name
  require_jq
  local input task_id task_subject plan_file
  input=$(cat)
  task_id=$(printf '%s' "$input" | jq -r '.task_id // "unknown"' 2>/dev/null || echo "unknown")
  task_subject=$(printf '%s' "$input" | jq -r '.task_subject // ""' 2>/dev/null || echo "")
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0
  cmd_add_task "$plan_file" "$task_id" "-"
  echo "[record-task-created] registered task (${task_id}: ${task_subject}) in ${plan_file}" >&2
}

cmd_record_task_completed() {
  # TaskCompleted hook: marks a native task as completed in the plan Task Ledger.
  require_jq
  local input task_id plan_file
  input=$(cat)
  task_id=$(printf '%s' "$input" | jq -r '.task_id // "unknown"' 2>/dev/null || echo "unknown")
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0
  cmd_update_task "$plan_file" "$task_id" "completed" || true
  echo "[record-task-completed] marked task (${task_id}) completed in ${plan_file}" >&2
}

cmd_record_permission_denied() {
  # PermissionDenied hook: records denied tool calls to Open Questions for next-session review.
  require_jq
  local input tool_name reason plan_file
  input=$(cat)
  tool_name=$(printf '%s' "$input" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")
  reason=$(printf '%s' "$input" | jq -r '.reason // "unknown"' 2>/dev/null || echo "unknown")
  [ "${#reason}" -gt 120 ] && reason="${reason:0:117}..."
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0
  _append_event_to_plan "$plan_file" "PERMISSION-DENIED" "tool=${tool_name} reason=${reason}"
  echo "[record-permission-denied] recorded denied tool (${tool_name}) in ${plan_file}" >&2
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
  # 1. agent_transcript_path: subagent-only transcript (canonical SubagentStop field)
  # 2. transcript_path: full session transcript (fallback); tail -200 to reduce cross-critic risk
  # 3. last_assistant_message: in-payload field (used in test fixtures, CI without file I/O)
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
  plan_file=$(cmd_find_active 2>/dev/null) || exit 1

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
    local blocked_marker="[BLOCKED] critic verdict missing — investigate ${agent_name}"
    if grep -q "^## Open Questions$" "$plan_file"; then
      _awk_inplace "$plan_file" -v marker="$blocked_marker" '
        /^## Open Questions$/ { print; in_section=1; next }
        in_section && /^## / { print marker; print ""; print; in_section=0; next }
        { print }
        END { if (in_section) print marker }
      '
    fi
    exit 1
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
  # Uses last verdict from this agent (any phase) — a PASS between two FAILs resets the streak.
  if [ "$verdict" = "FAIL" ] && [ -n "$category" ]; then
    local last_verdict_line
    last_verdict_line=$(grep "/${agent_name}: " "$plan_file" 2>/dev/null | tail -1 || true)
    if [ -n "$last_verdict_line" ] && printf '%s' "$last_verdict_line" | grep -q ": FAIL"; then
      local last_category
      last_category=$(printf '%s' "$last_verdict_line" | grep -o '\[category: [A-Z_]*\]' \
                      | sed 's/\[category: //; s/\]//' || true)
      if [ -n "$last_category" ] && [ "$last_category" = "$category" ]; then
        local blocked_marker="[BLOCKED-CATEGORY] ${agent_name}: category ${category} failed twice — fix the root cause before retrying"
        if grep -q "^## Open Questions$" "$plan_file"; then
          _awk_inplace "$plan_file" -v marker="$blocked_marker" '
            /^## Open Questions$/ { print; in_section=1; next }
            in_section && /^## / { print marker; print ""; print; in_section=0; next }
            { print }
            END { if (in_section) print marker }
          '
        fi
        cmd_append_verdict "$plan_file" "$verdict_label"
        echo "[record-verdict] consecutive same-category FAIL (${category}) from ${agent_name} — blocked" >&2
        exit 1
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
    _awk_inplace "$plan_file" -v row="$row" '
      /^## Task Ledger$/ { print; in_section=1; next }
      in_section && /^\| task-id/ { print; next }
      in_section && /^\|---/ { print; next }
      in_section && /^## / { print row; print ""; print; in_section=0; next }
      { print }
      END { if (in_section) print row }
    '
  else
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
  _awk_inplace "$plan_file" -v tid="$task_id" -v status="$status" -v sha="$commit_sha" '
    /^\| / {
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
  '
}

cmd_record_critic_start() {
  # SubagentStart hook: records critic start time + phase in ## Critic Runs for audit trail.
  require_jq
  local input agent_name plan_file current_phase ts
  input=$(cat)
  agent_name=$(printf '%s' "$input" | jq -r '.agent_type // "unknown"' 2>/dev/null || echo "unknown")

  # Only record for critic-* agents; ignore all others.
  case "$agent_name" in
    critic-*) ;;
    *) exit 0 ;;
  esac

  plan_file=$(cmd_find_active 2>/dev/null) || exit 0
  current_phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "unknown")
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
  _append_to_critic_runs "$plan_file" "[START @${ts}] phase=${current_phase} agent=${agent_name}"
  echo "[record-critic-start] recorded critic start (${agent_name}, phase=${current_phase}) in ${plan_file}" >&2
}

cmd_flush_on_end() {
  # SessionEnd hook: records a marker so the next session knows a clean exit occurred.
  require_jq
  local input reason plan_file
  input=$(cat)
  reason=$(printf '%s' "$input" | jq -r '.reason // "normal"' 2>/dev/null || echo "normal")
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0
  _append_event_to_plan "$plan_file" "SESSION-END" "reason=${reason} — plan state preserved; resume with context injection"
  echo "[flush-on-end] recorded session-end marker (reason=${reason}) in ${plan_file}" >&2
}

cmd_record_tool_failure() {
  # PostToolUseFailure hook: records Write|Edit failures so they are visible in the next session.
  require_jq
  local input tool_name error_msg plan_file
  input=$(cat)
  tool_name=$(printf '%s' "$input" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")
  error_msg=$(printf '%s' "$input" | jq -r '.error // "unknown"' 2>/dev/null || echo "unknown")
  [ "${#error_msg}" -gt 120 ] && error_msg="${error_msg:0:117}..."
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0
  _append_event_to_plan "$plan_file" "TOOL-FAIL" "tool=${tool_name} error=${error_msg}"
  echo "[record-tool-failure] recorded tool failure (${tool_name}) in ${plan_file}" >&2
}

cmd_gc_events() {
  # Compacts ## Open Questions: keeps [BLOCKED*] items, last [SESSION-END] and [POST-COMPACT];
  # discards transient audit markers (PRE-COMPACT, STOPFAIL, TOOL-FAIL, PERMISSION-DENIED).
  # Intended to run after SessionStart context injection to reduce plan file noise.
  local plan_file
  plan_file=$(cmd_find_active 2>/dev/null) || { echo "[gc-events] no active plan file" >&2; exit 0; }

  if ! grep -q "^## Open Questions$" "$plan_file"; then
    echo "[gc-events] no Open Questions section in ${plan_file}" >&2
    exit 0
  fi

  _awk_inplace "$plan_file" '
    /^## Open Questions$/ { in_section=1; print; next }
    in_section && /^## / {
      # Flush section contents before next section header
      for (i=1; i<=user_count; i++) print user_memos[i]
      for (i=1; i<=kept_count; i++) print kept[i]
      if (last_session_end != "") print last_session_end
      if (last_post_compact != "") print last_post_compact
      print ""
      print
      in_section=0
      next
    }
    in_section {
      if (/\[BLOCKED/) {
        kept[++kept_count] = $0
      } else if (/\[SESSION-END/) {
        last_session_end = $0
      } else if (/\[POST-COMPACT/) {
        last_post_compact = $0
      } else if (/\[(PRE-COMPACT|STOPFAIL|TOOL-FAIL|PERMISSION-DENIED)/) {
        # Discard machine-generated audit markers
      } else if (/^[[:space:]]*$/) {
        # Discard blank lines; spacing re-added on flush
      } else {
        # Preserve user-written memos that do not match any machine marker
        user_memos[++user_count] = $0
      }
      next
    }
    { print }
    END {
      if (in_section) {
        for (i=1; i<=user_count; i++) print user_memos[i]
        for (i=1; i<=kept_count; i++) print kept[i]
        if (last_session_end != "") print last_session_end
        if (last_post_compact != "") print last_post_compact
      }
    }
  '
  echo "[gc-events] compacted Open Questions in ${plan_file}" >&2
}

cmd_migrate_to_json() {
  # Creates a .state.json sidecar from an existing Markdown plan file.
  # Safe to re-run: no-ops if state file already exists.
  local plan_file="${1:-}"
  if [ -z "$plan_file" ]; then
    plan_file=$(cmd_find_active 2>/dev/null) || die "no active plan file found; pass plan file path as argument"
  fi
  require_file "$plan_file"
  require_jq
  local state_file
  state_file=$(_state_file "$plan_file")
  if [ -f "$state_file" ]; then
    echo "[migrate-to-json] state file already exists: ${state_file}" >&2
    exit 0
  fi
  local phase
  phase=$(awk '/^## Phase$/{found=1; next} found && /^[A-Za-z]/{print; exit}' "$plan_file" \
          | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' || echo "brainstorm")
  jq -nc --arg phase "$phase" '{"schema":2,"phase":$phase}' > "$state_file"
  echo "[migrate-to-json] created ${state_file} (phase=${phase})" >&2
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

  # Warn if plan file is large (> 500 lines) — signals need for cleanup or gc-events
  local line_count size_warning=""
  line_count=$(wc -l < "$plan_file" 2>/dev/null || echo 0)
  if [ "$line_count" -gt 500 ]; then
    size_warning=" | WARNING: plan file is ${line_count} lines (>500) — run gc-events or archive old sections"
  fi

  # Build body with per-section character budgets so Open Questions are never crowded out
  # by verbose verdict history. Path+phase is preserved in full (it is always short in
  # production; only test tmp paths are long). Verdicts capped at 300 chars. Open questions
  # get the remaining space up to the 800-char total cap.
  local path_phase verdicts_str questions_str
  path_phase="Active plan: ${plan_file} | Phase: ${phase}"
  verdicts_str="Recent verdicts: ${verdicts:-none}"
  if [ "${#verdicts_str}" -gt 300 ]; then verdicts_str="${verdicts_str:0:297}..."; fi
  questions_str="Open questions: ${questions}"
  if [ "${#questions_str}" -gt 400 ]; then questions_str="${questions_str:0:397}..."; fi

  local body_raw body
  body_raw="${path_phase} | ${verdicts_str} | ${questions_str}${size_warning}"
  if [ "${#body_raw}" -gt 800 ]; then
    body="${body_raw:0:797}..."
  else
    body="$body_raw"
  fi

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
  record-verdict)         cmd_record_verdict ;;
  record-critic-start)    cmd_record_critic_start ;;
  record-task-created)    cmd_record_task_created ;;
  record-task-completed)  cmd_record_task_completed ;;
  record-permission-denied) cmd_record_permission_denied ;;
  flush-before-compact) cmd_flush_before_compact ;;
  log-post-compact)     cmd_log_post_compact ;;
  flush-on-end)         cmd_flush_on_end ;;
  record-stopfail)      cmd_record_stopfail ;;
  record-tool-failure)  cmd_record_tool_failure ;;
  context)              cmd_context ;;
  gc-events)            cmd_gc_events ;;
  migrate-to-json)      cmd_migrate_to_json "${2:-}" ;;
  add-task)             [ $# -eq 4 ] || die "Usage: plan-file.sh add-task <plan-file> <task-id> <layer>"; cmd_add_task "$2" "$3" "$4" ;;
  update-task)          [ $# -ge 4 ] || die "Usage: plan-file.sh update-task <plan-file> <task-id> <status> [commit-sha]"; cmd_update_task "$2" "$3" "$4" "${5:--}" ;;
  *) die "Unknown command: $1" ;;
esac
