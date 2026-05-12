#!/usr/bin/env bash
# Merged plan-cmd: state / notes / verdicts / record-verdict / markers / tasks-gc / sidecar.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PLAN_CMD_LOADED:-}" ]] && return 0
_PLAN_CMD_LOADED=1

_PLAN_CMD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_PLAN_LIB_LOADED:-}" ]]          || . "$_PLAN_CMD_DIR/plan-lib.sh"
[[ -n "${_PLAN_LOOP_HELPERS_LOADED:-}" ]] || . "$_PLAN_CMD_DIR/plan-loop-helpers.sh"

# ── State management ──────────────────────────────────────────────────────────

cmd_init() {
  local plan_file="$1"
  local mode="${2:-}"
  local slug
  slug=$(basename "$plan_file" .md)
  if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
    die "cmd_init: plan slug '${slug}' contains illegal characters — must match ^[a-z0-9][a-z0-9_-]{0,63}$"
  fi
  if [ -f "$plan_file" ]; then
    if [ -n "$mode" ]; then
      local existing
      existing=$(awk '/^mode:/{print $2; exit}' "$plan_file" 2>/dev/null || true)
      if [ -n "$existing" ] && [ "$existing" != "$mode" ]; then
        echo "[plan-file] init: existing plan has mode='${existing}', requested='${mode}' — keeping existing" >&2
      fi
    fi
    echo "[plan-file] init: $plan_file already exists — skipping" >&2
    sc_ensure_dir "$plan_file" || die "ERROR: sidecar dir setup failed for $plan_file"
    return 0
  fi
  mkdir -p "$(dirname "$plan_file")"
  {
    printf -- '---\nfeature: %s\nphase: brainstorm\nschema: 2\n' "$slug"
    [ -n "$mode" ] && printf 'mode: %s\n' "$mode"
    printf -- '---\n\n## Vision\n\n## Scenarios\n\n## Test Manifest\n\n## Phase\nbrainstorm\n\n## Phase Transitions\n- brainstorm → (initial)\n\n## Critic Verdicts\n\n## Task Ledger\n\n## Integration Failures\n\n## Verdict Audits\n\n## Open Questions\n'
  } > "$plan_file"
  sc_ensure_dir "$plan_file" || die "ERROR: sidecar dir setup failed for $plan_file"
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

_read_phase_quick() {
  local pf="$1" p=""
  p=$(awk '/^## Phase$/{found=1; next} found && /^[A-Za-z]/{print; exit}' "$pf" 2>/dev/null \
    | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' || true)
  echo "$p"
}

cmd_find_active() {
  local plans_dir="${CLAUDE_PROJECT_DIR:-$PWD}/plans"

  if [ -n "${CLAUDE_PLAN_FILE:-}" ]; then
    if [ -f "$CLAUDE_PLAN_FILE" ]; then
      local envphase
      envphase=$(_read_phase_quick "$CLAUDE_PLAN_FILE")
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
    bphase=$(_read_phase_quick "$plans_dir/${branch}.md")
    if [ -n "$bphase" ] && [ "$bphase" != "done" ]; then
      echo "$plans_dir/${branch}.md"
      return 0
    fi
  fi

  local found="" count=0 malformed=0
  while IFS= read -r -d '' f; do
    local _fn; _fn=$(basename "$f" .md)
    if ! [[ "$_fn" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
      echo "[plan-file] WARNING: skipping plan file with non-slug name: $f" >&2
      continue
    fi
    local phase
    phase=$(_read_phase_quick "$f")
    if [ -z "$phase" ]; then
      echo "[plan-file] ERROR: plan file exists but phase cannot be read: $f (missing ## Phase section)" >&2
      malformed=$((malformed + 1))
    elif [ "$phase" != "done" ]; then
      count=$((count + 1))
      [ -z "$found" ] && found="$f"
    fi
  done < <(find "$plans_dir" -maxdepth 1 -name '*.md' -print0 2>/dev/null | sort -z)
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

# _find_latest_by_mtime DIR PATTERN — POSIX-safe newest file by mtime.
_find_latest_by_mtime() {
  local _dir="$1" _pat="$2"
  if command -v find >/dev/null 2>&1 && find "$_dir" -maxdepth 1 -name "$_pat" -printf '%T@ %p\n' \
      >/dev/null 2>&1; then
    find "$_dir" -maxdepth 1 -name "$_pat" -printf '%T@ %p\n' 2>/dev/null | \
      sort -rn | head -1 | cut -d' ' -f2-
  else
    find "$_dir" -maxdepth 1 -name "$_pat" -type f -exec stat -f '%m %N' {} \; 2>/dev/null | \
      sort -rn | head -1 | cut -d' ' -f2-
  fi
}

cmd_find_latest() {
  local plans_dir="${CLAUDE_PROJECT_DIR:-$PWD}/plans"
  [ -d "$plans_dir" ] || return 2
  local f _fn
  f=$(_find_latest_by_mtime "$plans_dir" '*.md' || true)
  [ -z "$f" ] && return 2
  _fn=$(basename "$f" .md)
  if ! [[ "$_fn" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
    echo "[plan-file] WARNING: find-latest: skipping file with non-slug name: $f" >&2
    return 2
  fi
  echo "$f"
}

_require_phase() {
  local _plan="$1" _label="$2" _phase
  _phase=$(cmd_get_phase "$_plan" 2>/dev/null) || die "$_label: cannot read phase from $_plan"
  [ -z "$_phase" ] || [ "$_phase" = "unknown" ] && die "$_label: phase unknown for $_plan"
  echo "$_phase"
}

cmd_transition() {
  local plan_file="$1" to_phase="$2" reason="$3"
  require_file "$plan_file"
  local from_phase
  from_phase=$(_require_phase "$plan_file" "cmd_transition") || exit $?
  cmd_set_phase "$plan_file" "$to_phase"
  _append_to_phase_transitions "$plan_file" "- ${from_phase} → ${to_phase} (reason: ${reason})"
}

cmd_commit_phase() {
  local plan_file="$1" message="$2"
  git add "$plan_file"
  git diff --cached --quiet || git commit -m "$message"
}

# ── Notes / stop-block / context ──────────────────────────────────────────────

cmd_append_note() {
  local plan_file="$1" note="$2"
  if [[ "${CLAUDE_PLAN_CAPABILITY:-agent}" != "harness" && "${CLAUDE_PLAN_CAPABILITY:-agent}" != "human" ]]; then
    if printf '%s' "${note:-}" | grep -qE '\[[A-Z][A-Z0-9_:-]*\]'; then
      die "append-note: control marker tokens (e.g. [BLOCKED], [IMPLEMENTED: x]) are reserved for the harness — use free-form text for notes in ## Open Questions"
    fi
  fi
  require_file "$plan_file"
  _append_to_open_questions "$plan_file" "$note"
  if printf '%s' "${note:-}" | grep -qE '^\[BLOCKED'; then
    if command -v jq >/dev/null 2>&1; then
      sc_ensure_dir "$plan_file" || return 1
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
      _record_blocked "$plan_file" "$_kind" "harness" "$(basename "$plan_file" .md)" "$note" 2>/dev/null || true
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

cmd_context() {
  require_jq
  local plan_file
  plan_file=$(cmd_find_active 2>/dev/null) || exit 0

  local phase
  phase=$(_require_phase "$plan_file" "cmd_context") || exit 0

  local verdicts
  verdicts=$(awk '/^## Critic Verdicts$/{found=1; next} found && /^## /{found=0} found && /^- /{print}' \
    "$plan_file" 2>/dev/null | tail -3 | sed 's/^- //' | tr '\n' '|' | sed 's/|$//' || echo "none")

  local blocked_items other_items questions
  blocked_items=$(awk '/^## Open Questions$/{found=1; next} found && /^## /{found=0} found && (/\[BLOCKED/ || /\[STOP-BLOCKED/){print}' \
    "$plan_file" 2>/dev/null | head -3 | tr '\n' '|' | sed 's/|$//' || true)
  other_items=$(awk '/^## Open Questions$/{found=1; next} found && /^## /{found=0} found && /[^[:space:]]/ && !/\[BLOCKED/ && !/\[STOP-BLOCKED/ && !/\[FIRST-TURN/ && !/\[AUTO-DECIDED/{print}' \
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

# ── Verdict streak / ceiling / audit ─────────────────────────────────────────

# _dispatch_rls_rc PLAN LABEL RC — dispatches _record_loop_state failure codes; always exits 1.
_dispatch_rls_rc() {
  local _plan="$1" _label="$2" _rc="$3"
  case $_rc in
    1) echo "[record-verdict] BLOCKED-CEILING: ${_label}" >&2
       cmd_append_verdict "$_plan" "${MARK_BLOCKED_CEILING} ${_label}" ;;
    2) echo "[record-verdict] BLOCKED-CORRUPT: ordinal compute failed — ${_label} not persisted" >&2
       cmd_append_verdict "$_plan" "[BLOCKED] kind=corrupt ${_label}" ;;
    3) echo "[record-verdict] BLOCKED-STREAK: streak compute failed — ${_label} not persisted" >&2
       cmd_append_verdict "$_plan" "[BLOCKED] kind=streak ${_label}" ;;
    4) echo "[record-verdict] BLOCKED-WRITE: verdicts.jsonl append failed — plan.md NOT updated" >&2 ;;
    *) echo "[record-verdict] _record_loop_state rc=${_rc} — ${_label} not persisted" >&2
       cmd_append_verdict "$_plan" "$_label" ;;
  esac
  exit 1
}

# _check_consecutive_and_block PLAN PHASE AGENT JQ_PREV_QUERY MATCH_VAL KIND MSG LOG_LABEL
_check_consecutive_and_block() {
  local plan_file="$1" phase="$2" agent="$3"
  local jq_prev_query="$4" match_val="$5" kind="$6" msg="$7" log_label="$8"
  local _ms _prev_val _vpath _scope
  _scope=$(_scope_of "$phase" "$agent")
  _ms=$(jq -r '.milestone_seq // 0' "$(sc_conv_path "$plan_file" "$phase" "$agent")" 2>/dev/null || echo 0)
  _vpath=$(sc_path "$plan_file" "$SC_VERDICTS")
  _prev_val=""
  if [[ -f "$_vpath" ]]; then
    local _jq_rc=0
    _prev_val=$(jq -rs --arg p "$phase" --arg a "$agent" --argjson ms "$_ms" \
      "$jq_prev_query" "$_vpath" 2>/dev/null) || _jq_rc=$?
    if [[ $_jq_rc -ne 0 ]]; then
      _record_blocked_runtime "$plan_file" "$agent" "$_scope" \
        "corrupt verdicts.jsonl — jq failed in consecutive check; run gc-sidecars or fix manually"
      return 2
    fi
  fi
  if [[ -n "$_prev_val" ]] && [[ "$_prev_val" == "$match_val" ]]; then
    _append_to_open_questions "$plan_file" "[BLOCKED] ${kind}:${agent}: ${msg}"
    _record_blocked "$plan_file" "$kind" "$agent" "$_scope" "$msg" 2>/dev/null || true
    echo "[record-verdict] ${log_label}" >&2
    return 0
  fi
  return 1
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
    ACCEPT|ACCEPT-OVERRIDE|REJECT-PASS) ;;
    *) die "append-audit: invalid outcome '${outcome}'. Must be ACCEPT, ACCEPT-OVERRIDE, or REJECT-PASS" ;;
  esac
  local ts
  ts=$(_iso_timestamp)
  _append_to_verdict_audits "$plan_file" "- ${ts} ${agent} ${outcome}: ${summary}"
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
  current_phase=$(_require_phase "$plan_file" "append-review-verdict") || exit $?
  local verdict_label="${current_phase}/${agent}: ${verdict}"
  local _arv_rc=0
  _record_loop_state "$plan_file" "$current_phase" "$agent" "$verdict" || _arv_rc=$?
  [[ $_arv_rc -ne 0 ]] && _dispatch_rls_rc "$plan_file" "$verdict_label" "$_arv_rc"
  cmd_append_verdict "$plan_file" "$verdict_label"
  echo "[append-review-verdict] verdict appended: ${verdict_label}" >&2
}

# ── Record verdict ────────────────────────────────────────────────────────────

# _parse_verdict_message OUTPUT → prints "<verdict>|<category>"
_parse_verdict_message() {
  local _msg="$1" _v _c
  _v=$(printf '%s' "$_msg" | grep -oE '<!--[[:space:]]*verdict:[[:space:]]*[A-Z]+[[:space:]]*-->' | tail -1 \
       | sed -E 's/<!--[[:space:]]*verdict:[[:space:]]*//; s/[[:space:]]*-->//' || true)
  _c=$(printf '%s' "$_msg" | grep -oE '<!--[[:space:]]*category:[[:space:]]*[A-Z_]+[[:space:]]*-->' | tail -1 \
       | sed -E 's/<!--[[:space:]]*category:[[:space:]]*//; s/[[:space:]]*-->//' || true)
  printf '%s|%s\n' "${_v:-}" "${_c:-}"
}

_handle_parse_error() {
  local plan_file="$1" current_phase="$2" agent="$3" log_msg="$4" block_msg="$5" retry_msg="$6"
  echo "[record-verdict] ${log_msg}" >&2
  local _hpe_rc=0
  _record_loop_state "$plan_file" "$current_phase" "$agent" "PARSE_ERROR" || _hpe_rc=$?
  [[ $_hpe_rc -ne 0 ]] && _dispatch_rls_rc "$plan_file" "${current_phase}/${agent}: PARSE_ERROR" "$_hpe_rc"
  local _ccb_parse_rc=0
  _check_consecutive_and_block "$plan_file" "$current_phase" "$agent" \
      '[.[] | select(.phase == $p and .agent == $a and .milestone_seq == $ms)] | .[-2].verdict // ""' \
      "PARSE_ERROR" "parse" "$block_msg" \
      "BLOCKED parse: ${agent} two consecutive PARSE_ERRORs" || _ccb_parse_rc=$?
  case $_ccb_parse_rc in
    0) : ;;
    1) echo "[record-verdict] ${retry_msg}" >&2
       cmd_append_verdict "$plan_file" "${current_phase}/${agent}: PARSE_ERROR" ;;
    2) cmd_append_verdict "$plan_file" "[BLOCKED] kind=corrupt-check ${current_phase}/${agent}: PARSE_ERROR" ;;
    *) echo "[record-verdict] _check_consecutive_and_block rc=${_ccb_parse_rc} unknown" >&2; exit 1 ;;
  esac
  exit 1
}

