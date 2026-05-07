#!/usr/bin/env bash
# Plan-file library — all commands (formerly plan-core/phase/verdicts/ledger.sh).
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PLAN_LIB_LOADED:-}" ]] && return 0
_PLAN_LIB_LOADED=1

_PLAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_ACTIVE_PLAN_LOADED:-}" ]] || . "$_PLAN_LIB_DIR/active-plan.sh"
[[ -n "${_PHASE_POLICY_LOADED:-}" ]] || . "${_PLAN_LIB_DIR}/../phase-policy.sh"
VALID_PHASES="$(list_phases)"

VALID_CRITIC_AGENTS="critic-feature critic-spec critic-test critic-code critic-cross pr-review"

# ── Core helpers ──────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

# Validates <agent> against VALID_CRITIC_AGENTS.
_validate_critic_agent() {
  local agent="$1" cmd="$2"
  case " $VALID_CRITIC_AGENTS " in
    *" $agent "*) ;;
    *) die "${cmd}: unknown agent '${agent}'. Valid values: ${VALID_CRITIC_AGENTS}" ;;
  esac
}

# Agents whose verdicts are recorded via cmd_record_verdict (pr-review uses append-review-verdict).
_is_subagent_critic() {
  case "${1:-}" in
    critic-spec|critic-test|critic-code|critic-feature|critic-cross) return 0 ;;
    *) return 1 ;;
  esac
}

# _with_lock <lock_base_path> <body_fn>
# Acquires an advisory lock on <lock_base_path> and invokes <body_fn> while held.
# Uses flock(1) when available (Linux), otherwise falls back to mkdir-based advisory lock.
_with_lock() {
  local lock_base="$1" body_fn="$2"
  if command -v flock >/dev/null 2>&1; then
    (
      flock -w 5 200 || return 1
      "$body_fn" || return 1
    ) 200>"${lock_base}.lock"
  else
    local lock_dir="${lock_base}.lockdir"
    local retries=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
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
      [ "$retries" -ge 50 ] && { echo "ERROR: lock timeout for ${lock_base}" >&2; return 1; }
      sleep 0.1
    done
    echo $$ > "${lock_dir}/pid" 2>/dev/null || true
    if "$body_fn"; then
      rm -f "${lock_dir}/pid" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
    else
      rm -f "${lock_dir}/pid" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
      return 1
    fi
  fi
}

# Shared globals for _with_lock body functions
_AWK_INPLACE_FILE=""
_AWK_INPLACE_TMP=""
_AWK_INPLACE_ARGS=()

_awk_inplace_body() {
  if awk "${_AWK_INPLACE_ARGS[@]}" "$_AWK_INPLACE_FILE" > "$_AWK_INPLACE_TMP"; then
    mv "$_AWK_INPLACE_TMP" "$_AWK_INPLACE_FILE"
  else
    rm -f "$_AWK_INPLACE_TMP"
    return 1
  fi
}

# Atomic awk-in-place with advisory lock.
_awk_inplace() {
  local plan_file="$1"; shift
  _AWK_INPLACE_FILE="$plan_file"
  _AWK_INPLACE_TMP=$(mktemp "${plan_file}.XXXXXX")
  _AWK_INPLACE_ARGS=("$@")
  if ! _with_lock "$plan_file" "_awk_inplace_body"; then
    rm -f "$_AWK_INPLACE_TMP"
    return 1
  fi
}

# ── Schema validation ─────────────────────────────────────────────────────────

_check_schema() {
  local plan_file="$1"
  local schema_ver
  schema_ver=$(awk '/^---$/{in_fm=!in_fm; next} in_fm && /^schema:/{print $2; exit}' "$plan_file" 2>/dev/null \
              | tr -d '[:space:]' || echo "")
  [ "${schema_ver}" = "2" ] || die "unsupported plan file schema version: '${schema_ver:-missing}' (required: 2)"
}

require_jq() {
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not found" >&2; exit 2; }
}

require_file() {
  [ -f "$1" ] || { echo "ERROR: plan file not found: $1" >&2; exit 2; }
}

# ── Section-append helpers ────────────────────────────────────────────────────

_append_to_section() {
  local plan_file="$1" section="$2" entry="$3"
  [ "${4:-}" = "--bullet" ] && entry="- $entry"
  _awk_inplace "$plan_file" -v section="$section" -v entry="$entry" '
    $0 == "## " section { print; in_section=1; found=1; next }
    in_section && /^## / { print entry; print ""; print; in_section=0; next }
    { print }
    END {
      if (in_section) print entry
      else if (!found) { print ""; print "## " section; print entry }
    }
  '
}

