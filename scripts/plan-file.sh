#!/usr/bin/env bash
# Helper for reading/writing plan files under plans/
#
# Usage:
#   plan-file.sh get-phase <plan-file>
#       Prints the current phase value (brainstorm|spec|red|review|green|integration|done)
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
#       Exit 0 = found; exit 2 = none found; exit 3 = ambiguous (2+ active plans)
#
#   plan-file.sh record-verdict
#       Reads SubagentStop JSON from stdin; extracts agent name + last PASS/FAIL line;
#       appends verdict to the active plan file. Tracks PASS streak and run count;
#       emits [FIRST-TURN], [CONVERGED], and [BLOCKED-CEILING] markers to ## Open Questions.
#       Detects consecutive same-category FAILs and writes [BLOCKED-CATEGORY] when detected.
#       Exit 0 = success; exit 1 = error (includes no active plan, CEILING exceeded)
#
#   plan-file.sh append-review-verdict <plan-file> <agent> PASS|FAIL
#       Records a pr-review-toolkit verdict (called directly by the skill, not via SubagentStop).
#       Applies same streak/ceiling/FIRST-TURN/CONVERGED logic as record-verdict.
#       Exit 0 = success; exit 1 = ceiling exceeded or error
#
#   plan-file.sh record-critic-start
#       Called by SubagentStart hook for critic-.* agents; reads JSON from stdin;
#       appends a [START] entry to ## Critic Runs (created if absent) with phase + timestamp.
#       Exit 0 always (non-critic agents ignored; no active plan → silent skip).
#
#   plan-file.sh flush-before-compact
#       Called by PreCompact hook; reads JSON from stdin (trigger field);
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
#
#   plan-file.sh migrate-refactor [plan-file]
#       Rewrites a plan file stuck at the removed `refactor` phase to `green`.
#       Safe to run when not in refactor phase (no-op with message to stderr).
#       Exit 0 always.
#
#   plan-file.sh report-error <plan-file> <task-id> <file> <line> <description> <scope>
#       Appends a row to ## Pre-existing Errors (creates section + table if absent).
#       err-id is auto-assigned (err-N) inside the atomic lock to prevent duplicate IDs
#       when parallel coder worktrees call this simultaneously.
#       scope: nearby (same layer/module) or distant (different layer/feature).
#       Exit 0 = success; exit 1 = error
#
#   plan-file.sh list-errors <plan-file> [--status pending] [--scope nearby]
#       Parses ## Pre-existing Errors table; applies optional filters; prints
#       pipe-delimited rows: err-id|task-id|file|line|description|scope|status
#       Exit 0 always (no section or no matching rows → no output)
#
#   plan-file.sh update-error <plan-file> <err-id> <status>
#       Updates the status column for the matching err-id row.
#       Valid statuses: pending | fixed | deferred
#       Exit 0 = success; exit 1 = error
#
#   plan-file.sh record-integration-attempt <plan-file>
#       Increments the persistent integration re-run counter in .state.json.
#       Prints the new count on stdout. Survives /compact and session restarts.
#       Exit 0 = success; exit 1 = error
#
#   plan-file.sh get-integration-attempts <plan-file>
#       Prints the current integration re-run counter (0 if not yet set).
#       Exit 0 always
#
#   plan-file.sh record-stop-block <plan-file> <phase> <reason>
#       Writes a timestamped [STOP-BLOCKED] entry to ## Open Questions.
#       Called by stop-check.sh before each exit 2 so the block reason persists
#       across session restarts for post-mortem inspection.
#       Exit 0 = success; exit 1 = error
#
#   plan-file.sh record-auto-approved <plan-file> <kind> <agent-or-skill> [note]
#       Appends [AUTO-APPROVED-{KIND}] {agent}[: {note}] to ## Open Questions.
#       Canonical alternative to manual append — prevents typos and duplicate entries.
#       kind: PLAN | TASKLIST | FIRST | CATEGORIZED | DECIDED (case-insensitive)
#       Exit 0 = success; exit 1 = error

set -euo pipefail