# _resolve_output INPUT AGENT_TRANSCRIPT TRANSCRIPT → transcript text for verdict extraction
_resolve_output() {
  local input="$1" agent_transcript="$2" transcript="$3"
  local out="" _safe_path _transcript_size _size_warn=1048576
  if [ -n "$agent_transcript" ]; then
    _safe_path=$(_is_safe_transcript_path "$agent_transcript") && [ -f "$_safe_path" ] && {
      _transcript_size=$(wc -c < "$_safe_path" 2>/dev/null || echo 0)
      [ "$_transcript_size" -gt "$_size_warn" ] && \
        echo "[record-verdict] WARN: agent_transcript size ${_transcript_size} bytes — reading last 1MB only" >&2
      out=$(tail -c 1048576 "$_safe_path" | \
        jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="text")|.text//empty' \
        2>/dev/null || true)
    }
  fi
  if [ -z "$out" ] && [ -n "$transcript" ]; then
    _safe_path=$(_is_safe_transcript_path "$transcript") && [ -f "$_safe_path" ] && {
      _transcript_size=$(wc -c < "$_safe_path" 2>/dev/null || echo 0)
      [ "$_transcript_size" -gt "$_size_warn" ] && \
        echo "[record-verdict] WARN: transcript size ${_transcript_size} bytes — reading last 1MB only" >&2
      out=$(tail -c 1048576 "$_safe_path" | \
        jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="text")|.text//empty' \
        2>/dev/null | tail -200 || true)
    }
  fi
  [ -z "$out" ] && out=$(printf '%s' "$input" | jq -r '.last_assistant_message // ""' 2>/dev/null || echo "")
  printf '%s' "$out"
}