_append_to_open_questions()    { _append_to_section "$1" "Open Questions"   "$2"; }
_append_to_phase_transitions() { _append_to_section "$1" "Phase Transitions" "$2"; }
_append_to_critic_verdicts()   { _append_to_section "$1" "Critic Verdicts"  "$2" --bullet; }
_append_to_verdict_audits()    { _append_to_section "$1" "Verdict Audits"   "$2"; }

# ── Phase lifecycle commands ──────────────────────────────────────────────────

_awk_replace_phase_body() {
  local plan_file="$1" phase="$2"
  _awk_inplace "$plan_file" -v phase="$phase" '
    BEGIN { in_fm=0; fm_done=0; in_phase_section=0 }
    /^---$/ && !fm_done { in_fm = !in_fm; if (!in_fm) fm_done=1; print; next }
    in_fm && /^phase:/ { print "phase: " phase; next }
    /^## Phase$/ { print; print ""; in_phase_section=1; next }
    in_phase_section && /^[[:space:]]*$/ { next }
    in_phase_section && /^[A-Za-z]/ { print phase; in_phase_section=0; next }
    in_phase_section && !/^[A-Za-z]/ { print phase; print; in_phase_section=0; next }
    { print }
    END { if (in_phase_section) { print phase } }
  '
}

cmd_init() {
  local plan_file="$1"
  local mode="${2:-}"
  local slug
  slug=$(basename "$plan_file" .md)
  if [ -f "$plan_file" ]; then
    if [ -n "$mode" ]; then
      local existing
      existing=$(awk '/^mode:/{print $2; exit}' "$plan_file" 2>/dev/null || true)
      if [ -n "$existing" ] && [ "$existing" != "$mode" ]; then
        echo "[plan-file] init: existing plan has mode='${existing}', requested='${mode}' — keeping existing" >&2
      fi
    fi
    echo "[plan-file] init: $plan_file already exists — skipping" >&2
    return 0
  fi
  mkdir -p "$(dirname "$plan_file")"
  {
    printf -- '---\nfeature: %s\nphase: brainstorm\nschema: 2\n' "$slug"
    [ -n "$mode" ] && printf 'mode: %s\n' "$mode"
    printf -- '---\n\n## Vision\n\n## Scenarios\n\n## Test Manifest\n\n## Phase\nbrainstorm\n\n## Phase Transitions\n- brainstorm → (initial)\n\n## Critic Verdicts\n\n## Task Ledger\n\n## Integration Failures\n\n## Verdict Audits\n\n## Open Questions\n'
  } > "$plan_file"
}

cmd_get_phase() {
  local plan_file="$1"
  require_file "$plan_file"
  local phase
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
  local valid=0
  for p in $VALID_PHASES; do
    [ "$p" = "$phase" ] && valid=1 && break
  done
  [ "$valid" -eq 1 ] || die "invalid phase: $phase (must be one of: $VALID_PHASES)"
  _awk_replace_phase_body "$plan_file" "$phase"
}