VALID_PHASES="brainstorm spec red review green integration done"

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
    # Migrate legacy "schema" key to "state_schema" on first write after rename.
    jq --arg phase "$phase" '
      .phase = $phase |
      if has("schema") and (has("state_schema") | not)
        then .state_schema = .schema | del(.schema)
        else .
      end
    ' "$state_file" > "$tmp_file"
  else
    jq -nc --arg phase "$phase" '{"state_schema":2,"phase":$phase}' > "$tmp_file"
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
# Creates the section if absent. Entire check+create+append is one atomic _awk_inplace
# call to prevent duplicate section creation when parallel hooks fire concurrently.
_append_to_open_questions() {
  local plan_file="$1" note="$2"
  _awk_inplace "$plan_file" -v note="$note" '
    /^## Open Questions$/ { print; in_section=1; found=1; next }
    in_section && /^## / { print note; print ""; print; in_section=0; next }
    { print }
    END {
      if (in_section) { print note }
      else if (!found) { print ""; print "## Open Questions"; print note }
    }
  '
}

# Appends <entry> to the ## Critic Runs section of <plan_file>.
# Creates the section if absent. Uses _awk_inplace for both branches so the
# check-and-append is atomic (flock/mkdir) even when two critics start simultaneously.
_append_to_critic_runs() {
  local plan_file="$1" entry="$2"
  _awk_inplace "$plan_file" -v entry="- $entry" '
    /^## Critic Runs$/ { print; in_section=1; found=1; next }
    in_section && /^## / { print entry; print ""; print; in_section=0; next }
    { print }
    END {
      if (in_section) print entry
      else if (!found) { print ""; print "## Critic Runs"; print entry }
    }
  '
}

# Shared loop-state tracker for critic and pr-review convergence logic.
# Emits [FIRST-TURN], [CONVERGED], and [BLOCKED-CEILING] markers to ## Open Questions.
# Priority: CEILING > BLOCKED-CATEGORY (cmd_record_verdict) > BLOCKED-AMBIGUOUS (skill) > CONVERGED > FIRST-TURN.
# Must be called BEFORE the verdict is appended to ## Critic Verdicts.
#
# Usage: _record_loop_state <plan_file> <current_phase> <agent> <verdict>
# Returns: 0 = ok, 1 = ceiling exceeded (caller must still append verdict then exit 1)
_record_loop_state() {
  local plan_file="$1" current_phase="$2" agent="$3" verdict="$4"
  local ceiling="${CLAUDE_CRITIC_LOOP_CEILING:-5}"
  case "$ceiling" in
    ''|*[!0-9]*) echo "[record-loop-state] invalid CLAUDE_CRITIC_LOOP_CEILING '${ceiling}'; falling back to 5" >&2; ceiling=5 ;;
  esac

  # Count existing verdicts for this phase+agent in ## Critic Verdicts section
  local pat="${current_phase}/${agent}:"
  local prior_run_count
  prior_run_count=$(awk -v pat="$pat" \
    '/^## Critic Verdicts$/{s=1;next} s&&/^## /{s=0} s&&/^- /{if(index($0,pat))c++} END{print c+0}' \
    "$plan_file" 2>/dev/null || echo "0")
  local run_ordinal=$((prior_run_count + 1))

  # CEILING check (highest priority)
  if [ "$run_ordinal" -gt "$ceiling" ]; then
    _append_to_open_questions "$plan_file" \
      "[BLOCKED-CEILING] ${agent}: exceeded ${ceiling} runs for phase ${current_phase} — manual review required"
    echo "[record-loop-state] BLOCKED-CEILING: ${agent} run #${run_ordinal} exceeds ceiling ${ceiling}" >&2
    return 1
  fi

  # FIRST-TURN: emit once, on the very first run for this phase+agent.
  # Guard with grep to prevent duplicates if _record_loop_state is called multiple times
  # for the same run (e.g. hook retry, manual record-verdict re-invocation).
  if [ "$run_ordinal" -eq 1 ]; then
    if ! grep -qF "[FIRST-TURN] ${agent}" "$plan_file" 2>/dev/null; then
      _append_to_open_questions "$plan_file" "[FIRST-TURN] ${agent}"
      echo "[record-loop-state] FIRST-TURN: ${agent} first run (phase=${current_phase})" >&2
    fi
  fi

  # PASS streak: count consecutive PASSes at end of existing verdicts, then include this one
  if [ "$verdict" = "PASS" ]; then
    local agent_lines streak=0
    agent_lines=$(awk -v pat="$pat" \
      '/^## Critic Verdicts$/{s=1;next} s&&/^## /{s=0} s&&/^- /{if(index($0,pat))print}' \
      "$plan_file" 2>/dev/null || true)
    # Walk backward through existing verdicts, counting trailing PASSes
    while IFS= read -r line; do
      if printf '%s' "$line" | grep -q ": PASS"; then
        streak=$((streak + 1))
      else
        break
      fi
    done < <(printf '%s\n' "$agent_lines" \
      | awk 'NR>0{lines[NR]=$0} END{for(i=NR;i>=1;i--) print lines[i]}')
    # Include this (PASS) verdict in the streak
    streak=$((streak + 1))
    # Emit [CONVERGED] when streak reaches 2 or more, but only if not already present
    # (guards against duplicate entries after manual Open Questions edits).
    if [ "$streak" -ge 2 ]; then
      if ! grep -qF "[CONVERGED] ${agent}" "$plan_file" 2>/dev/null; then
        _append_to_open_questions "$plan_file" "[CONVERGED] ${agent}"
        echo "[record-loop-state] CONVERGED: ${agent} with ${streak} consecutive PASSes" >&2
      fi
    fi
  fi

  return 0
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
    exit 3
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
  error_type=$(printf '%s' "$input" | jq -r '.error_type // "unknown"' 2>/dev/null || echo "unknown")
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0
  _append_event_to_plan "$plan_file" "STOPFAIL" "error_type=${error_type} — session interrupted; resume with /implementing or check plan phase"
  echo "[record-stopfail] recorded stop-failure marker (error_type=${error_type}) in ${plan_file}" >&2
}