_resolve_plan_for_verdict() {
  local _agent="$1" _find_rc=0
  plan_file=$(cmd_find_active) || _find_rc=$?
  if [ "$_find_rc" -ne 0 ]; then
    case "$_find_rc" in
      2) echo "[record-verdict] no active plan file — verdict for ${_agent} dropped" >&2 ;;
      3) echo "[record-verdict] ambiguous: multiple active plan files — pin CLAUDE_PLAN_FILE for ${_agent}" >&2 ;;
      4) echo "[record-verdict] unreadable plan phase — verdict for ${_agent} dropped" >&2 ;;
      *) echo "[record-verdict] cmd_find_active failed (exit ${_find_rc}) — verdict for ${_agent} dropped" >&2 ;;
    esac
    exit 0
  fi
  current_phase=$(_require_phase "$plan_file" "record-verdict") || exit $?
}

_extract_or_handle_missing_verdict() {
  local _output="$1" _input="$2" _plan="$3" _phase="$4" _agent="$5" _pvm_out
  _pvm_out=$(_parse_verdict_message "$_output")
  IFS='|' read -r verdict category <<< "$_pvm_out"
  if [ -z "$verdict" ]; then
    printf '%s' "$_output" | grep -qE 'Verdict:\s*(PASS|FAIL)|\*\*Verdict:\s*(PASS|FAIL)\*\*' && {
      echo "[record-verdict] textual-verdict-only transcript for ${_agent} — skipping" >&2; exit 0; }
    printf '%s' "$_output" | grep -qE '### Verdict|<!-- verdict:' || {
      echo "[record-verdict] no verdict section in transcript for ${_agent} — skipping" >&2; exit 0; }
    local _keys; _keys=$(printf '%s' "$_input" | jq -r 'keys | join(", ")' 2>/dev/null || echo "unknown")
    _handle_parse_error "$_plan" "$_phase" "$_agent" \
      "missing verdict marker from ${_agent} (payload keys: ${_keys})" \
      "verdict marker missing (two consecutive parse errors) — check agent output format before retrying" \
      "first PARSE_ERROR for ${_agent} — will retry automatically"
  fi
  [ "$verdict" = "FAIL" ] && [ -z "$category" ] && \
    _handle_parse_error "$_plan" "$_phase" "$_agent" \
      "FAIL without category from ${_agent} — treating as PARSE_ERROR" \
      "FAIL without category (two consecutive parse errors) — check agent output format" \
      "first FAIL-without-category for ${_agent} — will retry automatically"
  return 0
}