cmd_find_active() {
  local plans_dir="${CLAUDE_PROJECT_DIR:-$PWD}/plans"

  _read_phase() {
    local pf="$1"
    local p=""
    p=$(awk '/^## Phase$/{found=1; next} found && /^[A-Za-z]/{print; exit}' "$pf" 2>/dev/null \
      | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' || true)
    echo "$p"
  }

  if [ -n "${CLAUDE_PLAN_FILE:-}" ]; then
    if [ -f "$CLAUDE_PLAN_FILE" ]; then
      local envphase
      envphase=$(_read_phase "$CLAUDE_PLAN_FILE")
      if [ -n "$envphase" ] && [ "$envphase" != "done" ]; then
        echo "$CLAUDE_PLAN_FILE"
        return 0
      fi
      if [ "$envphase" = "done" ]; then
        echo "[plan-file] CLAUDE_PLAN_FILE=$CLAUDE_PLAN_FILE is done; falling through to other strategies. Unset or pick a new plan if unintentional." >&2
      fi
    fi
  fi

  [ -d "$plans_dir" ] || { exit 2; }

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

  local found="" count=0 malformed=0
  while IFS= read -r f; do
    local phase
    phase=$(_read_phase "$f")
    if [ -z "$phase" ]; then
      echo "[plan-file] ERROR: plan file exists but phase cannot be read: $f (missing ## Phase section)" >&2
      malformed=$((malformed + 1))
    elif [ "$phase" != "done" ]; then
      count=$((count + 1))
      [ -z "$found" ] && found="$f"
    fi
  done < <(ls -t "$plans_dir"/*.md 2>/dev/null)
  if [ "$malformed" -gt 0 ] && [ "$count" -eq 0 ]; then
    echo "ERROR: ${malformed} plan file(s) exist but phase is unreadable — repair the ## Phase section before stopping." >&2
    exit 4
  elif [ "$count" -eq 0 ]; then
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

cmd_append_phase_transition() {
  local plan_file="$1" entry="$2"
  require_file "$plan_file"
  _append_to_phase_transitions "$plan_file" "$entry"
}

cmd_transition() {
  local plan_file="$1" to_phase="$2" reason="$3"
  require_file "$plan_file"
  local from_phase
  from_phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "unknown")
  cmd_set_phase "$plan_file" "$to_phase"
  cmd_append_phase_transition "$plan_file" "- ${from_phase} → ${to_phase} (reason: ${reason})"
}

cmd_commit_phase() {
  local plan_file="$1" message="$2"
  git add "$plan_file"
  git diff --cached --quiet || git commit -m "$message"
}

# ── Verdict IO, loop-state, reset, context ────────────────────────────────────

PHASE_CONVERGENCE_MARKERS=(
  "BLOCKED-CEILING"
  "CONVERGED"
  "FIRST-TURN"
)

_record_loop_state() {
  local plan_file="$1" current_phase="$2" agent="$3" verdict="$4"
  local ceiling="${CLAUDE_CRITIC_LOOP_CEILING:-5}"
  case "$ceiling" in
    ''|*[!0-9]*) echo "[record-loop-state] invalid CLAUDE_CRITIC_LOOP_CEILING '${ceiling}'; falling back to 5" >&2; ceiling=5 ;;
  esac
  if [ "$ceiling" -lt 2 ]; then
    echo "[record-loop-state] CLAUDE_CRITIC_LOOP_CEILING=${ceiling} is less than 2; falling back to 5" >&2; ceiling=5
  fi

  local pat="${current_phase}/${agent}:"
  local prior_run_count
  prior_run_count=$(awk -v pat="$pat" \
    '/^## Critic Verdicts$/{s=1;next} s&&/^## /{s=0} s&&/^- /{if(index($0,pat)){if(index($0,"[MILESTONE-BOUNDARY @"))c=0;else if(!index($0,"REJECT-PASS"))c++}} END{print c+0}' \
    "$plan_file" 2>/dev/null || echo "0")
  local run_ordinal=$((prior_run_count + 1))

  if [ "$run_ordinal" -gt "$ceiling" ]; then
    if ! grep -qF "[BLOCKED-CEILING] ${current_phase}/${agent}" "$plan_file" 2>/dev/null; then
      _append_to_open_questions "$plan_file" \
        "[BLOCKED-CEILING] ${current_phase}/${agent}: exceeded ${ceiling} runs — manual review required"
    fi
    echo "[record-loop-state] BLOCKED-CEILING: ${current_phase}/${agent} run #${run_ordinal} exceeds ceiling ${ceiling}" >&2
    return 1
  fi

  if [ "$verdict" != "PARSE_ERROR" ]; then
    if ! grep -qF "[FIRST-TURN] ${current_phase}/${agent}" "$plan_file" 2>/dev/null; then
      _append_to_open_questions "$plan_file" "[FIRST-TURN] ${current_phase}/${agent}"
      echo "[record-loop-state] FIRST-TURN: ${current_phase}/${agent} first real verdict" >&2
    fi
  fi

  if [ "$verdict" = "PASS" ]; then
    local agent_lines streak=0
    agent_lines=$(awk -v pat="$pat" \
      '/^## Critic Verdicts$/{s=1;next} s&&/^## /{s=0} s&&/^- /{if(index($0,pat))print}' \
      "$plan_file" 2>/dev/null || true)
    while IFS= read -r line; do
      if printf '%s' "$line" | grep -q ": PASS"; then
        streak=$((streak + 1))
      else
        break
      fi
    done < <(printf '%s\n' "$agent_lines" \
      | awk 'NR>0{lines[NR]=$0} END{for(i=NR;i>=1;i--) print lines[i]}')
    streak=$((streak + 1))
    if [ "$streak" -ge 2 ]; then
      if ! grep -qF "[CONVERGED] ${current_phase}/${agent}" "$plan_file" 2>/dev/null; then
        _append_to_open_questions "$plan_file" "[CONVERGED] ${current_phase}/${agent}"
        echo "[record-loop-state] CONVERGED: ${current_phase}/${agent} with ${streak} consecutive PASSes" >&2
      fi
    fi
  fi

  return 0
}

_clear_convergence_markers() {
  local plan_file="$1" scope="$2"
  local marker
  for marker in "${PHASE_CONVERGENCE_MARKERS[@]}"; do
    cmd_clear_marker "$plan_file" "[${marker}] ${scope}"
  done
}

cmd_append_verdict() {
  local plan_file="$1" label="$2"
  require_file "$plan_file"
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

cmd_append_audit() {
  local plan_file="$1" agent="$2" outcome="$3" summary="$4"
  require_file "$plan_file"
  case "$outcome" in
    ACCEPT|ACCEPT-OVERRIDE|REJECT-PASS|BLOCKED-AMBIGUOUS) ;;
    *) die "append-audit: invalid outcome '${outcome}'. Must be ACCEPT, ACCEPT-OVERRIDE, REJECT-PASS, or BLOCKED-AMBIGUOUS" ;;
  esac
  local ts
  ts=$(_iso_timestamp)
  _append_to_verdict_audits "$plan_file" "- ${ts} ${agent} ${outcome}: ${summary}"
}

cmd_record_verdict() {
  require_jq
  local input
  input=$(cat)
  local agent_name
  agent_name=$(printf '%s' "$input" | jq -r '.agent_type // "unknown"' 2>/dev/null || echo "unknown")

  if ! _is_subagent_critic "$agent_name"; then
    exit 0
  fi

  local agent_transcript transcript
  agent_transcript=$(printf '%s' "$input" | jq -r '.agent_transcript_path // empty' 2>/dev/null || true)
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)

  local plan_file
  local _find_rc=0
  plan_file=$(cmd_find_active) || _find_rc=$?
  if [ "$_find_rc" -ne 0 ]; then
    case "$_find_rc" in
      2) echo "[record-verdict] no active plan file — verdict for ${agent_name} dropped" >&2 ;;
      3) echo "[record-verdict] ambiguous: multiple active plan files — pin CLAUDE_PLAN_FILE to record verdict for ${agent_name}" >&2 ;;
      4) echo "[record-verdict] unreadable plan phase — verdict for ${agent_name} dropped (fix the ## Phase section to recover)" >&2 ;;
      *) echo "[record-verdict] cmd_find_active failed (exit ${_find_rc}) — verdict for ${agent_name} dropped" >&2 ;;
    esac
    exit 0
  fi

  local output=""
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

  # Forked-execution guard: skills may spawn multiple sub-agents. Skip non-authoritative ones:
  #   (a) Textual "Verdict:" present but no HTML markers — summary/forked copy.
  #   (b) No "### Verdict" or "<!-- verdict:" section at all — setup/exploratory sub-agent.
  # Only the primary transcript (HTML markers present) should record a verdict.
  if [ -z "$verdict" ]; then
    if printf '%s' "$output" | grep -qE 'Verdict:\s*(PASS|FAIL)|\*\*Verdict:\s*(PASS|FAIL)\*\*'; then
      echo "[record-verdict] textual-verdict-only transcript for ${agent_name} (forked-execution summary) — skipping" >&2
      exit 0
    fi
    if ! printf '%s' "$output" | grep -qE '### Verdict|<!-- verdict:'; then
      echo "[record-verdict] no verdict section in transcript for ${agent_name} (setup/exploratory sub-agent) — skipping" >&2
      exit 0
    fi
  fi

  if [ -z "$verdict" ]; then
    local input_keys
    input_keys=$(printf '%s' "$input" | jq -r 'keys | join(", ")' 2>/dev/null || echo "unknown")
    echo "[record-verdict] missing verdict marker from ${agent_name} (payload keys: ${input_keys})" >&2
    if ! _record_loop_state "$plan_file" "$current_phase" "$agent_name" "PARSE_ERROR"; then
      cmd_append_verdict "$plan_file" "${current_phase}/${agent_name}: PARSE_ERROR"
      exit 1
    fi
    local last_parse_line
    last_parse_line=$(awk -v pat="/${agent_name}:" \
      '/^## Critic Verdicts$/{s=1;next} s&&/^## /{s=0} s&&/^- /{if(index($0,pat)){if(index($0,"[MILESTONE-BOUNDARY @"))last="";else last=$0}} END{print last}' \
      "$plan_file" 2>/dev/null || true)
    if printf '%s' "$last_parse_line" | grep -q ": PARSE_ERROR"; then
      _append_to_open_questions "$plan_file" \
        "[BLOCKED] parse:${agent_name}: verdict marker missing (two consecutive parse errors) — check agent output format before retrying"
      echo "[record-verdict] BLOCKED parse: ${agent_name} two consecutive PARSE_ERRORs" >&2
    else
      echo "[record-verdict] first PARSE_ERROR for ${agent_name} — will retry automatically" >&2
    fi
    cmd_append_verdict "$plan_file" "${current_phase}/${agent_name}: PARSE_ERROR"
    exit 1
  fi

  local category=""
  category=$(printf '%s' "$output" | grep -o '<!-- category: [A-Z_]* -->' | tail -1 \
             | sed 's/<!-- category: //; s/ -->//' || true)

  # FAIL verdict must be accompanied by a category marker
  if [ "$verdict" = "FAIL" ] && [ -z "$category" ]; then
    echo "[record-verdict] FAIL verdict without category marker from ${agent_name} — treating as PARSE_ERROR" >&2
    if ! _record_loop_state "$plan_file" "$current_phase" "$agent_name" "PARSE_ERROR"; then
      cmd_append_verdict "$plan_file" "${current_phase}/${agent_name}: PARSE_ERROR"
      exit 1
    fi
    local last_parse_line
    last_parse_line=$(awk -v pat="/${agent_name}:" \
      '/^## Critic Verdicts$/{s=1;next} s&&/^## /{s=0} s&&/^- /{if(index($0,pat)){if(index($0,"[MILESTONE-BOUNDARY @"))last="";else last=$0}} END{print last}' \
      "$plan_file" 2>/dev/null || true)
    if printf '%s' "$last_parse_line" | grep -q ": PARSE_ERROR"; then
      _append_to_open_questions "$plan_file" \
        "[BLOCKED] parse:${agent_name}: FAIL without category (two consecutive parse errors) — check agent output format before retrying"
      echo "[record-verdict] BLOCKED parse: ${agent_name} two consecutive PARSE_ERRORs (FAIL without category)" >&2
    else
      echo "[record-verdict] first FAIL-without-category for ${agent_name} — will retry automatically" >&2
    fi
    cmd_append_verdict "$plan_file" "${current_phase}/${agent_name}: PARSE_ERROR"
    exit 1
  fi

  local verdict_label="${current_phase}/${agent_name}: ${verdict}"
  if [ -n "$category" ]; then
    verdict_label="${verdict_label} [category: ${category}]"
  fi

  if ! _record_loop_state "$plan_file" "$current_phase" "$agent_name" "$verdict"; then
    cmd_append_verdict "$plan_file" "$verdict_label"
    echo "[record-verdict] BLOCKED-CEILING from _record_loop_state — verdict appended, exiting 1" >&2
    exit 1
  fi

  if [ "$verdict" = "FAIL" ] && [ -n "$category" ]; then
    local last_verdict_line
    last_verdict_line=$(awk -v pat="/${agent_name}:" \
      '/^## Critic Verdicts$/{s=1;next} s&&/^## /{s=0} s&&/^- /{if(index($0,pat)){if(index($0,"[MILESTONE-BOUNDARY @"))last="";else if(!index($0,": PARSE_ERROR"))last=$0}} END{print last}' \
      "$plan_file" 2>/dev/null || true)
    if [ -n "$last_verdict_line" ] && printf '%s' "$last_verdict_line" | grep -q ": FAIL"; then
      local last_category
      last_category=$(printf '%s' "$last_verdict_line" | grep -o '\[category: [A-Z_]*\]' \
                      | sed 's/\[category: //; s/\]//' || true)
      if [ -n "$last_category" ] && [ "$last_category" = "$category" ]; then
        _append_to_open_questions "$plan_file" \
          "[BLOCKED] category:${agent_name}: ${category} failed twice — fix the root cause before retrying"
        cmd_append_verdict "$plan_file" "$verdict_label"
        echo "[record-verdict] consecutive same-category FAIL (${category}) from ${agent_name} — blocked" >&2
        exit 1
      fi
    fi
  fi

  cmd_append_verdict "$plan_file" "$verdict_label"
}

cmd_record_verdict_guarded() {
  local _input _agent _plan _find_rc _lock
  _input=$(cat)
  _agent="unknown"
  if command -v jq >/dev/null 2>&1; then
    _agent=$(printf '%s' "$_input" | jq -r 'if (.agent_type // "") == "" then "unknown" else .agent_type end' 2>/dev/null || echo "unknown")
  fi
  # Non-critic agents are not subject to the protocol-violation guard
  if ! _is_subagent_critic "$_agent"; then
    exit 0
  fi
  _find_rc=0
  _plan=$(cmd_find_active) || _find_rc=$?
  _lock=""
  [ "$_find_rc" -eq 0 ] && _lock="${_plan}.critic.lock"
  if [ -z "$_lock" ] || [ ! -f "$_lock" ]; then
    if [ "$_find_rc" -eq 0 ]; then
      cmd_append_note "$_plan" \
        "[BLOCKED] protocol-violation:${_agent}: invoked outside run-critic-loop.sh context"
    fi
    echo "[record-verdict-guarded] BLOCKED: ${_agent} ran outside run-critic-loop.sh" >&2
    exit 2
  fi
  printf '%s' "$_input" | cmd_record_verdict
}

cmd_append_review_verdict() {
  local plan_file="$1" agent="$2" verdict="$3"
  require_file "$plan_file"
  [ "$agent" = "pr-review" ] || die "append-review-verdict: agent must be 'pr-review', got: ${agent}"
  case "$verdict" in
    PASS|FAIL) ;;
    *) die "append-review-verdict: verdict must be PASS or FAIL, got: ${verdict}" ;;
  esac
  local current_phase
  current_phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "unknown")
  local verdict_label="${current_phase}/${agent}: ${verdict}"
  if ! _record_loop_state "$plan_file" "$current_phase" "$agent" "$verdict"; then
    cmd_append_verdict "$plan_file" "$verdict_label"
    echo "[append-review-verdict] BLOCKED-CEILING — verdict appended, exiting 1" >&2
    exit 1
  fi
  cmd_append_verdict "$plan_file" "$verdict_label"
  echo "[append-review-verdict] recorded ${verdict_label}" >&2
}

cmd_clear_marker() {
  local plan_file="$1" marker="$2"
  require_file "$plan_file"
  _awk_inplace "$plan_file" -v marker="$marker" '
    /^## Open Questions$/ { in_section=1; print; next }
    in_section && /^## / { in_section=0 }
    in_section && index($0, marker) > 0 { next }
    { print }
  '
  echo "[clear-marker] removed '$marker' from ## Open Questions in $plan_file" >&2
}

cmd_unblock() {
  local agent="$1"
  local plan_file
  plan_file=$(cmd_find_active) || die "unblock: no active plan found"
  _awk_inplace "$plan_file" -v agent="$agent" '
    /^## Open Questions$/ { in_section=1; print; next }
    in_section && /^## / { in_section=0 }
    in_section && /\[BLOCKED/ && index($0, agent) > 0 { next }
    { print }
  '
  echo "[unblock] cleared [BLOCKED*] markers for '${agent}' in ${plan_file}" >&2
}

cmd_clear_converged() {
  local plan_file="$1" agent="$2"
  require_file "$plan_file"
  _validate_critic_agent "$agent" "clear-converged"
  local current_phase
  current_phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "unknown")
  [ "$current_phase" = "unknown" ] && die "clear-converged: could not determine current phase from ${plan_file}"
  local scope="${current_phase}/${agent}"
  cmd_clear_marker "$plan_file" "[CONVERGED] ${scope}"
  local ts
  ts=$(_iso_timestamp)
  _append_to_critic_verdicts "$plan_file" \
    "${ts} ${scope}: REJECT-PASS (audit-override — streak reset)"
  echo "[clear-converged] cleared [CONVERGED] and reset streak for ${scope}" >&2
}

cmd_reset_milestone() {
  local plan_file="$1" agent="$2"
  require_file "$plan_file"
  _validate_critic_agent "$agent" "reset-milestone"
  local current_phase
  current_phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "unknown")
  [ "$current_phase" = "unknown" ] && die "reset-milestone: could not determine current phase from ${plan_file}"
  local scope="${current_phase}/${agent}"
  _clear_convergence_markers "$plan_file" "$scope"
  local ts
  ts=$(_iso_timestamp)
  _append_to_critic_verdicts "$plan_file" \
    "[MILESTONE-BOUNDARY @${ts}] ${scope}:"
  echo "[reset-milestone] cleared convergence markers and added milestone boundary for ${scope}" >&2
}

cmd_reset_pr_review() {
  local plan_file="$1"
  require_file "$plan_file"
  local current_phase
  current_phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "unknown")
  [ "$current_phase" = "unknown" ] && die "reset-pr-review: could not determine current phase from ${plan_file}"
  for phase in implement review; do
    _clear_convergence_markers "$plan_file" "${phase}/pr-review"
    local ts
    ts=$(_iso_timestamp)
    _append_to_critic_verdicts "$plan_file" \
      "[MILESTONE-BOUNDARY @${ts}] ${phase}/pr-review:"
  done
  echo "[reset-pr-review] cleared pr-review convergence markers for implement and review phases" >&2
}

cmd_reset_for_rollback() {
  local plan_file="$1" target_phase="$2"
  require_file "$plan_file"
  [ -n "$target_phase" ] || die "reset-for-rollback: target-phase required"
  cmd_set_phase "$plan_file" "$target_phase"
  cmd_reset_milestone "$plan_file" critic-code
  cmd_reset_pr_review "$plan_file"
  _clear_convergence_markers "$plan_file" "review/critic-code"
  echo "[reset-for-rollback] phase set to ${target_phase}; critic-code and pr-review state cleared" >&2
}

cmd_context() {
  require_jq
  local plan_file
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0

  local phase
  phase=$(cmd_get_phase "$plan_file" 2>/dev/null || echo "unknown")

  local verdicts
  verdicts=$(awk '/^## Critic Verdicts$/{found=1; next} found && /^## /{found=0} found && /^- /{print}' \
    "$plan_file" 2>/dev/null | tail -3 | sed 's/^- //' | tr '\n' '|' | sed 's/|$//' || echo "none")

  local blocked_items other_items questions
  blocked_items=$(awk '/^## Open Questions$/{found=1; next} found && /^## /{found=0} found && (/\[BLOCKED/ || /\[STOP-BLOCKED/){print}' \
    "$plan_file" 2>/dev/null | head -3 | tr '\n' '|' | sed 's/|$//' || true)
  other_items=$(awk '/^## Open Questions$/{found=1; next} found && /^## /{found=0} found && /[^[:space:]]/ && !/\[BLOCKED/ && !/\[STOP-BLOCKED/ && !/\[CONVERGED/ && !/\[FIRST-TURN/ && !/\[AUTO-DECIDED/{print}' \
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

  local line_count size_warning=""
  line_count=$(wc -l < "$plan_file" 2>/dev/null || echo 0)
  if [ "$line_count" -gt 500 ]; then
    size_warning=" | WARNING: plan file is ${line_count} lines (>500) — run gc-events or archive old sections"
  fi

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

# ── Task commands ─────────────────────────────────────────────────────────────

cmd_add_task() {
  local plan_file="$1" task_id="$2" layer="$3"
  require_file "$plan_file"
  # Idempotent: skip if task already in ledger (prevents duplicate rows on recovery re-run)
  grep -qF "| ${task_id} |" "$plan_file" 2>/dev/null && return 0
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
          matched++
          next
        }
      }
    }
    { print }
    END { exit (matched == 0) ? 1 : 0 }
  ' || { echo "ERROR: task id '$task_id' not found in $plan_file" >&2; exit 1; }
}

cmd_tier_safe() {
  local plan_file="$1"; shift
  require_file "$plan_file"
  [ $# -ge 1 ] || die "tier-safe requires at least one task-id"
  local blocked_tasks="" task_id status
  for task_id in "$@"; do
    status=$(awk -v tid="$task_id" '
      /^## Task Ledger$/ { in_section=1; next }
      in_section && /^## / { in_section=0 }
      in_section && /^\| / {
        n = split($0, f, "|")
        if (n >= 5) {
          id = f[2]; sub(/^[[:space:]]+/, "", id); sub(/[[:space:]]+$/, "", id)
          st = f[4]; sub(/^[[:space:]]+/, "", st); sub(/[[:space:]]+$/, "", st)
          if (id == tid) { print st; exit }
        }
      }
    ' "$plan_file" 2>/dev/null || true)
    if [ "$status" = "blocked" ]; then
      blocked_tasks="${blocked_tasks} ${task_id}(ledger:blocked)"
      continue
    fi
    if grep -qF "[BLOCKED] coder:${task_id}" "$plan_file" 2>/dev/null; then
      blocked_tasks="${blocked_tasks} ${task_id}([BLOCKED] coder)"
    fi
  done
  if [ -n "$blocked_tasks" ]; then
    echo "BLOCKED [tier-safe]: the following tasks are blocked — cannot merge tier:${blocked_tasks}" >&2
    exit 2
  fi
  exit 0
}

# ── Event commands ────────────────────────────────────────────────────────────

cmd_record_task_completed() {
  require_jq
  local input task_id plan_file
  input=$(cat)
  task_id=$(printf '%s' "$input" | jq -r '.task_id // "unknown"' 2>/dev/null || echo "unknown")
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0
  cmd_update_task "$plan_file" "$task_id" "completed" || true
  echo "[record-task-completed] marked task (${task_id}) completed in ${plan_file}" >&2
}

cmd_gc_events() {
  local plan_file
  plan_file=$(cmd_find_active 2>/dev/null) || { echo "[gc-events] no active plan file" >&2; exit 0; }
  if ! grep -q "^## Open Questions$" "$plan_file"; then
    echo "[gc-events] no Open Questions section in ${plan_file}" >&2
    exit 0
  fi
  _awk_inplace "$plan_file" '
    /^## Open Questions$/ { in_section=1; print; next }
    in_section && /^## / {
      for (i=1; i<=user_count; i++) print user_memos[i]
      for (i=1; i<=kept_count; i++) print kept[i]
      print ""
      print
      in_section=0
      next
    }
    in_section {
      if (/\[BLOCKED/ || /\[STOP-BLOCKED/ || /\[CONVERGED/ || /\[FIRST-TURN/ || /\[UNVERIFIED CLAIM/) {
        kept[++kept_count] = $0
      } else if (/\[(AUTO-DECIDED)/) {
        # Discard transient audit markers.
      } else if (/^[[:space:]]*$/) {
        # Discard blank lines; spacing re-added on flush
      } else {
        user_memos[++user_count] = $0
      }
      next
    }
    { print }
    END {
      if (in_section) {
        for (i=1; i<=user_count; i++) print user_memos[i]
        for (i=1; i<=kept_count; i++) print kept[i]
      }
    }
  '
  echo "[gc-events] compacted Open Questions in ${plan_file}" >&2
}

cmd_gc_verdicts() {
  local plan_file="$1"
  require_file "$plan_file"
  if ! grep -q "^## Critic Verdicts$" "$plan_file"; then
    echo "[gc-verdicts] no Critic Verdicts section in ${plan_file}" >&2; return 0
  fi
  _awk_inplace "$plan_file" '
    /^## Critic Verdicts$/ { in_section=1; print; next }
    in_section && /^## / {
      if (n > 0) {
        start = (last_boundary > 0) ? last_boundary : 1
        dropped = start - 1
        for (i = start; i <= n; i++) print lines[i]
        if (dropped > 0)
          print "[gc-verdicts] dropped " dropped " pre-boundary verdict lines" > "/dev/stderr"
      }
      in_section=0; print; next
    }
    in_section {
      lines[++n] = $0
      if (index($0, "[MILESTONE-BOUNDARY @") > 0) last_boundary = n
      next
    }
    { print }
    END {
      if (in_section && n > 0) {
        start = (last_boundary > 0) ? last_boundary : 1
        dropped = start - 1
        for (i = start; i <= n; i++) print lines[i]
        if (dropped > 0)
          print "[gc-verdicts] dropped " dropped " pre-boundary verdict lines" > "/dev/stderr"
      }
    }
  '
}

cmd_record_stop_block() {
  local plan_file="$1" phase="$2" reason="$3"
  require_file "$plan_file"
  local ts
  ts=$(_iso_timestamp)
  _append_to_open_questions "$plan_file" \
    "[STOP-BLOCKED @${ts}] phase=${phase} — ${reason}"
  echo "[record-stop-block] recorded stop block (phase=${phase}): ${reason}" >&2
}
