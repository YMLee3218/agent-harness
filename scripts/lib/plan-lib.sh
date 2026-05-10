#!/usr/bin/env bash
# Plan-file library — all commands (formerly plan-core/phase/verdicts/ledger.sh).
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PLAN_LIB_LOADED:-}" ]] && return 0
_PLAN_LIB_LOADED=1

_PLAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_ACTIVE_PLAN_LOADED:-}" ]] || . "$_PLAN_LIB_DIR/active-plan.sh"
[[ -n "${_PHASE_POLICY_LOADED:-}" ]] || . "${_PLAN_LIB_DIR}/../phase-policy.sh"
[[ -n "${_SIDECAR_LOADED:-}" ]] || . "$_PLAN_LIB_DIR/sidecar.sh"
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

# Agents whose verdicts are recorded via the SubagentStop hook (record-verdict-guarded).
_is_subagent_critic() {
  case " ${VALID_CRITIC_AGENTS} " in
    *" ${1:-} "*) return 0 ;;
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
    sc_ensure_dir "$plan_file"  # H4-5th: ensure sidecar exists even for pre-existing plans
    return 0
  fi
  mkdir -p "$(dirname "$plan_file")"
  {
    printf -- '---\nfeature: %s\nphase: brainstorm\nschema: 2\n' "$slug"
    [ -n "$mode" ] && printf 'mode: %s\n' "$mode"
    printf -- '---\n\n## Vision\n\n## Scenarios\n\n## Test Manifest\n\n## Phase\nbrainstorm\n\n## Phase Transitions\n- brainstorm → (initial)\n\n## Critic Verdicts\n\n## Task Ledger\n\n## Integration Failures\n\n## Verdict Audits\n\n## Open Questions\n'
  } > "$plan_file"
  sc_ensure_dir "$plan_file"
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
  # In agent context (not harness/human), reject any text containing a control marker token
  # (e.g. " [BLOCKED] foo", "note [CONVERGED] x/y"). Pattern matches [UPPERCASE...] anywhere.
  if [[ "${CLAUDE_PLAN_CAPABILITY:-agent}" != "harness" && "${CLAUDE_PLAN_CAPABILITY:-agent}" != "human" ]]; then
    if printf '%s' "${note:-}" | grep -qE '\[[A-Z][A-Z0-9_:-]*\]'; then
      die "append-note: control marker tokens (e.g. [BLOCKED], [CONVERGED], [IMPLEMENTED: x]) are reserved for the harness — use free-form text for notes in ## Open Questions"
    fi
  fi
  require_file "$plan_file"
  _append_to_open_questions "$plan_file" "$note"
  # Mirror BLOCKED notes to sidecar blocked.jsonl so is-blocked reads from authoritative source
  if printf '%s' "${note:-}" | grep -qE '^\[BLOCKED'; then
    if command -v jq >/dev/null 2>&1; then
      sc_ensure_dir "$plan_file"
      local _kind="runtime"
      case "$note" in
        *'[BLOCKED-CEILING]'*) _kind="ceiling" ;;
        *'[BLOCKED] parse:'*)  _kind="parse" ;;
        *'[BLOCKED] category:'*) _kind="category" ;;
        *'[BLOCKED] protocol-violation:'*) _kind="protocol-violation" ;;
        *'[BLOCKED] preflight:'*) _kind="preflight" ;;
        *'[BLOCKED] integration:'*) _kind="integration" ;;
        *'[BLOCKED] coder:'*) _kind="coder" ;;
        *'[BLOCKED-AMBIGUOUS]'*) _kind="ambiguous" ;;
        *'[BLOCKED] script-failure:'*|*'[BLOCKED] session-timeout'*|*'[BLOCKED] no timeout'*|*'[BLOCKED] plan unchanged'*) _kind="runtime" ;;
      esac
      sc_append_jsonl "$(sc_path "$plan_file" "blocked.jsonl")" \
        "$(jq -nc --arg ts "$(_iso_timestamp)" --arg kind "$_kind" \
             --arg scope "$(basename "$plan_file" .md)" --arg msg "$note" \
             '{"ts":$ts,"kind":$kind,"agent":"harness","scope":$scope,"message":$msg,"cleared_at":null}')" 2>/dev/null || true
    fi
  fi
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