_resolve_verdict_payload() {
  local _input="$1"
  agent_name=$(printf '%s' "$_input" | jq -r '.agent_type // "unknown"' 2>/dev/null) || {
    echo "[record-verdict] WARN: jq parse failed on input — agent_type unknown, verdict may be dropped" >&2
    agent_name="unknown"
    local _plan_file_fallback _rc_fallback=0
    _plan_file_fallback=$(cmd_find_active 2>/dev/null) || _rc_fallback=$?
    [ "$_rc_fallback" -eq 0 ] && [ -n "$_plan_file_fallback" ] && \
      _record_blocked_runtime "$_plan_file_fallback" "harness" "transcript-parse-failure" \
        "jq failed to extract agent_type" 2>/dev/null || true
  }
  _is_subagent_critic "$agent_name" || exit 0
  local _agent_transcript _transcript
  _agent_transcript=$(printf '%s' "$_input" | jq -r '.agent_transcript_path // empty' 2>/dev/null || true)
  _transcript=$(printf '%s' "$_input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
  _resolve_plan_for_verdict "$agent_name"
  local _output
  _output=$(_resolve_output "$_input" "$_agent_transcript" "$_transcript")
  _extract_or_handle_missing_verdict "$_output" "$_input" "$plan_file" "$current_phase" "$agent_name"
}

_persist_verdict() {
  local _plan="$1" _phase="$2" _agent="$3" _verdict="$4" _category="$5"
  local _label="${_phase}/${_agent}: ${_verdict}"
  [ -n "$_category" ] && _label="${_label} [category: ${_category}]"
  local _rls_rc=0
  _record_loop_state "$_plan" "$_phase" "$_agent" "$_verdict" "$_category" || _rls_rc=$?
  [[ $_rls_rc -ne 0 ]] && _dispatch_rls_rc "$_plan" "$_label" "$_rls_rc"
  if [ "$_verdict" = "FAIL" ] && [ -n "$_category" ]; then
    local _ccb_rc=0
    _check_consecutive_and_block "$_plan" "$_phase" "$_agent" \
      '[.[] | select(.phase == $p and .agent == $a and .milestone_seq == $ms and .verdict == "FAIL")] | .[-2].category // ""' \
      "$_category" "category" "${_category} failed twice — fix root cause before retrying" \
      "consecutive same-category FAIL (${_category}) from ${_agent} — blocked" || _ccb_rc=$?
    case $_ccb_rc in
      0) cmd_append_verdict "$_plan" "$_label"; exit 1 ;;
      1) : ;;
      2) cmd_append_verdict "$_plan" "[BLOCKED] kind=corrupt-check ${_label}"; exit 1 ;;
      *) echo "[record-verdict] _check_consecutive_and_block rc=${_ccb_rc} unknown" >&2; exit 1 ;;
    esac
  fi
  cmd_append_verdict "$_plan" "$_label"
  echo "[record-verdict] verdict appended: ${_label}" >&2
  [ "$_verdict" = "FAIL" ] && exit 1 || exit 0
}