cmd_record_task_created() {
  # TaskCreated hook: observability log only — does NOT add to Task Ledger.
  # The implementing skill's explicit add-task calls are the canonical source for the Task Ledger
  # (they carry the correct layer). Adding here with layer="-" causes duplicate ledger rows.
  # Payload fields: task_id, task_subject, task_description, teammate_name, team_name
  require_jq
  local input task_id task_subject plan_file
  input=$(cat)
  task_id=$(printf '%s' "$input" | jq -r '.task_id // "unknown"' 2>/dev/null || echo "unknown")
  task_subject=$(printf '%s' "$input" | jq -r '.task_subject // ""' 2>/dev/null || echo "")
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0
  echo "[record-task-created] native task created (${task_id}: ${task_subject}) — Task Ledger managed by skill" >&2
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

  # Only record for phase-gate critics (critic-spec, critic-test, critic-code).
  # critic-feature is intentionally excluded: it uses a simpler max-2 iteration guard,
  # not the convergence protocol. See reference/critic-loop.md §Brainstorm exception.
  case "$agent_name" in
    critic-feature) exit 0 ;;
    critic-spec|critic-test|critic-code) ;;
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
  # Uses the LAST occurrence (fail-closed): if both markers appear (e.g. marker shown in example
  # then actual verdict), the last one wins. FAIL is checked before PASS so ambiguous cases
  # that contain both resolve to FAIL rather than silently advancing the phase.
  local verdict=""
  local last_verdict_marker
  last_verdict_marker=$(printf '%s' "$output" | grep -o '<!-- verdict: [A-Z]* -->' | tail -1 || true)
  if printf '%s' "$last_verdict_marker" | grep -q 'FAIL'; then
    verdict="FAIL"
  elif printf '%s' "$last_verdict_marker" | grep -q 'PASS'; then
    verdict="PASS"
  fi

  local current_phase
  current_phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "unknown")

  if [ -z "$verdict" ]; then
    local input_keys
    input_keys=$(printf '%s' "$input" | jq -r 'keys | join(", ")' 2>/dev/null || echo "unknown")
    echo "[record-verdict] missing verdict marker from ${agent_name} (payload keys: ${input_keys})" >&2
    # Track this run in the ceiling counter (prevents runaway loops on persistent PARSE_ERROR).
    _record_loop_state "$plan_file" "$current_phase" "$agent_name" "PARSE_ERROR" || true
    # Check for consecutive PARSE_ERROR: if the prior verdict for this agent was also PARSE_ERROR,
    # emit [BLOCKED-PARSE] so the skill stops rather than retrying indefinitely.
    local last_parse_line
    last_parse_line=$(awk -v pat="${current_phase}/${agent_name}:" \
      '/^## Critic Verdicts$/{s=1;next} s&&/^## /{s=0} s&&/^- /{if(index($0,pat))last=$0} END{print last}' \
      "$plan_file" 2>/dev/null || true)
    if printf '%s' "$last_parse_line" | grep -q ": PARSE_ERROR"; then
      _append_to_open_questions "$plan_file" \
        "[BLOCKED-PARSE] ${agent_name}: verdict marker missing twice consecutively — check agent output format before retrying"
      echo "[record-verdict] BLOCKED-PARSE: ${agent_name} two consecutive PARSE_ERRORs" >&2
    else
      echo "[record-verdict] first PARSE_ERROR for ${agent_name} — will retry automatically" >&2
    fi
    cmd_append_verdict "$plan_file" "${current_phase}/${agent_name}: PARSE_ERROR"
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

  # Loop-state tracking: FIRST-TURN / CONVERGED / BLOCKED-CEILING
  # Call before appending verdict so run-count reflects pre-append state.
  if ! _record_loop_state "$plan_file" "$current_phase" "$agent_name" "$verdict"; then
    # CEILING exceeded — append verdict for audit trail then exit
    cmd_append_verdict "$plan_file" "$verdict_label"
    echo "[record-verdict] BLOCKED-CEILING from _record_loop_state — verdict appended, exiting 1" >&2
    exit 1
  fi

  # Consecutive same-category FAIL detection
  # Scoped to agent only (phase-independent) — ensures red→review phase transitions do not
  # reset the category counter, so the same structural problem cannot slip past the ceiling
  # by crossing a phase boundary.
  if [ "$verdict" = "FAIL" ] && [ -n "$category" ]; then
    local last_verdict_line
    last_verdict_line=$(awk -v pat="${agent_name}:" \
      '/^## Critic Verdicts$/{s=1;next} s&&/^## /{s=0} s&&/^- /{if(index($0,pat))last=$0} END{print last}' \
      "$plan_file" 2>/dev/null || true)
    if [ -n "$last_verdict_line" ] && printf '%s' "$last_verdict_line" | grep -q ": FAIL"; then
      local last_category
      last_category=$(printf '%s' "$last_verdict_line" | grep -o '\[category: [A-Z_]*\]' \
                      | sed 's/\[category: //; s/\]//' || true)
      if [ -n "$last_category" ] && [ "$last_category" = "$category" ]; then
        _append_to_open_questions "$plan_file" \
          "[BLOCKED-CATEGORY] ${agent_name}: category ${category} failed twice — fix the root cause before retrying"
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
  reason=$(printf '%s' "$input" | jq -r '.reason // "unknown"' 2>/dev/null || echo "unknown")
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
      if (/\[BLOCKED/ || /\[STOP-BLOCKED/ || /\[DEFERRED-ERROR/ || /\[CONVERGED/ || /\[FIRST-TURN/ || /\[CONFIRMED-FIRST/ || /\[AUTO-APPROVED-FIRST/) {
        kept[++kept_count] = $0
      } else if (/\[SESSION-END/) {
        last_session_end = $0
      } else if (/\[POST-COMPACT/) {
        last_post_compact = $0
      } else if (/\[(PRE-COMPACT|STOPFAIL|TOOL-FAIL|PERMISSION-DENIED|AUTO-APPROVED-PLAN|AUTO-APPROVED-TASKLIST|AUTO-APPROVED-CATEGORIZED|AUTO-APPROVED-DECIDED)/) {
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
  jq -nc --arg phase "$phase" '{"state_schema":2,"phase":$phase}' > "$state_file"
  echo "[migrate-to-json] created ${state_file} (phase=${phase})" >&2
}

cmd_migrate_refactor() {
  # Rewrites a plan file stuck at the removed `refactor` phase to `green`.
  local plan_file="${1:-}"
  if [ -z "$plan_file" ]; then
    plan_file=$(cmd_find_latest 2>/dev/null) || die "no plan file found"
  fi
  require_file "$plan_file"
  local current_phase
  current_phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "")
  if [ "$current_phase" != "refactor" ]; then
    echo "[migrate-refactor] plan is not in refactor phase (current: ${current_phase:-unknown}); nothing to do" >&2
    exit 0
  fi
  _state_set_phase "$plan_file" "green"
  _awk_inplace "$plan_file" -v phase="green" '
    BEGIN { in_fm=0; fm_done=0; in_phase_section=0 }
    /^---$/ && !fm_done { in_fm = !in_fm; if (!in_fm) fm_done=1; print; next }
    in_fm && /^phase:/ { print "phase: " phase; next }
    /^## Phase$/ { print; in_phase_section=1; next }
    in_phase_section && /^[[:space:]]*$/ { next }
    in_phase_section && /^[A-Za-z]/ { print phase; in_phase_section=0; next }
    in_phase_section && !/^[A-Za-z]/ { print phase; print; in_phase_section=0; next }
    { print }
  '
  echo "[migrate-refactor] migrated ${plan_file}: refactor → green" >&2
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

cmd_report_error() {
  # report-error <plan-file> <task-id> <file> <line> <description> <scope>
  # Appends a row to ## Pre-existing Errors atomically (counting inside the lock
  # prevents duplicate err-N IDs when parallel coder worktrees call simultaneously).
  local plan_file="$1" task_id="$2" file="$3" line="$4" description="$5" scope="$6"
  require_file "$plan_file"
  case "$scope" in
    nearby|distant) ;;
    *) die "invalid scope: $scope (must be: nearby or distant)" ;;
  esac

  _awk_inplace "$plan_file" \
    -v task_id="$task_id" -v file="$file" -v line="$line" \
    -v description="$description" -v scope="$scope" '
    /^## Pre-existing Errors$/ { in_section=1; found=1; print; next }
    in_section && /^\| err-[0-9]/ { err_count++; print; next }
    in_section && /^## / {
      new_id = "err-" (err_count + 1)
      print "| " new_id " | " task_id " | " file " | " line " | " description " | " scope " | pending |"
      print ""
      print
      in_section = 0
      next
    }
    { print }
    END {
      if (in_section) {
        new_id = "err-" (err_count + 1)
        print "| " new_id " | " task_id " | " file " | " line " | " description " | " scope " | pending |"
      } else if (!found) {
        new_id = "err-1"
        print ""
        print "## Pre-existing Errors"
        print "| err-id | task-id | file | line | description | scope | status |"
        print "|--------|---------|------|------|-------------|-------|--------|"
        print "| " new_id " | " task_id " | " file " | " line " | " description " | " scope " | pending |"
      }
    }
  '
}

cmd_list_errors() {
  # list-errors <plan-file> [--status <status>] [--scope <scope>]
  local plan_file="$1"; shift
  require_file "$plan_file"
  local filter_status="" filter_scope=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) filter_status="$2"; shift 2 ;;
      --scope)  filter_scope="$2";  shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  awk -v filter_status="$filter_status" -v filter_scope="$filter_scope" '
    /^## Pre-existing Errors$/ { in_section=1; next }
    in_section && /^## / { exit }
    in_section && /^\| err-[0-9]/ {
      n = split($0, fields, "|")
      if (n < 8) next
      err_id     = fields[2]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", err_id)
      task_id    = fields[3]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", task_id)
      file       = fields[4]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", file)
      line       = fields[5]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      description = fields[6]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", description)
      scope      = fields[7]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", scope)
      status     = fields[8]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
      if (filter_status != "" && status != filter_status) next
      if (filter_scope  != "" && scope  != filter_scope)  next
      print err_id "|" task_id "|" file "|" line "|" description "|" scope "|" status
    }
  ' "$plan_file"
}

cmd_update_error() {
  # update-error <plan-file> <err-id> <status>
  local plan_file="$1" err_id="$2" status="$3"
  require_file "$plan_file"
  case "$status" in
    pending|fixed|deferred) ;;
    *) die "invalid status: $status (must be: pending, fixed, or deferred)" ;;
  esac

  _awk_inplace "$plan_file" -v eid="$err_id" -v new_status="$status" '
    /^\| err-[0-9]/ {
      n = split($0, fields, "|")
      if (n >= 8) {
        id = fields[2]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
        if (id == eid) {
          task_id     = fields[3]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", task_id)
          file        = fields[4]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", file)
          line        = fields[5]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
          description = fields[6]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", description)
          scope       = fields[7]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", scope)
          printf "| %s | %s | %s | %s | %s | %s | %s |\n", \
            eid, task_id, file, line, description, scope, new_status
          next
        }
      }
    }
    { print }
  '
}

cmd_append_review_verdict() {
  # append-review-verdict <plan-file> <agent> PASS|FAIL
  # Records a pr-review-toolkit verdict directly (SubagentStop hook does not fire for Skill calls).
  # Applies the same streak/ceiling/FIRST-TURN/CONVERGED logic as cmd_record_verdict.
  # NOTE: pr-review does not emit a machine-parseable <!-- category: X --> marker, so consecutive
  # same-category (BLOCKED-CATEGORY) escalation is intentionally NOT applied here. The skill must
  # resolve repeated FAILs via the fix-chain documented in implementing/SKILL.md §Step 5.
  local plan_file="$1" agent="$2" verdict="$3"
  require_file "$plan_file"
  case "$verdict" in
    PASS|FAIL) ;;
    *) die "append-review-verdict: verdict must be PASS or FAIL, got: ${verdict}" ;;
  esac

  local current_phase
  current_phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "unknown")

  local verdict_label="${current_phase}/${agent}: ${verdict}"

  # Loop-state tracking (must run before appending verdict)
  if ! _record_loop_state "$plan_file" "$current_phase" "$agent" "$verdict"; then
    cmd_append_verdict "$plan_file" "$verdict_label"
    echo "[append-review-verdict] BLOCKED-CEILING — verdict appended, exiting 1" >&2
    exit 1
  fi

  cmd_append_verdict "$plan_file" "$verdict_label"
  echo "[append-review-verdict] recorded ${verdict_label}" >&2
}