# ── Sidecar convergence helpers ───────────────────────────────────────────────

# Reset the sidecar convergence JSON for a phase/agent scope (increment milestone_seq).
# Called by reset-milestone, reset-pr-review, clear-converged.
_sc_reset_convergence_for_scope() {
  local plan_file="$1" phase="$2" agent="$3"
  command -v jq >/dev/null 2>&1 || return 0
  sc_ensure_dir "$plan_file"
  local conv_path
  conv_path=$(sc_path "$plan_file" "convergence/${phase}__${agent}.json")
  local existing_ms=0
  if [[ -f "$conv_path" ]]; then
    existing_ms=$(jq -r '.milestone_seq // 0' "$conv_path" 2>/dev/null || echo 0)
  fi
  local new_ms=$((existing_ms + 1))
  sc_update_json "$conv_path" \
    "$(jq -nc --arg p "$phase" --arg a "$agent" --argjson ms "$new_ms" \
      '{"phase":$p,"agent":$a,"first_turn":false,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":0,"milestone_seq":$ms}')"
}

# ── Verdict IO, loop-state, reset, context ────────────────────────────────────

# _jq_compute_or_block PLAN_FILE JSONL_PATH LABEL JQ_FILTER [JQ_ARGS...]
# Runs jq -r [JQ_ARGS...] JQ_FILTER JSONL_PATH; on failure appends BLOCKED runtime record and returns 1.
# Caller receives raw jq stdout and performs post-processing (wc -l, awk, etc.).
_jq_compute_or_block() {
  local plan_file="$1" jsonl_path="$2" label="$3" jq_filter="$4"
  shift 4
  local _out _rc=0
  _out=$(jq -r "$@" "$jq_filter" "$jsonl_path" 2>/dev/null) || _rc=$?
  if [[ $_rc -ne 0 ]]; then
    _append_to_open_questions "$plan_file" \
      "[BLOCKED] runtime: corrupt verdicts.jsonl — jq parse failed computing ${label}; manual inspection required"
    sc_append_jsonl "$(sc_path "$plan_file" "blocked.jsonl")" \
      "$(jq -nc --arg ts "$(_iso_timestamp)" --arg label "$label" \
           '{"ts":$ts,"kind":"runtime","agent":"harness","scope":"verdicts","message":("corrupt verdicts.jsonl — " + $label + " computation failed"),"cleared_at":null}')" 2>/dev/null || true
    return 1
  fi
  printf '%s' "${_out:-}"
}

PHASE_CONVERGENCE_MARKERS=(
  "BLOCKED-CEILING"
  "CONVERGED"
  "FIRST-TURN"
)