cmd_record_verdict() {
  require_jq
  local input; input=$(cat)
  local plan_file agent_name current_phase verdict category
  _resolve_verdict_payload "$input"
  _persist_verdict "$plan_file" "$current_phase" "$agent_name" "$verdict" "$category"
}

cmd_record_verdict_guarded() {
  local _input _agent _plan _find_rc _lock
  _input=$(cat)
  _agent="unknown"
  if command -v jq >/dev/null 2>&1; then
    _agent=$(printf '%s' "$_input" | jq -r 'if (.agent_type // "") == "" then "unknown" else .agent_type end' 2>/dev/null || echo "unknown")
  fi
  if ! _is_subagent_critic "$_agent"; then
    exit 0
  fi
  _find_rc=0
  _plan=$(cmd_find_active) || _find_rc=$?
  _lock=""
  [ "$_find_rc" -eq 0 ] && _lock="${_plan}.critic.lock"
  if [ -z "$_lock" ] || [ ! -f "$_lock" ]; then
    if [ "$_find_rc" -eq 0 ]; then
      sc_ensure_dir "$_plan" || { echo "ERROR: [record-verdict-guarded] sc_ensure_dir failed: $_plan" >&2; exit 2; }
      _record_blocked_runtime "$_plan" "$_agent" "protocol-violation" \
        "invoked outside run-critic-loop.sh context"
    fi
    echo "[record-verdict-guarded] BLOCKED: ${_agent} ran outside run-critic-loop.sh" >&2
    exit 2
  fi
  printf '%s' "$_input" | cmd_record_verdict
}