cmd_record_integration_attempt() {
  # record-integration-attempt <plan-file>
  # Increments the persistent integration re-run counter stored in .state.json.
  # Prints the new count on stdout. Counter survives /compact and session restarts.
  local plan_file="$1"
  require_file "$plan_file"
  require_jq
  local state_file tmp_file current_count new_count
  state_file=$(_state_file "$plan_file")
  tmp_file=$(mktemp "${state_file}.XXXXXX")
  if [ -f "$state_file" ]; then
    current_count=$(jq -r '.integration_attempts // 0' "$state_file" 2>/dev/null || echo "0")
    new_count=$((current_count + 1))
    jq --argjson n "$new_count" '
      .integration_attempts = $n |
      if has("schema") and (has("state_schema") | not)
        then .state_schema = .schema | del(.schema)
        else .
      end
    ' "$state_file" > "$tmp_file"
  else
    new_count=1
    jq -nc --argjson n "$new_count" '{"state_schema":2,"integration_attempts":$n}' > "$tmp_file"
  fi
  mv "$tmp_file" "$state_file"
  echo "$new_count"
  echo "[record-integration-attempt] counter now ${new_count} in ${state_file}" >&2
}

cmd_get_integration_attempts() {
  # get-integration-attempts <plan-file>
  # Prints the current integration re-run counter (0 if not yet set).
  local plan_file="$1"
  require_file "$plan_file"
  require_jq
  local state_file
  state_file=$(_state_file "$plan_file")
  if [ -f "$state_file" ]; then
    jq -r '.integration_attempts // 0' "$state_file" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

cmd_record_stop_block() {
  # record-stop-block <plan-file> <phase> <reason>
  # Writes a timestamped [STOP-BLOCKED] entry to ## Open Questions so the next
  # session can see exactly why the Stop hook blocked the previous stop attempt.
  local plan_file="$1" phase="$2" reason="$3"
  require_file "$plan_file"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
  _append_to_open_questions "$plan_file" \
    "[STOP-BLOCKED @${ts}] phase=${phase} — ${reason}"
  echo "[record-stop-block] recorded stop block (phase=${phase}): ${reason}" >&2
}

cmd_record_auto_approved() {
  # record-auto-approved <plan-file> <kind> <agent-or-skill> [note]
  # Appends [AUTO-APPROVED-{KIND}] {agent}[: {note}] to ## Open Questions.
  # Kind examples: PLAN, TASKLIST, FIRST, CATEGORIZED, DECIDED (case-insensitive).
  local plan_file="$1" kind="$2" agent="$3" note="${4:-}"
  require_file "$plan_file"
  kind=$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')
  case "$kind" in
    PLAN|TASKLIST|FIRST|CATEGORIZED|DECIDED) ;;
    *) die "record-auto-approved: invalid kind '${kind}'. Valid values: PLAN TASKLIST FIRST CATEGORIZED DECIDED" ;;
  esac
  local marker="[AUTO-APPROVED-${kind}] ${agent}"
  if [ -n "$note" ]; then
    marker="${marker}: ${note}"
  fi
  _append_to_open_questions "$plan_file" "$marker"
  echo "[record-auto-approved] ${marker}" >&2
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
  migrate-refactor)     cmd_migrate_refactor "${2:-}" ;;
  add-task)             [ $# -eq 4 ] || die "Usage: plan-file.sh add-task <plan-file> <task-id> <layer>"; cmd_add_task "$2" "$3" "$4" ;;
  update-task)          [ $# -ge 4 ] || die "Usage: plan-file.sh update-task <plan-file> <task-id> <status> [commit-sha]"; cmd_update_task "$2" "$3" "$4" "${5:--}" ;;
  report-error)         [ $# -eq 7 ] || die "Usage: plan-file.sh report-error <plan-file> <task-id> <file> <line> <description> <scope>"; cmd_report_error "$2" "$3" "$4" "$5" "$6" "$7" ;;
  list-errors)          [ $# -ge 2 ] || die "Usage: plan-file.sh list-errors <plan-file> [--status <status>] [--scope <scope>]"; cmd_list_errors "$2" "${@:3}" ;;
  update-error)         [ $# -eq 4 ] || die "Usage: plan-file.sh update-error <plan-file> <err-id> <status>"; cmd_update_error "$2" "$3" "$4" ;;
  append-review-verdict) [ $# -eq 4 ] || die "Usage: plan-file.sh append-review-verdict <plan-file> <agent> PASS|FAIL"; cmd_append_review_verdict "$2" "$3" "$4" ;;
  record-integration-attempt) [ $# -eq 2 ] || die "Usage: plan-file.sh record-integration-attempt <plan-file>"; cmd_record_integration_attempt "$2" ;;
  get-integration-attempts)   [ $# -eq 2 ] || die "Usage: plan-file.sh get-integration-attempts <plan-file>"; cmd_get_integration_attempts "$2" ;;
  record-stop-block)          [ $# -eq 4 ] || die "Usage: plan-file.sh record-stop-block <plan-file> <phase> <reason>"; cmd_record_stop_block "$2" "$3" "$4" ;;
  record-auto-approved)       [ $# -ge 4 ] || die "Usage: plan-file.sh record-auto-approved <plan-file> <kind> <agent> [note]"; cmd_record_auto_approved "$2" "$3" "$4" "${5:-}" ;;
  *) die "Unknown command: $1" ;;
esac