_record_loop_state() {
  local plan_file="$1" current_phase="$2" agent="$3" verdict="$4" category="${5:-}"
  local ceiling="${CLAUDE_CRITIC_LOOP_CEILING:-5}"
  case "$ceiling" in
    ''|*[!0-9]*) echo "[record-loop-state] invalid CLAUDE_CRITIC_LOOP_CEILING '${ceiling}'; falling back to 5" >&2; ceiling=5 ;;
  esac
  if [ "$ceiling" -lt 2 ]; then
    echo "[record-loop-state] CLAUDE_CRITIC_LOOP_CEILING=${ceiling} is less than 2; falling back to 5" >&2; ceiling=5
  fi

  # ── Sidecar path (canonical source of truth when jq is available) ─────────
  if command -v jq >/dev/null 2>&1; then
    sc_ensure_dir "$plan_file"
    local verdicts_path convergence_path
    verdicts_path=$(sc_path "$plan_file" "verdicts.jsonl")
    convergence_path=$(sc_path "$plan_file" "convergence/${current_phase}__${agent}.json")

    # Read existing convergence state
    local conv_state
    conv_state=$(sc_read_json "$convergence_path" \
      '{"first_turn":false,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":0,"milestone_seq":0}')
    local current_milestone_seq
    current_milestone_seq=$(printf '%s' "$conv_state" | jq -r '.milestone_seq // 0')

    # Count prior verdicts for this scope/milestone (determines ordinal)
    local prior_ordinal=0
    if [[ -f "$verdicts_path" ]]; then
      local _ord_out
      _ord_out=$(_jq_compute_or_block "$plan_file" "$verdicts_path" "ordinal" \
        'select(.phase == $p and .agent == $a and .milestone_seq == $ms) | 1' \
        --arg p "$current_phase" --arg a "$agent" --argjson ms "$current_milestone_seq") || return 1
      prior_ordinal=$(printf '%s' "$_ord_out" | awk 'END{print NR}' || echo 0)
    fi
    local run_ordinal=$((prior_ordinal + 1))

    # Ceiling check
    if [ "$run_ordinal" -gt "$ceiling" ]; then
      sc_update_json "$convergence_path" \
        "$(printf '%s' "$conv_state" | jq '.ceiling_blocked = true')"
      if ! grep -qF "[BLOCKED-CEILING] ${current_phase}/${agent}" "$plan_file" 2>/dev/null; then
        _append_to_open_questions "$plan_file" \
          "[BLOCKED-CEILING] ${current_phase}/${agent}: exceeded ${ceiling} runs — manual review required"
      fi
      # Dedup under a single flock: read+decide+write atomically to prevent duplicate ceiling records
      # when two SubagentStop hooks fire concurrently for the same scope.
      local _ceil_bpath
      _ceil_bpath=$(sc_path "$plan_file" "blocked.jsonl")
      (
        if command -v flock >/dev/null 2>&1; then
          flock -w 5 200 || { echo "[sidecar] lock timeout for ${_ceil_bpath}" >&2; exit 1; }
        fi
        local _ceil_count=0
        if [[ -f "$_ceil_bpath" ]]; then
          local _ceil_out _ceil_rc=0
          _ceil_out=$(jq -r --arg scope "${current_phase}/${agent}" \
            'select(.cleared_at == null and .kind == "ceiling" and .scope == $scope) | 1' \
            "$_ceil_bpath" 2>/dev/null) || _ceil_rc=$?
          if [[ $_ceil_rc -eq 0 ]]; then
            _ceil_count=$(printf '%s' "${_ceil_out:-}" | awk 'END{print NR}')
          fi
        fi
        if [[ "$_ceil_count" -eq 0 ]]; then
          sc_append_jsonl_unlocked "$_ceil_bpath" "$(jq -nc --arg ts "$(_iso_timestamp)" --arg agent "$agent" \
               --arg scope "${current_phase}/${agent}" --arg msg "exceeded ${ceiling} runs" \
               '{"ts":$ts,"kind":"ceiling","agent":$agent,"scope":$scope,"message":$msg,"cleared_at":null}')"
        fi
      ) 200>"${_ceil_bpath}.lock" || {
        _append_to_open_questions "$plan_file" \
          "[BLOCKED] runtime: ceiling-dedup lock timeout — check for stale ${_ceil_bpath}.lock and re-run"
        sc_append_jsonl "$_ceil_bpath" "$(jq -nc --arg ts "$(_iso_timestamp)" --arg agent "$agent" \
             --arg scope "${current_phase}/${agent}" \
             '{"ts":$ts,"kind":"runtime","agent":$agent,"scope":$scope,"message":"ceiling-dedup lock timeout","cleared_at":null}')" || true
      }
      echo "[record-loop-state] BLOCKED-CEILING: ${current_phase}/${agent} run #${run_ordinal} exceeds ceiling ${ceiling}" >&2
      return 1
    fi

    # First-turn tracking
    local was_first_turn new_first_turn
    was_first_turn=$(printf '%s' "$conv_state" | jq -r '.first_turn')
    if [[ "$verdict" != "PARSE_ERROR" ]]; then
      if [[ "$was_first_turn" != "true" ]]; then
        _append_to_open_questions "$plan_file" "[FIRST-TURN] ${current_phase}/${agent}"
        echo "[record-loop-state] FIRST-TURN: ${current_phase}/${agent} first real verdict" >&2
      fi
      new_first_turn="true"
    else
      new_first_turn="$was_first_turn"
    fi

    # Append current verdict to verdicts.jsonl
    local ts verdict_record
    ts=$(_iso_timestamp)
    verdict_record=$(jq -nc \
      --arg ts "$ts" --arg phase "$current_phase" --arg agent "$agent" \
      --arg verdict "$verdict" --arg category "$category" \
      --argjson ord "$run_ordinal" --argjson ms "$current_milestone_seq" \
      '{"ts":$ts,"phase":$phase,"agent":$agent,"verdict":$verdict,"category":$category,"ordinal":$ord,"milestone_seq":$ms}')
    sc_append_jsonl "$verdicts_path" "$verdict_record"

    # Compute trailing PASS streak (from updated verdicts.jsonl)
    local streak=0
    if [[ "$verdict" == "PASS" ]]; then
      local _streak_out
      _streak_out=$(_jq_compute_or_block "$plan_file" "$verdicts_path" "streak" \
        'select(.phase == $p and .agent == $a and .milestone_seq == $ms) | .verdict' \
        --arg p "$current_phase" --arg a "$agent" --argjson ms "$current_milestone_seq") || return 1
      streak=$(printf '%s' "$_streak_out" | \
        awk '{lines[NR]=$0} END{c=0; for(i=NR;i>=1;i--){if(lines[i]=="PASS")c++; else break}; print c}' \
        || echo "0")
    fi

    # Convergence check
    local was_converged new_converged prior_ceiling_blocked
    was_converged=$(printf '%s' "$conv_state" | jq -r '.converged')
    prior_ceiling_blocked=$(printf '%s' "$conv_state" | jq -r '.ceiling_blocked // false')
    new_converged="$was_converged"
    if [[ "$streak" -ge 2 ]] && [[ "$was_converged" != "true" ]]; then
      new_converged="true"
    fi

    # Write updated convergence state to sidecar FIRST (authoritative — harness reads only this)
    sc_update_json "$convergence_path" \
      "$(jq -nc \
        --arg p "$current_phase" --arg a "$agent" \
        --argjson ft "$([ "$new_first_turn" = "true" ] && echo true || echo false)" \
        --argjson streak "$streak" \
        --argjson conv "$([ "$new_converged" = "true" ] && echo true || echo false)" \
        --argjson cb "$([ "$prior_ceiling_blocked" = "true" ] && echo true || echo false)" \
        --argjson ord "$run_ordinal" --argjson ms "$current_milestone_seq" \
        '{"phase":$p,"agent":$a,"first_turn":$ft,"streak":$streak,"converged":$conv,"ceiling_blocked":$cb,"ordinal":$ord,"milestone_seq":$ms}')"

    # Write plan.md informational mirror AFTER sidecar (harness never reads this for decisions)
    if [[ "$new_converged" == "true" ]] && [[ "$was_converged" != "true" ]]; then
      _append_to_open_questions "$plan_file" "[CONVERGED] ${current_phase}/${agent}"
      echo "[record-loop-state] CONVERGED: ${current_phase}/${agent} with ${streak} consecutive PASSes" >&2
    fi

    return 0
  fi

  # jq required for sidecar operations — preflight guarantees this; hard-fail if missing
  die "_record_loop_state: jq is required but not found — install jq (brew install jq or apt install jq)"
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