# ── Markers / reset ───────────────────────────────────────────────────────────

PHASE_CONVERGENCE_MARKERS=(
  "BLOCKED-CEILING"
  "FIRST-TURN"
)

_clear_convergence_markers() {
  local plan_file="$1" scope="$2"
  local marker
  for marker in "${PHASE_CONVERGENCE_MARKERS[@]}"; do
    cmd_clear_marker "$plan_file" "[${marker}] ${scope}"
  done
}

_cmd_clear_marker_body() {
  local plan_file="$1" marker="$2"
  local _candidate_lines _hm
  _candidate_lines=$(awk -v marker="$marker" '
    /^## Open Questions$/ { in_section=1; next }
    in_section && /^## / { in_section=0 }
    in_section && substr($0, 1, length(marker)) == marker { print }
  ' "$plan_file" 2>/dev/null || true)
  if [[ -n "$_candidate_lines" ]]; then
    for _hm in "${HUMAN_MUST_CLEAR_MARKERS[@]}"; do
      if printf '%s' "$_candidate_lines" | grep -qF "$_hm"; then
        require_capability "clear-marker:$_hm" C
        break
      fi
    done
  fi
  if command -v jq >/dev/null 2>&1; then
    sc_ensure_dir "$plan_file" || return 1
    local _bpath _ts
    _bpath=$(sc_path "$plan_file" "$SC_BLOCKED")
    _ts=$(_iso_timestamp)
    _sc_rewrite_jsonl "$_bpath" \
      'if (.cleared_at == null and (.message | startswith($marker))) then .cleared_at = $ts else . end' \
      "clear-marker" \
      --arg marker "$marker" --arg ts "$_ts" || return 1
  fi
  local _tmp
  _tmp=$(mktemp "${plan_file}.XXXXXX")
  awk -v marker="$marker" '
    /^## Open Questions$/ { in_section=1; print; next }
    in_section && /^## / { in_section=0 }
    in_section && substr($0, 1, length(marker)) == marker { next }
    { print }
  ' "$plan_file" > "$_tmp" && mv "$_tmp" "$plan_file" || { rm -f "$_tmp"; return 1; }
}

cmd_clear_marker() {
  local plan_file="$1" marker="$2"
  require_file "$plan_file"
  local _rc=0
  _with_lock "${plan_file}" _cmd_clear_marker_body "$plan_file" "$marker" || _rc=$?
  if [[ $_rc -ne 0 ]]; then
    echo "[clear-marker] failed to clear '$marker' from $plan_file (rc=${_rc})" >&2
    return "$_rc"
  fi
  echo "[clear-marker] removed '$marker' from ## Open Questions in $plan_file" >&2
}

# cmd_unblock clears [BLOCKED*:agent:...] lines for the named agent.
# NOTE: BLOCKED-AMBIGUOUS lines are NOT cleared here — use cmd_clear_marker (Ring C).
cmd_unblock() {
  local agent="$1"
  _validate_critic_agent "$agent" "unblock"
  local plan_file
  plan_file=$(cmd_find_active) || die "unblock: no active plan found"
  if command -v jq >/dev/null 2>&1; then
    local _bpath _ts
    _bpath=$(sc_path "$plan_file" "$SC_BLOCKED")
    _ts=$(_iso_timestamp)
    _sc_rewrite_jsonl "$_bpath" \
      'if (.cleared_at == null and .kind != "ambiguous" and .agent == $agent) then .cleared_at = $ts else . end' \
      "unblock" \
      --arg agent "$agent" --arg ts "$_ts" || return 1
  fi
  _awk_inplace "$plan_file" -v agent="$agent" '
    /^## Open Questions$/ { in_section=1; print; next }
    in_section && /^## / { in_section=0 }
    in_section && /\[BLOCKED-AMBIGUOUS\]/ { print; next }
    in_section && /\[BLOCKED/ {
      _skip = 0
      if (match($0, /\[BLOCKED[^:]*:[^:]*:/)) {
        field = substr($0, RSTART, RLENGTH)
        sub(/^\[BLOCKED[^:]*:/, "", field); sub(/:$/, "", field)
        if (field == agent) _skip = 1
      }
      if (!_skip && /\[BLOCKED-CEILING\]/) {
        prefix = "[BLOCKED-CEILING] "
        if (substr($0, 1, length(prefix)) == prefix) {
          rest = substr($0, length(prefix) + 1)
          slash_pos = index(rest, "/")
          if (slash_pos > 0) {
            after_slash = substr(rest, slash_pos + 1)
            if (substr(after_slash, 1, length(agent)) == agent) {
              nxt = (length(after_slash) > length(agent)) ? substr(after_slash, length(agent)+1, 1) : ""
              if (nxt == "" || nxt == " " || nxt == ":") _skip = 1
            }
          }
        }
      }
      if (_skip) next
    }
    { print }
  '
  echo "[unblock] cleared [BLOCKED*] markers for '${agent}' in ${plan_file}" >&2
}

cmd_clear_converged() {
  local plan_file="$1" agent="$2"
  require_file "$plan_file"
  _validate_critic_agent "$agent" "clear-converged"
  local current_phase
  current_phase=$(_require_phase "$plan_file" "clear-converged")
  local scope; scope=$(_scope_of "$current_phase" "$agent")
  local ts
  ts=$(_iso_timestamp)
  _append_to_critic_verdicts "$plan_file" \
    "${ts} ${scope}: REJECT-PASS (audit-override — streak reset)"
  _sc_reset_convergence_for_scope "$plan_file" "$current_phase" "$agent"
  echo "[clear-converged] reset streak for ${scope}" >&2
}

cmd_reset_milestone() {
  local plan_file="$1" agent="$2"
  require_file "$plan_file"
  _validate_critic_agent "$agent" "reset-milestone"
  local current_phase
  current_phase=$(_require_phase "$plan_file" "reset-milestone")
  local scope; scope=$(_scope_of "$current_phase" "$agent")
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
  current_phase=$(_require_phase "$plan_file" "reset-pr-review")
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

cmd_reset_phase_state() {
  local plan_file="$1" target_phase="$2"
  require_file "$plan_file"
  [ -n "$target_phase" ] || die "reset-for-rollback: target-phase required"
  cmd_set_phase "$plan_file" "$target_phase"
  cmd_reset_milestone "$plan_file" critic-code
  cmd_reset_pr_review "$plan_file"
  _clear_convergence_markers "$plan_file" "review/critic-code"
  echo "[reset-for-rollback] phase set to ${target_phase}; critic-code and pr-review state cleared" >&2
}

# ── Task ledger / GC ──────────────────────────────────────────────────────────

cmd_add_task() {
  local plan_file="$1" task_id="$2" layer="$3"
  require_file "$plan_file"
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

cmd_record_task_completed() {
  require_jq
  local input task_id plan_file
  input=$(cat)
  task_id=$(printf '%s' "$input" | jq -r '.task_id // "unknown"' 2>/dev/null || echo "unknown")
  [[ "$task_id" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "[record-task-completed] invalid task_id: ${task_id}" >&2; exit 0; }
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

# ── Sidecar queries / migration ───────────────────────────────────────────────

cmd_gc_sidecars() {
  local plan_file="$1"
  require_file "$plan_file"
  command -v jq >/dev/null 2>&1 || { echo "[gc-sidecars] jq not available — skipping" >&2; return 0; }
  local vpath bpath
  vpath=$(sc_path "$plan_file" "$SC_VERDICTS")
  bpath=$(sc_path "$plan_file" "$SC_BLOCKED")

  if [[ -f "$vpath" ]] && [[ -s "$vpath" ]]; then
    local max_ms keep_from varchive
    max_ms=$(jq -r '.milestone_seq // 0' "$vpath" 2>/dev/null | sort -n | tail -1 || true)
    max_ms="${max_ms:-0}"
    if [[ "${max_ms}" -le 0 ]]; then
      echo "[gc-sidecars] verdicts.jsonl: only milestone_seq=0 — nothing to rotate" >&2
    else
      keep_from=$(( max_ms - 1 ))
      varchive=$(sc_path "$plan_file" "$SC_VERDICTS_ARCHIVE")
      if _sc_rotate_jsonl "$vpath" "$varchive" \
          'select((.milestone_seq // 0) >= $kf)' \
          'select((.milestone_seq // 0) < $kf)' \
          "gc-sidecars" --argjson kf "$keep_from"; then
        echo "[gc-sidecars] rotated verdicts.jsonl (kept milestone_seq >= ${keep_from})" >&2
      fi
    fi
  fi

  if [[ -f "$bpath" ]]; then
    local cutoff
    cutoff=$(date -u -d '30 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
             || date -u -v-30d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
    if [[ -n "$cutoff" ]]; then
      local barchive
      barchive=$(sc_path "$plan_file" "$SC_BLOCKED_ARCHIVE")
      if _sc_rotate_jsonl "$bpath" "$barchive" \
          'select(.cleared_at == null or .cleared_at >= $cut)' \
          'select(.cleared_at != null and .cleared_at < $cut)' \
          "gc-sidecars" --arg cut "$cutoff"; then
        echo "[gc-sidecars] rotated blocked.jsonl (archived cleared records older than 30d)" >&2
      fi
    else
      echo "[gc-sidecars] WARNING: neither GNU nor BSD date supports relative cutoff — skipping blocked.jsonl rotation" >&2
    fi
  fi
}

cmd_is_converged() {
  local plan_file="$1" phase="$2" agent="$3"
  require_file "$plan_file"
  if ! command -v jq >/dev/null 2>&1; then
    echo "[is-converged] jq required but not found — preflight should have blocked this run" >&2
    return 2
  fi
  local conv_path
  conv_path=$(sc_conv_path "$plan_file" "$phase" "$agent")
  if [[ ! -f "$conv_path" ]]; then
    echo "[is-converged] WARNING: sidecar convergence file absent — treating as not-converged (run migrate-to-sidecar if this is unexpected)" >&2
    return 1
  fi
  local converged
  converged=$(jq -r '.converged // false' "$conv_path" 2>/dev/null || echo false)
  [[ "$converged" == "true" ]]
}

cmd_is_blocked() {
  local plan_file="$1" kind="${2:-}"
  require_file "$plan_file"
  local _bpath
  _bpath=$(sc_path "$plan_file" "$SC_BLOCKED")
  if [[ ! -f "$_bpath" ]]; then
    echo "[is-blocked] WARNING: blocked.jsonl absent — treating as not-blocked (run migrate-to-sidecar if this is unexpected)" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "[is-blocked] jq required but not found — preflight should have blocked this run" >&2
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

cmd_is_implemented() {
  local plan_file="$1" feat_slug="$2"
  require_file "$plan_file"
  local impl_path
  impl_path=$(sc_path "$plan_file" "$SC_IMPLEMENTED")
  command -v jq >/dev/null 2>&1 || return 1
  if [[ ! -f "$impl_path" ]]; then
    echo "[is-implemented] WARNING: sidecar implemented.json absent — treating as not-implemented (run migrate-to-sidecar if this is unexpected)" >&2
    return 1
  fi
  local result
  result=$(jq -r --arg slug "$feat_slug" '.features | map(. == $slug) | any' "$impl_path" 2>/dev/null || echo false)
  [[ "$result" == "true" ]]
}

cmd_mark_implemented() {
  local plan_file="$1" feat_slug="$2"
  require_file "$plan_file"
  sc_ensure_dir "$plan_file" || die "ERROR: sidecar dir setup failed for $plan_file"
  require_jq
  local impl_path existing new_state
  impl_path=$(sc_path "$plan_file" "$SC_IMPLEMENTED")
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

cmd_migrate_to_sidecar() {
  local plan_file="$1"
  require_file "$plan_file"
  require_jq
  sc_ensure_dir "$plan_file" || die "ERROR: sidecar dir setup failed for $plan_file"
  local sentinel
  sentinel=$(sc_path "$plan_file" ".migrated_from_v2.txt")
  if [[ -f "$sentinel" ]]; then
    echo "[migrate-to-sidecar] already migrated: $plan_file" >&2
    return 0
  fi
  local conv_dir
  conv_dir=$(sc_path "$plan_file" "convergence")
  if ls "${conv_dir}"/*.json 2>/dev/null | grep -q .; then
    echo "[migrate-to-sidecar] BLOCKED: convergence files already exist in ${conv_dir} — migration refused to avoid overwriting authoritative sidecar state (use reset-milestone if a fresh start is needed)" >&2
    return 1
  fi
  local phase agent
  for phase in brainstorm spec red implement review; do
    for agent in critic-feature critic-spec critic-test critic-code critic-cross pr-review; do
      local scope; scope=$(_scope_of "$phase" "$agent")
      local converged=false ceiling_blocked=false streak_val=0
      if grep -qF "[CONVERGED] ${scope}" "$plan_file" 2>/dev/null; then
        converged=true; streak_val=2
      fi
      if grep -qF "[BLOCKED-CEILING] ${scope}" "$plan_file" 2>/dev/null; then
        ceiling_blocked=true
      fi
      if [[ "$converged" == "true" ]] || [[ "$ceiling_blocked" == "true" ]]; then
        local conv_path
        conv_path=$(sc_conv_path "$plan_file" "$phase" "$agent")
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
  impl_path=$(sc_path "$plan_file" "$SC_IMPLEMENTED")
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
  echo "$(_iso_timestamp): migrated from plan.md v2" > "$sentinel"
  echo "[migrate-to-sidecar] migration complete for $plan_file" >&2
}