# _check_consecutive_and_block PLAN PHASE AGENT JQ_PREV_QUERY MATCH_VAL KIND MSG LOG_LABEL
# Queries the previous verdict/category value from verdicts.jsonl using JQ_PREV_QUERY.
# If it equals MATCH_VAL, writes [BLOCKED] kind:agent: msg to plan.md and blocked.jsonl, returns 0.
# Returns 1 if no consecutive match (no block written).
_check_consecutive_and_block() {
  local plan_file="$1" phase="$2" agent="$3"
  local jq_prev_query="$4" match_val="$5" kind="$6" msg="$7" log_label="$8"
  local _ms _prev_val _vpath
  _ms=$(jq -r '.milestone_seq // 0' "$(sc_path "$plan_file" "convergence/${phase}__${agent}.json")" 2>/dev/null || echo 0)
  _vpath=$(sc_path "$plan_file" "verdicts.jsonl")
  _prev_val=""
  if [[ -f "$_vpath" ]]; then
    local _jq_rc=0
    _prev_val=$(jq -rs --arg p "$phase" --arg a "$agent" --argjson ms "$_ms" \
      "$jq_prev_query" "$_vpath" 2>/dev/null) || _jq_rc=$?
    if [[ $_jq_rc -ne 0 ]]; then
      _append_to_open_questions "$plan_file" \
        "[BLOCKED] runtime: corrupt verdicts.jsonl — run gc-sidecars or fix manually"
      sc_append_jsonl "$(sc_path "$plan_file" "blocked.jsonl")" \
        "$(jq -nc --arg ts "$(_iso_timestamp)" --arg agent "$agent" \
             --arg scope "${phase}/${agent}" \
             '{"ts":$ts,"kind":"runtime","agent":$agent,"scope":$scope,"message":"corrupt verdicts.jsonl — jq failed in consecutive check","cleared_at":null}')" 2>/dev/null || true
      return 0
    fi
  fi
  if [[ -n "$_prev_val" ]] && [[ "$_prev_val" == "$match_val" ]]; then
    _append_to_open_questions "$plan_file" "[BLOCKED] ${kind}:${agent}: ${msg}"
    sc_append_jsonl "$(sc_path "$plan_file" "blocked.jsonl")" \
      "$(jq -nc --arg ts "$(_iso_timestamp)" --arg agent "$agent" \
           --arg scope "${phase}/${agent}" --arg kind "$kind" --arg msg "$msg" \
           '{"ts":$ts,"kind":$kind,"agent":$agent,"scope":$scope,"message":$msg,"cleared_at":null}')" 2>/dev/null || true
    echo "[record-verdict] ${log_label}" >&2
    return 0
  fi
  return 1
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
    if _check_consecutive_and_block "$plan_file" "$current_phase" "$agent_name" \
        '[.[] | select(.phase == $p and .agent == $a and .milestone_seq == $ms)] | .[-2].verdict // ""' \
        "PARSE_ERROR" "parse" \
        "verdict marker missing (two consecutive parse errors) — check agent output format before retrying" \
        "BLOCKED parse: ${agent_name} two consecutive PARSE_ERRORs"; then
      : # blocked — message already written
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
    if _check_consecutive_and_block "$plan_file" "$current_phase" "$agent_name" \
        '[.[] | select(.phase == $p and .agent == $a and .milestone_seq == $ms)] | .[-2].verdict // ""' \
        "PARSE_ERROR" "parse" \
        "FAIL without category (two consecutive parse errors) — check agent output format before retrying" \
        "BLOCKED parse: ${agent_name} two consecutive PARSE_ERRORs (FAIL without category)"; then
      : # blocked — message already written
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

  if ! _record_loop_state "$plan_file" "$current_phase" "$agent_name" "$verdict" "$category"; then
    cmd_append_verdict "$plan_file" "$verdict_label"
    echo "[record-verdict] BLOCKED-CEILING from _record_loop_state — verdict appended, exiting 1" >&2
    exit 1
  fi

  if [ "$verdict" = "FAIL" ] && [ -n "$category" ]; then
    if _check_consecutive_and_block "$plan_file" "$current_phase" "$agent_name" \
        '[.[] | select(.phase == $p and .agent == $a and .milestone_seq == $ms and .verdict == "FAIL")] | .[-2].category // ""' \
        "$category" "category" \
        "${category} failed twice — fix the root cause before retrying" \
        "consecutive same-category FAIL (${category}) from ${agent_name} — blocked"; then
      cmd_append_verdict "$plan_file" "$verdict_label"
      exit 1
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
      # Use cmd_append_note so [BLOCKED] is mirrored to sidecar blocked.jsonl (H3-5th)
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
  local _hm
  for _hm in "${HUMAN_MUST_CLEAR_MARKERS[@]}"; do
    if [[ "$marker" == *"$_hm"* ]]; then
      require_capability "clear-marker:$_hm" C
      break
    fi
  done
  # H1-5th: update sidecar FIRST — sidecar is authoritative. Plan.md update follows only on success.
  # C5-5th: use startswith (anchored) instead of contains to prevent over-matching shorter prefixes.
  if command -v jq >/dev/null 2>&1; then
    sc_ensure_dir "$plan_file"  # guarantee sidecar exists before checking blocked.jsonl
    local _bpath _ts
    _bpath=$(sc_path "$plan_file" "blocked.jsonl")
    _ts=$(_iso_timestamp)
    _sc_rewrite_jsonl "$_bpath" \
      'if (.cleared_at == null and (.message | startswith($marker))) then .cleared_at = $ts else . end' \
      "clear-marker" \
      --arg marker "$marker" --arg ts "$_ts" || return 1
  fi
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
  # H1-5th: update sidecar FIRST — sidecar is authoritative. Plan.md update follows only on success.
  # C5-5th: exact agent match to prevent over-clearing unrelated scopes ("critic-code" must not
  #         clear "critic-code-v2"). Also clears harness-written records (agent="harness") whose
  #         message contains the structured marker pattern "[BLOCKED*]:agent:" — e.g. protocol-violation.
  if command -v jq >/dev/null 2>&1; then
    local _bpath _ts
    _bpath=$(sc_path "$plan_file" "blocked.jsonl")
    _ts=$(_iso_timestamp)
    _sc_rewrite_jsonl "$_bpath" \
      'if (.cleared_at == null and (.agent == $agent or (.agent == "harness" and (.message | test("\\[BLOCKED[^:]*:" + $agent + ":"))))) then .cleared_at = $ts else . end' \
      "unblock" \
      --arg agent "$agent" --arg ts "$_ts" || return 1
  fi
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
  _sc_reset_convergence_for_scope "$plan_file" "$current_phase" "$agent"
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
  _sc_reset_convergence_for_scope "$plan_file" "$current_phase" "$agent"
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
    _sc_reset_convergence_for_scope "$plan_file" "$phase" "pr-review"
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
  # Simplified: drop only [AUTO-DECIDED] and blank lines. All other markers are informational
  # only (control state lives in the sidecar) and are preserved for human transparency.
  _awk_inplace "$plan_file" '
    /^## Open Questions$/ { in_section=1; print; next }
    in_section && /^## / { print ""; print; in_section=0; next }
    in_section && /\[AUTO-DECIDED\]/ { next }
    in_section && /^[[:space:]]*$/ { next }
    { print }
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

cmd_gc_sidecars() {
  local plan_file="$1"
  require_file "$plan_file"
  command -v jq >/dev/null 2>&1 || { echo "[gc-sidecars] jq not available — skipping" >&2; return 0; }
  local vpath bpath
  vpath=$(sc_path "$plan_file" "verdicts.jsonl")
  bpath=$(sc_path "$plan_file" "blocked.jsonl")

  # verdicts.jsonl: keep two most recent milestone_seq values; archive the rest.
  # B3: skip entirely if file is empty (avoids keep_from=-1 edge case).
  if [[ -f "$vpath" ]] && [[ -s "$vpath" ]]; then
    local max_ms keep_from varchive
    max_ms=$(jq -r '.milestone_seq // 0' "$vpath" 2>/dev/null | sort -n | tail -1 || echo 0)
    keep_from=$(( max_ms - 1 ))
    varchive=$(sc_path "$plan_file" "verdicts-archive.jsonl")
    if _sc_rotate_jsonl "$vpath" "$varchive" \
        'select((.milestone_seq // 0) >= $kf)' \
        'select((.milestone_seq // 0) < $kf)' \
        "gc-sidecars" --argjson kf "$keep_from"; then
      echo "[gc-sidecars] rotated verdicts.jsonl (kept milestone_seq >= ${keep_from})" >&2
    fi
  fi

  # blocked.jsonl: archive cleared records older than 30 days.
  if [[ -f "$bpath" ]]; then
    local cutoff
    cutoff=$(date -u -d '30 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
             || date -u -v-30d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
    if [[ -n "$cutoff" ]]; then
      local barchive
      barchive=$(sc_path "$plan_file" "blocked-archive.jsonl")
      if _sc_rotate_jsonl "$bpath" "$barchive" \
          'select(.cleared_at == null or .cleared_at >= $cut)' \
          'select(.cleared_at != null and .cleared_at < $cut)' \
          "gc-sidecars" --arg cut "$cutoff"; then
        echo "[gc-sidecars] rotated blocked.jsonl (archived cleared records older than 30d)" >&2
      fi
    else
      # B4: warn when neither GNU nor BSD date supports relative cutoff
      echo "[gc-sidecars] WARNING: neither GNU nor BSD date supports relative cutoff — skipping blocked.jsonl rotation" >&2
    fi
  fi
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

# ── Sidecar query commands ────────────────────────────────────────────────────

# is-converged PLAN PHASE AGENT
# Returns 0 if sidecar says converged, 1 if not converged, 2 if jq unavailable (callers treat as blocked).
# Reads ONLY from the sidecar: plan.md [CONVERGED] markers are informational and ignored.
cmd_is_converged() {
  local plan_file="$1" phase="$2" agent="$3"
  require_file "$plan_file"
  if ! command -v jq >/dev/null 2>&1; then
    echo "[is-converged] jq required but not found — preflight should have blocked this run" >&2
    return 2
  fi
  local conv_path
  conv_path=$(sc_path "$plan_file" "convergence/${phase}__${agent}.json")
  if [[ ! -f "$conv_path" ]]; then
    echo "[is-converged] WARNING: sidecar convergence file absent — treating as not-converged (run migrate-to-sidecar if this is unexpected)" >&2
    return 1
  fi
  local converged
  converged=$(jq -r '.converged // false' "$conv_path" 2>/dev/null || echo false)
  [[ "$converged" == "true" ]]
}

# has-blocked PLAN [KIND] — returns 0 if any uncleared blocked record exists, 1 if none.
# Reads from sidecar blocked.jsonl only (cmd_init guarantees sidecar always exists).
# Optional KIND filters by record kind (e.g. "integration", "parse", "ceiling").
cmd_has_blocked() {
  local plan_file="$1" kind="${2:-}"
  require_file "$plan_file"
  local _bpath
  _bpath=$(sc_path "$plan_file" "blocked.jsonl")
  if [[ ! -f "$_bpath" ]]; then
    echo "[has-blocked] WARNING: blocked.jsonl absent — treating as not-blocked (run migrate-to-sidecar if this is unexpected)" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "[has-blocked] jq required but not found — preflight should have blocked this run" >&2
    return 2
  fi
  local _count
  if [[ -n "$kind" ]]; then
    _count=$(jq -r --arg k "$kind" 'select(.cleared_at == null and .kind == $k) | 1' \
      "$_bpath" 2>/dev/null | awk 'END{print NR}' || echo 0)
  else
    _count=$(jq -r 'select(.cleared_at == null) | 1' "$_bpath" 2>/dev/null | awk 'END{print NR}' || echo 0)
  fi
  [[ "$_count" -gt 0 ]]
}

# is-blocked PLAN [KIND] — alias for has-blocked (Ring A: agent-callable read-only query)
cmd_is_blocked() {
  cmd_has_blocked "$@"
}

# is-implemented PLAN FEAT_SLUG — returns 0 if sidecar says implemented, 1 otherwise.
cmd_is_implemented() {
  local plan_file="$1" feat_slug="$2"
  require_file "$plan_file"
  local impl_path
  impl_path=$(sc_path "$plan_file" "implemented.json")
  command -v jq >/dev/null 2>&1 || return 1
  if [[ ! -f "$impl_path" ]]; then
    echo "[is-implemented] WARNING: sidecar implemented.json absent — treating as not-implemented (run migrate-to-sidecar if this is unexpected)" >&2
    return 1
  fi
  local result
  result=$(jq -r --arg slug "$feat_slug" '.features | map(. == $slug) | any' "$impl_path" 2>/dev/null || echo false)
  [[ "$result" == "true" ]]
}

# mark-implemented PLAN FEAT_SLUG — write to sidecar + plan.md [IMPLEMENTED:] marker
cmd_mark_implemented() {
  local plan_file="$1" feat_slug="$2"
  require_file "$plan_file"
  sc_ensure_dir "$plan_file"
  require_jq
  local impl_path existing new_state
  impl_path=$(sc_path "$plan_file" "implemented.json")
  if [[ -f "$impl_path" ]]; then
    existing=$(cat "$impl_path")
  else
    existing='{"features":[]}'
  fi
  new_state=$(printf '%s' "$existing" | jq --arg slug "$feat_slug" \
    '.features |= (. + [$slug] | unique)')
  sc_update_json "$impl_path" "$new_state"
  _append_to_open_questions "$plan_file" "[IMPLEMENTED: ${feat_slug}]"
  echo "[mark-implemented] ${feat_slug} marked implemented in ${plan_file}" >&2
}

# inter-feature-reset PLAN — remove task-definitions block and pending/in_progress/completed/blocked
# rows from Task Ledger in plan.md (Ring B: harness-only, called between feature iterations)
cmd_inter_feature_reset() {
  local plan_file="$1"
  require_file "$plan_file"
  _awk_inplace "$plan_file" '
    /<!-- task-definitions-start -->/{skip=1;next}
    /<!-- task-definitions-end -->/{skip=0;next}
    skip{next}
    {print}
  '
  _awk_inplace "$plan_file" '
    /^## Task Ledger$/{sec=1;print;next}
    sec&&/^## /{sec=0}
    sec&&/\| pending[ |]|\| in_progress[ |]|\| completed[ |]|\| blocked[ |]/{next}
    {print}
  '
  echo "[inter-feature-reset] cleared task definitions and ledger rows in ${plan_file}" >&2
}

# migrate-to-sidecar PLAN — one-shot migration: build sidecar from plan.md markers
cmd_migrate_to_sidecar() {
  local plan_file="$1"
  require_file "$plan_file"
  require_jq
  sc_ensure_dir "$plan_file"
  local sentinel
  sentinel=$(sc_path "$plan_file" ".migrated_from_v2.txt")
  if [[ -f "$sentinel" ]]; then
    echo "[migrate-to-sidecar] already migrated: $plan_file" >&2
    return 0
  fi
  # C3-5th: refuse if convergence files already exist — they were written by the harness and are
  # authoritative. Overwriting them with plan.md text could re-introduce forged [CONVERGED] markers.
  local conv_dir
  conv_dir=$(sc_path "$plan_file" "convergence")
  if ls "${conv_dir}"/*.json 2>/dev/null | grep -q .; then
    echo "[migrate-to-sidecar] BLOCKED: convergence files already exist in ${conv_dir} — migration refused to avoid overwriting authoritative sidecar state (use reset-milestone if a fresh start is needed)" >&2
    return 1
  fi
  local phase agent
  for phase in brainstorm spec red implement review; do
    for agent in critic-feature critic-spec critic-test critic-code critic-cross pr-review; do
      local scope="${phase}/${agent}"
      local converged=false ceiling_blocked=false streak_val=0
      if grep -qF "[CONVERGED] ${scope}" "$plan_file" 2>/dev/null; then
        converged=true; streak_val=2
      fi
      if grep -qF "[BLOCKED-CEILING] ${scope}" "$plan_file" 2>/dev/null; then
        ceiling_blocked=true
      fi
      if [[ "$converged" == "true" ]] || [[ "$ceiling_blocked" == "true" ]]; then
        local conv_path
        conv_path=$(sc_path "$plan_file" "convergence/${phase}__${agent}.json")
        jq -nc \
          --arg p "$phase" --arg a "$agent" \
          --argjson conv "$converged" --argjson cb "$ceiling_blocked" \
          --argjson streak "$streak_val" \
          '{"phase":$p,"agent":$a,"first_turn":true,"streak":$streak,"converged":$conv,"ceiling_blocked":$cb,"ordinal":2,"milestone_seq":0}' \
          > "$conv_path"
        echo "[migrate-to-sidecar] ${scope}: converged=${converged} ceiling=${ceiling_blocked}" >&2
      fi
    done
  done
  local impl_path
  impl_path=$(sc_path "$plan_file" "implemented.json")
  if [[ ! -f "$impl_path" ]]; then
    local features_json='{"features":[]}'
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local slug
      slug=$(printf '%s' "$line" | sed 's/.*\[IMPLEMENTED: //; s/\].*//')
      features_json=$(printf '%s' "$features_json" | jq --arg s "$slug" '.features |= (. + [$s] | unique)')
    done < <(grep -F '[IMPLEMENTED:' "$plan_file" 2>/dev/null || true)
    sc_update_json "$impl_path" "$features_json"
  fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ): migrated from plan.md v2" > "$sentinel"
  echo "[migrate-to-sidecar] migration complete for $plan_file" >&2
}
