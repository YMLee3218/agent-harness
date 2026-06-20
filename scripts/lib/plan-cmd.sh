#!/usr/bin/env bash
# Merged plan-cmd: state / notes / verdicts / record-verdict / markers / tasks-gc / sidecar.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PLAN_CMD_LOADED:-}" ]] && return 0
_PLAN_CMD_LOADED=1

_PLAN_CMD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_PLAN_LIB_LOADED:-}" ]]          || . "$_PLAN_CMD_DIR/plan-lib.sh"
[[ -n "${_PLAN_LOOP_HELPERS_LOADED:-}" ]] || . "$_PLAN_CMD_DIR/plan-loop-helpers.sh"

# ── Severity-rule parsers (single-source from reference/severity.md) ─────────

_severity_categories() {
  local _sev; _sev="$(cd "${_PLAN_CMD_DIR}/../.." && pwd)/reference/severity.md"
  [[ -f "$_sev" ]] || { echo "[plan-cmd] WARN: severity.md not found at ${_sev}" >&2; return 0; }
  awk '
    /^## Category priority/ { in_section=1; next }
    in_section && /^```/ { if (in_fence) exit; in_fence=1; next }
    in_section && in_fence {
      gsub(/[^A-Z_]/, " ")
      for (i=1; i<=NF; i++) if ($i ~ /^[A-Z][A-Z_]+$/) printf "%s ", $i
    }
    in_section && !in_fence && /^## / { exit }
  ' "$_sev" 2>/dev/null | tr -s ' ' | sed 's/ *$//'
}

_severity_blocking_labels() {
  local _sev; _sev="$(cd "${_PLAN_CMD_DIR}/../.." && pwd)/reference/severity.md"
  [[ -f "$_sev" ]] || { echo "[plan-cmd] WARN: severity.md not found at ${_sev}" >&2; return 0; }
  awk -F'|' '
    /^## Severity levels/ { in_section=1; next }
    in_section && /^\|/ && NF>=5 {
      label=$3; blocking=$4
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", label)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", blocking)
      if (blocking == "Yes") {
        gsub(/[`]/, "", label)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", label)
        print label
      }
    }
    in_section && /^## / && !/^## Severity levels/ { exit }
  ' "$_sev" 2>/dev/null
}

# ── State management ──────────────────────────────────────────────────────────

cmd_init() {
  local plan_file="$1"
  local mode="${2:-}"
  local slug
  slug=$(basename "$plan_file" .md)
  if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
    die "cmd_init: plan slug '${slug}' contains illegal characters — must match ^[a-z0-9][a-z0-9_-]{0,63}$"
  fi
  # Validate path BEFORE mkdir to prevent stale directory creation on traversal paths.
  # sc_dir needs the parent dir to exist (uses cd to resolve), so we walk up to the
  # nearest existing ancestor to reconstruct the absolute path for a pre-check.
  # sc_dir re-validates via realpath after mkdir as defence-in-depth.
  local _git_root
  _git_root=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || _git_root=""
  # Only adopt git root if it is under CLAUDE_PROJECT_DIR (worktrees outside are not supported).
  [[ -n "$_git_root" && -n "${CLAUDE_PROJECT_DIR:-}" && "$_git_root/" == "${CLAUDE_PROJECT_DIR:-}/"* ]] || \
    _git_root="${CLAUDE_PROJECT_DIR:?cmd_init: CLAUDE_PROJECT_DIR required}"
  local _proj; _proj=$(cd "$_git_root" 2>/dev/null && pwd -P) \
      || die "cmd_init: project root is not a valid directory: ${_git_root}"
  local _pd _suffix="" _abs_pd=""
  _pd=$(dirname "$plan_file")
  while [[ "$_pd" != "/" && "$_pd" != "." ]]; do
    if _abs_pd=$(cd "$_pd" 2>/dev/null && pwd -P); then break; fi
    _suffix="/$(basename "$_pd")${_suffix}"
    _pd=$(dirname "$_pd")
  done
  [[ -z "$_abs_pd" ]] && _abs_pd=$(cd "${_pd:-.}" 2>/dev/null && pwd -P) || true
  [[ -z "$_abs_pd" ]] && die "ERROR: plan path '${plan_file}' — cannot resolve ancestor directory for path validation"
  case "${_abs_pd}${_suffix}/$(basename "$plan_file")" in
    "${_proj}/plans/"*.md) ;;
    *) die "ERROR: plan path '${plan_file}' is outside project plans/ — path-traversal rejected" ;;
  esac
  mkdir -p "$(dirname "$plan_file")"
  if ! sc_dir "$plan_file" > /dev/null; then
    rmdir "$(dirname "$plan_file")" 2>/dev/null || true
    die "ERROR: plan path '${plan_file}' is outside project plans/ — path-traversal rejected"
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
  {
    printf -- '---\nfeature: %s\nphase: brainstorm\nschema: 2\n' "$slug"
    [ -n "$mode" ] && printf 'mode: %s\n' "$mode"
    printf -- '---\n\n## Phase\nbrainstorm\n\n## Vision\n\n## Scenarios\n\n## Test Manifest\n\n## Phase Transitions\n- brainstorm → (initial)\n\n## Critic Verdicts\n\n## Task Ledger\n| task-id | layer | status | commit-sha |\n|---------|-------|--------|------------|\n## Integration Failures\n\n## Verdict Audits\n\n## Open Questions\n'
  } > "$plan_file"
  printf 'brainstorm' > "${plan_file%.md}.phase"
  sc_ensure_dir "$plan_file" || die "ERROR: sidecar dir setup failed for $plan_file"
}

cmd_get_phase() {
  local plan_file="$1"
  require_file "$plan_file"
  local phase_file="${plan_file%.md}.phase"
  local phase=""
  if [[ -f "$phase_file" ]]; then
    phase=$(cat "$phase_file" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' || true)
  else
    # Migration fallback: read from ## Phase body section
    phase=$(awk '/^## Phase$/{found=1; next} found && /^[A-Za-z]/{print; exit} found && /^##/{exit}' "$plan_file" \
            | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  fi
  if [ -z "$phase" ]; then
    echo "ERROR: phase not found — '${phase_file}' sidecar absent (schema 2: restore with printf '<phase>' > '${phase_file}'; legacy plans: check '## Phase' body section in $plan_file)" >&2
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
  printf '%s' "$phase" > "${plan_file%.md}.phase"
  # Stage .phase so the next commit always includes the authoritative phase value.
  local _repo_dir; _repo_dir="$(cd "$(dirname "$plan_file")" && pwd)"
  git -C "$_repo_dir" add "${plan_file%.md}.phase" 2>/dev/null || true
  # Mirror to plan.md frontmatter and body for human readability (non-authoritative)
  _awk_replace_phase_body "$plan_file" "$phase"
}

_read_phase_quick() {
  local pf="$1" p=""
  local _phf="${pf%.md}.phase"
  if [[ -f "$_phf" ]]; then
    p=$(cat "$_phf" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' || true)
  else
    # Migration fallback: read from ## Phase body section
    p=$(awk '/^## Phase$/{found=1; next} found && /^[A-Za-z]/{print; exit} found && /^##/{exit}' "$pf" 2>/dev/null \
      | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' || true)
  fi
  echo "$p"
}

cmd_find_active() {
  local _git_root
  _git_root=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || _git_root=""
  [[ -n "$_git_root" && -n "${CLAUDE_PROJECT_DIR:-}" && "$_git_root/" == "${CLAUDE_PROJECT_DIR:-}/"* ]] || _git_root="${CLAUDE_PROJECT_DIR:-$PWD}"

  local plans_dir="${_git_root}/plans"

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
      if [ -z "$envphase" ]; then
        echo "ERROR: CLAUDE_PLAN_FILE=$CLAUDE_PLAN_FILE exists but phase is unreadable — restore '${CLAUDE_PLAN_FILE%.md}.phase' sidecar (printf '<phase>' > '${CLAUDE_PLAN_FILE%.md}.phase'); for legacy plans check '## Phase' body section." >&2
        exit 4
      fi
    fi
  fi

  [ -d "$plans_dir" ] || { exit 2; }

  # branch slug matching
  local branch
  branch=$(git -C "$_git_root" symbolic-ref --short HEAD 2>/dev/null \
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
    local phase
    phase=$(_read_phase_quick "$f")
    if [ -z "$phase" ]; then
      echo "[plan-file] ERROR: plan file exists but phase cannot be read: $f (missing .phase file and ## Phase section)" >&2
      malformed=$((malformed + 1))
    elif [ "$phase" != "done" ]; then
      count=$((count + 1))
      [ -z "$found" ] && found="$f"
    fi
  done < <(find "$plans_dir" -maxdepth 1 -name '*.md' -print0 2>/dev/null | sort -z)
  if [ "$malformed" -gt 0 ]; then
    echo "ERROR: ${malformed} plan file(s) exist but phase is unreadable — create plans/{slug}.phase or repair the ## Phase section." >&2
    exit 4
  elif [ "$count" -eq 0 ]; then
    exit 2
  elif [ "$count" -ge 2 ]; then
    echo "ERROR: ${count} active plan files found with no CLAUDE_PLAN_FILE or branch-slug match. Set CLAUDE_PLAN_FILE=${plans_dir}/{slug}.md or align branch name with plan file name." >&2
    exit 3
  else
    echo "[plan-file] WARNING: falling back to only active plan ($found). Set CLAUDE_PLAN_FILE or use worktrees to disambiguate when running multiple features in parallel." >&2
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
  local _git_root
  _git_root=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || _git_root=""
  [[ -n "$_git_root" && -n "${CLAUDE_PROJECT_DIR:-}" && "$_git_root/" == "${CLAUDE_PROJECT_DIR:-}/"* ]] || _git_root="${CLAUDE_PROJECT_DIR:-$PWD}"
  local plans_dir="${_git_root}/plans"
  [ -d "$plans_dir" ] || return 2
  local f
  f=$(_find_latest_by_mtime "$plans_dir" '*.md' || true)
  [ -z "$f" ] && return 2
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
  local _repo_dir; _repo_dir="$(cd "$(dirname "$plan_file")" && pwd)"
  git -C "$_repo_dir" add "$_repo_dir/$(basename "$plan_file")"
  local _phase_file="${_repo_dir}/$(basename "${plan_file%.md}").phase"
  [[ -f "$_phase_file" ]] && git -C "$_repo_dir" add "$_phase_file" || true
  git -C "$_repo_dir" diff --cached --quiet || git -C "$_repo_dir" commit -m "$message"
}

# ── Notes / stop-block / context ──────────────────────────────────────────────

cmd_append_note() {
  local plan_file="$1" note="$2" _unit="${3:-}" _stage="${4:-}"
  # Ambient fallback: orchestrator phase-functions export CLAUDE_BLOCK_UNIT / CLAUDE_BLOCK_STAGE
  # around per-unit work so the ~50 scattered [BLOCKED:*] append-note sites emit unit-keyed
  # events block facts without each threading explicit args. Explicit args (run-critic-loop's
  # _an) take precedence; absent both → legacy plan.md/blocked.jsonl-only behaviour.
  [[ -z "$_unit"  ]] && _unit="${CLAUDE_BLOCK_UNIT:-}"
  [[ -z "$_stage" ]] && _stage="${CLAUDE_BLOCK_STAGE:-}"
  require_file "$plan_file"
  # [BLOCKED:transient] must never reach plan.md — route to sidecar transient counter only.
  if printf '%s' "${note:-}" | grep -qF '[BLOCKED:transient]'; then
    echo "[cmd_append_note] WARN: [BLOCKED:transient] note suppressed from plan.md — use _record_transient directly" >&2
    return 0
  fi
  local _kind=""
  if printf '%s' "${note:-}" | grep -qE '^\[BLOCKED:'; then
    _kind=$(printf '%s' "$note" | sed -n 's/^\[BLOCKED:\([a-z]*\)\].*/\1/p')
    case "${_kind:-}" in
      envelope|docs|spec|code|env|harness|ceiling) ;;
      *)
        echo "[cmd_append_note] WARN: unrecognized BLOCKED kind '${_kind:-empty}' — refusing to write marker" >&2
        return 1
        ;;
    esac
  fi
  # Idempotency: skip if exact same [BLOCKED:*] marker already present in ## Open Questions.
  if [[ -n "$_kind" ]]; then
    local _oq_section
    _oq_section=$(awk '/^## Open Questions$/{s=1;next} s&&/^## /{s=0} s{print}' "$plan_file" 2>/dev/null) || _oq_section=""
    if printf '%s\n' "$_oq_section" | grep -qxF -- "$note"; then
      echo "[cmd_append_note] INFO: duplicate [BLOCKED:${_kind}] marker suppressed" >&2
      return 0
    fi
  fi
  if [[ -n "$_kind" ]] && command -v jq >/dev/null 2>&1; then
    sc_ensure_dir "$plan_file" || return 1
    local _agent; _agent=$(printf '%s' "$note" | sed -n 's/^\[BLOCKED:[a-z]*\] \([^ :]*\).*/\1/p')
    [[ -z "$_agent" ]] && _agent="harness"
    if ! _record_blocked "$plan_file" "$_kind" "$_agent" "$(basename "$plan_file" .md)" "$note"; then
      echo "[append-note] FATAL: blocked.jsonl write failed — plan.md NOT marked" >&2
      return 2
    fi
    # Group-additive: emit the unit-keyed block fact ALONGSIDE legacy blocked.jsonl when the
    # caller threaded a unit + stage. ceiling kind is NOT an events block fact (count-derived
    # predicate, invariant 10); transient already returned above. Dedup is invariant-3.
    if [[ -n "$_unit" && -n "$_stage" && "$_kind" != "ceiling" ]]; then
      ev_record_block "$plan_file" "$_unit" "$_stage" "$_kind" "$note" 2>/dev/null || true
    fi
  fi
  _append_to_open_questions "$plan_file" "$note"
}

cmd_record_stop_block() {
  local plan_file="$1" phase="$2" reason="$3"
  require_file "$plan_file"
  sc_dir "$plan_file" > /dev/null
  local ts
  ts=$(_iso_timestamp)
  _append_to_open_questions "$plan_file" \
    "[STOP-BLOCKED @${ts}] phase=${phase} — ${reason}"
  echo "[record-stop-block] recorded stop block (phase=${phase}): ${reason}" >&2
}

cmd_context() {
  require_jq
  local plan_file="${1:-}"
  if [ -z "$plan_file" ]; then
    plan_file=$(cmd_find_active 2>/dev/null) || exit 0
  fi

  local phase
  phase=$(_require_phase "$plan_file" "cmd_context") || exit 0

  local verdicts
  verdicts=$(awk '/^## Critic Verdicts$/{found=1; next} found && /^## /{found=0} found && /^- /{print}' \
    "$plan_file" 2>/dev/null | tail -3 | sed 's/^- //' | tr '\n' '|' | sed 's/|$//' || echo "none")

  local blocked_items other_items questions
  blocked_items=$(awk '/^## Open Questions$/{found=1; next} found && /^## /{found=0} found && (/\[BLOCKED/ || /\[STOP-BLOCKED/){print}' \
    "$plan_file" 2>/dev/null | head -3 | tr '\n' '|' | sed 's/|$//' || true)
  other_items=$(awk '/^## Open Questions$/{found=1; next} found && /^## /{found=0} found && /[^[:space:]]/ && !/\[BLOCKED/ && !/\[STOP-BLOCKED/ && !/\[IMPLEMENTED/{print}' \
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

# _dispatch_rls_rc PLAN LABEL RC [PHASE AGENT] — dispatches _record_loop_state failure codes; always exits 1.
# rc=1: CEILING (Open Questions + sidecar already written by _ceiling_block — add Critic Verdicts trace).
# rc=2/4: ordinal/append failure — no prior _record_blocked_runtime; write Open Questions + sidecar now.
# rc=3: _compute_streak failure — _record_blocked_runtime already called in _compute_streak; skip to avoid duplicate.
_dispatch_rls_rc() {
  local _plan="$1" _label="$2" _rc="$3" _phase="${4:-}" _agent="${5:-}"
  if [[ $_rc -eq 1 ]]; then
    echo "[record-verdict] [BLOCKED:ceiling]: ${_label}" >&2
    cmd_append_verdict "$_plan" "[BLOCKED:ceiling] ${_label}"
  else
    echo "[record-verdict] BLOCKED (rc=${_rc}): ${_label} not persisted" >&2
    if [[ -n "$_phase" ]] && [[ -n "$_agent" ]] && [[ $_rc -ne 3 ]]; then
      local _scope; _scope=$(_scope_of "$_phase" "$_agent")
      _record_blocked_runtime "$_plan" "$_agent" "$_scope" \
        "runtime failure (rc=${_rc}) persisting verdict — sidecar may need manual inspection"
    fi
    cmd_append_verdict "$_plan" "[BLOCKED:harness] sidecar: runtime — ${_label}"
  fi
  exit 1
}

# _check_consecutive_and_block PLAN PHASE AGENT JQ_PREV_QUERY MATCH_VAL KIND MSG LOG_LABEL
_check_consecutive_and_block() {
  local plan_file="$1" phase="$2" agent="$3"
  local jq_prev_query="$4" match_val="$5" kind="$6" msg="$7" log_label="$8"
  local _unit="${9:-}"
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
        "corrupt verdicts.jsonl — jq failed in consecutive check; fix manually (delete or repair the file)"
      return 2
    fi
  fi
  if [[ -n "$_prev_val" ]] && [[ "$_prev_val" == "$match_val" ]]; then
    if [[ "$kind" == "category" ]]; then
      # Non-halting feedforward: remove any prior RECURRING marker (self-supersede, max 1 per agent)
      # and write a new advisory. No blocked.jsonl entry — loop continues normally.
      cmd_clear_marker "$plan_file" "[RECURRING] ${agent}:"
      _append_to_open_questions "$plan_file" "[RECURRING] ${agent}: ${msg}"
      echo "[record-verdict] ${log_label}" >&2
      return 1
    else
      # parse (and any future kinds): hard block — write [BLOCKED:code] and stop the loop.
      if ! _record_blocked "$plan_file" "code" "$agent" "$_scope" "$msg"; then
        echo "[record-verdict] FATAL: blocked.jsonl write failed for ${log_label} — plan.md NOT marked" >&2
        return 2
      fi
      # Group-additive: unit-keyed block fact (channel G). Stage derived from the agent.
      [[ -n "$_unit" ]] && ev_record_block "$plan_file" "$_unit" "$(_ev_stage_of_agent "$agent")" "code" "$msg" 2>/dev/null || true
      _append_to_open_questions "$plan_file" "[BLOCKED:code] ${agent}: ${kind} — ${msg}"
      echo "[record-verdict] ${log_label}" >&2
      return 0
    fi
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
    ACCEPT|ACCEPT-OVERRIDE|REJECT-PASS|BLOCKED-AMBIGUOUS) ;;
    *) die "append-audit: invalid outcome '${outcome}'. Must be ACCEPT, ACCEPT-OVERRIDE, REJECT-PASS, or BLOCKED-AMBIGUOUS" ;;
  esac
  local ts
  ts=$(_iso_timestamp)
  _append_to_verdict_audits "$plan_file" "- ${ts} ${agent} ${outcome}: ${summary}"
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
  local _unit="${7:-}" _input_hash="${8:-}"
  echo "[record-verdict] ${log_msg}" >&2
  local _hpe_rc=0
  _record_loop_state "$plan_file" "$current_phase" "$agent" "PARSE_ERROR" "" "$_unit" "$_input_hash" || _hpe_rc=$?
  [[ $_hpe_rc -ne 0 ]] && _dispatch_rls_rc "$plan_file" "${current_phase}/${agent}: PARSE_ERROR" "$_hpe_rc" "$current_phase" "$agent"
  local _ccb_parse_rc=0
  _check_consecutive_and_block "$plan_file" "$current_phase" "$agent" \
      '[.[] | select(.phase == $p and .agent == $a and .milestone_seq == $ms)] | .[-2].verdict // ""' \
      "PARSE_ERROR" "parse" "$block_msg" \
      "BLOCKED parse: ${agent} two consecutive PARSE_ERRORs" \
      "$_unit" || _ccb_parse_rc=$?
  case $_ccb_parse_rc in
    0) : ;;
    1) echo "[record-verdict] ${retry_msg}" >&2
       cmd_append_verdict "$plan_file" "${current_phase}/${agent}: PARSE_ERROR" ;;
    2) cmd_append_verdict "$plan_file" "[BLOCKED:harness] sidecar: corrupt-check — ${current_phase}/${agent}: PARSE_ERROR" ;;
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
      if [ "$_transcript_size" -gt "$_size_warn" ]; then
        echo "[record-verdict] WARN: agent_transcript size ${_transcript_size} bytes — reading last 1MB only" >&2
        out=$(tail -c 1048576 "$_safe_path" | tail -n +2 | \
          jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="text")|.text//empty' \
          2>/dev/null || true)
      else
        out=$(jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="text")|.text//empty' \
          < "$_safe_path" 2>/dev/null || true)
      fi
    }
  fi
  if [ -z "$out" ] && [ -n "$transcript" ]; then
    _safe_path=$(_is_safe_transcript_path "$transcript") && [ -f "$_safe_path" ] && {
      _transcript_size=$(wc -c < "$_safe_path" 2>/dev/null || echo 0)
      if [ "$_transcript_size" -gt "$_size_warn" ]; then
        echo "[record-verdict] WARN: transcript size ${_transcript_size} bytes — reading last 1MB only" >&2
        out=$(tail -c 1048576 "$_safe_path" | tail -n +2 | \
          jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="text")|.text//empty' \
          2>/dev/null | tail -200 || true)
      else
        out=$(jq -r 'select(.type=="assistant")|.message.content[]?|select(.type=="text")|.text//empty' \
          < "$_safe_path" 2>/dev/null | tail -200 || true)
      fi
    }
  fi
  [ -z "$out" ] && out=$(printf '%s' "$input" | jq -r '.last_assistant_message // ""' 2>/dev/null || echo "")
  printf '%s' "$out"
}

_resolve_plan_for_verdict() {
  local _agent="$1" _find_rc=0
  plan_file=$(cmd_find_active) || _find_rc=$?
  if [ "$_find_rc" -ne 0 ]; then
    echo "[record-verdict] cmd_find_active rc=${_find_rc} — verdict for ${_agent} dropped" >&2
    exit 0
  fi
  current_phase=$(_require_phase "$plan_file" "record-verdict") || exit $?
}

_extract_or_handle_missing_verdict() {
  local _output="$1" _input="$2" _plan="$3" _phase="$4" _agent="$5" _pvm_out
  _pvm_out=$(_parse_verdict_message "$_output")
  IFS='|' read -r verdict category <<< "$_pvm_out"
  if [ -z "$verdict" ]; then
    # Infrastructure failure detection: classify as [BLOCKED:env] instead of PARSE_ERROR when
    # output is empty (subagent never ran) or contains known infra-failure signatures.
    local _infra_detail=""
    if [ -z "$_output" ]; then
      _infra_detail="no subagent output"
    elif printf '%s' "$_output" | grep -qE \
        '(Unknown skill|ERROR:[[:space:]]+[a-z-]+ must be invoked via|=== CODEX-INFRA-FAILURE:|=== Codex [a-z-]+ exit: [1-9])'; then
      _infra_detail=$(printf '%s' "$_output" | \
        grep -E '(Unknown skill|ERROR:[[:space:]]+[a-z-]+ must be invoked via|=== CODEX-INFRA-FAILURE:|=== Codex [a-z-]+ exit: [1-9])' \
        | head -1 | cut -c1-120 || echo "infrastructure signature detected")
    fi
    if [ -n "$_infra_detail" ]; then
      if ! _record_blocked "$_plan" "env" "$_agent" "$(basename "$_plan" .md)" \
          "critic-skill-not-run — ${_infra_detail}"; then
        echo "[record-verdict] FATAL: blocked.jsonl write failed for [BLOCKED:env] ${_agent}: critic-skill-not-run — plan.md NOT marked" >&2
        exit 2
      fi
      _append_to_open_questions "$_plan" "[BLOCKED:env] ${_agent}: critic-skill-not-run — ${_infra_detail}"
      echo "[record-verdict] [BLOCKED:env] ${_agent}: critic-skill-not-run — ${_infra_detail}" >&2
      exit 1
    fi
    printf '%s' "$_output" | grep -qE 'Verdict:\s*(PASS|FAIL)|\*\*Verdict:\s*(PASS|FAIL)\*\*' && \
      _handle_parse_error "$_plan" "$_phase" "$_agent" \
        "textual verdict format (not HTML markers) from ${_agent}" \
        "verdict marker missing (two consecutive parse errors) — check agent output format before retrying" \
        "first PARSE_ERROR for ${_agent} (textual verdict format) — will retry automatically"
    printf '%s' "$_output" | grep -qE '### Verdict|<!-- verdict:' || \
      _handle_parse_error "$_plan" "$_phase" "$_agent" \
        "no verdict section in transcript for ${_agent}" \
        "verdict marker missing (two consecutive parse errors) — check agent output format before retrying" \
        "first PARSE_ERROR for ${_agent} (no verdict section) — will retry automatically"
    local _keys; _keys=$(printf '%s' "$_input" | jq -r 'keys | join(", ")' 2>/dev/null || echo "unknown")
    _handle_parse_error "$_plan" "$_phase" "$_agent" \
      "missing verdict marker from ${_agent} (payload keys: ${_keys})" \
      "verdict marker missing (two consecutive parse errors) — check agent output format before retrying" \
      "first PARSE_ERROR for ${_agent} — will retry automatically"
  fi
  if [ "$verdict" != "PASS" ] && [ "$verdict" != "FAIL" ]; then
    _handle_parse_error "$_plan" "$_phase" "$_agent" \
      "unknown verdict token '${verdict}' from ${_agent} — expected PASS or FAIL" \
      "unknown verdict token (two consecutive parse errors) — check agent output format before retrying" \
      "first PARSE_ERROR for ${_agent} (unknown verdict token '${verdict}') — will retry automatically"
  fi
  [ "$verdict" = "FAIL" ] && [ -z "$category" ] && \
    _handle_parse_error "$_plan" "$_phase" "$_agent" \
      "FAIL without category from ${_agent} — treating as PARSE_ERROR" \
      "FAIL without category (two consecutive parse errors) — check agent output format" \
      "first FAIL-without-category for ${_agent} — will retry automatically"
  # Guard: category must be in severity.md enum (fail-open if severity.md unparseable)
  if [ "$verdict" = "FAIL" ] && [ -n "$category" ]; then
    local _valid_cats; _valid_cats=$(_severity_categories)
    if [ -n "$_valid_cats" ]; then
      local _cat_found=0 _c
      for _c in $_valid_cats; do
        [ "$_c" = "$category" ] && { _cat_found=1; break; }
      done
      [ "$_cat_found" -eq 0 ] && \
        _handle_parse_error "$_plan" "$_phase" "$_agent" \
          "invalid category '${category}' from ${_agent} — not in severity.md enum; treating as PARSE_ERROR" \
          "invalid category (two consecutive parse errors) — check agent output format" \
          "first invalid-category PARSE_ERROR for ${_agent} — will retry automatically"
    else
      echo "[record-verdict] WARN: severity.md category list empty — skipping enum check for ${_agent}" >&2
    fi
  fi
  # Guard: PASS must carry category NONE (or no category marker at all).
  if [ "$verdict" = "PASS" ] && [ -n "$category" ] && [ "$category" != "NONE" ]; then
    _handle_parse_error "$_plan" "$_phase" "$_agent" \
      "PASS with non-NONE category '${category}' from ${_agent} — treating as PARSE_ERROR" \
      "PASS with non-NONE category (two consecutive parse errors) — check agent output format" \
      "first PASS-with-non-NONE-category PARSE_ERROR for ${_agent} — will retry automatically"
  fi
  # Guard: FAIL must have at least one blocking-label finding (fail-open if severity.md unparseable)
  if [ "$verdict" = "FAIL" ]; then
    local _sev_path; _sev_path="$(cd "${_PLAN_CMD_DIR}/../.." && pwd)/reference/severity.md"
    if [[ -f "$_sev_path" ]]; then
      local _blocking_found=0 _bl
      while IFS= read -r _bl; do
        [[ -z "$_bl" ]] && continue
        printf '%s' "$_output" | grep -qF "$_bl" && { _blocking_found=1; break; }
      done < <(_severity_blocking_labels)
      [ "$_blocking_found" -eq 0 ] && \
        _handle_parse_error "$_plan" "$_phase" "$_agent" \
          "FAIL without blocking finding from ${_agent} (no blocking label in output) — treating as PARSE_ERROR" \
          "FAIL without blocking finding (two consecutive parse errors) — check agent output format" \
          "first FAIL-without-blocking-finding for ${_agent} — will retry automatically"
    else
      echo "[record-verdict] WARN: severity.md not found — skipping blocking-finding check for ${_agent}" >&2
    fi
  fi
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
  _output=$(_resolve_output "$_input" "$_agent_transcript" "$_transcript")
  _extract_or_handle_missing_verdict "$_output" "$_input" "$plan_file" "$current_phase" "$agent_name"
}

_persist_verdict() {
  local _plan="$1" _phase="$2" _agent="$3" _verdict="$4" _category="$5" _output="${6:-}"
  local _unit="${7:-}" _input_hash="${8:-}"
  local _label="${_phase}/${_agent}: ${_verdict}"
  [ -n "$_category" ] && _label="${_label} [category: ${_category}]"
  local _rls_rc=0
  _record_loop_state "$_plan" "$_phase" "$_agent" "$_verdict" "$_category" "$_unit" "$_input_hash" || _rls_rc=$?
  [[ $_rls_rc -ne 0 ]] && _dispatch_rls_rc "$_plan" "$_label" "$_rls_rc" "$_phase" "$_agent"
  if [ "$_verdict" = "FAIL" ] && [ -n "$_category" ]; then
    local _ccb_rc=0
    _check_consecutive_and_block "$_plan" "$_phase" "$_agent" \
      '[.[] | select(.phase == $p and .agent == $a and .milestone_seq == $ms and .verdict != "PARSE_ERROR")] | .[-2] | select(.verdict == "FAIL") | .category // ""' \
      "$_category" "category" \
      "${_category} flagged 2× consecutively — next fix must resolve the root cause behind every ${_category} finding, not only the latest" \
      "consecutive same-category FAIL (${_category}) from ${_agent} — feedforward note written" \
      "$_unit" || _ccb_rc=$?
    case $_ccb_rc in
      1) : ;;
      2) cmd_append_verdict "$_plan" "[BLOCKED:harness] sidecar: corrupt-check — ${_label}"; exit 1 ;;
    esac
  fi
  cmd_append_verdict "$_plan" "$_label"
  echo "[record-verdict] verdict appended: ${_label}" >&2
  [ "$_verdict" = "FAIL" ] && exit 1 || exit 0
}

cmd_record_verdict() {
  require_jq
  local input; input=$(cat)
  local plan_file agent_name current_phase verdict category _output
  _resolve_verdict_payload "$input"
  # Transcript-driven (hook) path: no CLI unit/hash. critic-feature's run-critic-loop exports
  # CLAUDE_VERDICT_UNIT / CLAUDE_VERDICT_INPUT_HASH so the events fact is keyed correctly.
  _persist_verdict "$plan_file" "$current_phase" "$agent_name" "$verdict" "$category" "$_output" \
    "${CLAUDE_VERDICT_UNIT:-}" "${CLAUDE_VERDICT_INPUT_HASH:-}"
}

cmd_record_verdict_direct() {
  local plan_file="$1" agent="$2" phase="$3" verdict="$4" category="${5:-}"
  local _unit="${6:-}" _input_hash="${7:-}"
  require_file "$plan_file"
  _validate_critic_agent "$agent" "record-verdict-direct"

  local current_phase="$phase"

  case "$verdict" in
    PASS|FAIL|PARSE_ERROR) ;;
    *) die "record-verdict-direct: invalid verdict '$verdict'" ;;
  esac

  if [[ "$verdict" == "PARSE_ERROR" ]]; then
    _handle_parse_error "$plan_file" "$current_phase" "$agent" \
      "PARSE_ERROR (no verdict markers in codex output) for ${agent}" \
      "verdict marker missing (two consecutive parse errors) — check codex output format before retrying" \
      "first PARSE_ERROR for ${agent} — will retry automatically" \
      "$_unit" "$_input_hash"
    return
  fi

  if [[ "$verdict" == "FAIL" && -z "$category" ]]; then
    _handle_parse_error "$plan_file" "$current_phase" "$agent" \
      "FAIL without category from ${agent} (shell-driven path)" \
      "FAIL without category (two consecutive parse errors) — check codex output format" \
      "first FAIL-without-category for ${agent} — will retry automatically" \
      "$_unit" "$_input_hash"
    return
  fi

  if [[ "$verdict" == "PASS" && -n "$category" && "$category" != "NONE" ]]; then
    _handle_parse_error "$plan_file" "$current_phase" "$agent" \
      "PASS with non-NONE category '${category}' from ${agent} (shell-driven path)" \
      "PASS with non-NONE category (two consecutive parse errors)" \
      "first PASS-with-non-NONE-category for ${agent} — will retry automatically" \
      "$_unit" "$_input_hash"
    return
  fi

  if [[ "$verdict" == "FAIL" && -n "$category" ]]; then
    local _valid_cats _cat_found=0 _c
    _valid_cats=$(_severity_categories)
    if [[ -n "$_valid_cats" ]]; then
      for _c in $_valid_cats; do
        [[ "$_c" == "$category" ]] && { _cat_found=1; break; }
      done
      [[ "$_cat_found" -eq 0 ]] && \
        _handle_parse_error "$plan_file" "$current_phase" "$agent" \
          "invalid category '${category}' from ${agent} (shell-driven path) — not in severity.md enum" \
          "invalid category (two consecutive parse errors) — check codex output format" \
          "first invalid-category PARSE_ERROR for ${agent} — will retry automatically" \
          "$_unit" "$_input_hash"
    fi
  fi

  local _final_cat="$category"
  [[ "$_final_cat" == "NONE" ]] && _final_cat=""
  _persist_verdict "$plan_file" "$current_phase" "$agent" "$verdict" "$_final_cat" "" "$_unit" "$_input_hash"
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
      if ! _record_blocked "$_plan" "harness" "$_agent" "$(basename "$_plan" .md)" \
          "protocol-violation — invoked outside run-critic-loop.sh context"; then
        echo "[record-verdict-guarded] FATAL: blocked.jsonl write failed — plan.md NOT marked" >&2
        exit 2
      fi
      _append_to_open_questions "$_plan" \
        "[BLOCKED:harness] ${_agent}: protocol-violation — invoked outside run-critic-loop.sh context"
    fi
    echo "[record-verdict-guarded] BLOCKED: ${_agent} ran outside run-critic-loop.sh" >&2
    exit 2
  fi
  printf '%s' "$_input" | cmd_record_verdict
}

# ── Markers / reset ───────────────────────────────────────────────────────────

_cmd_clear_marker_body() {
  local plan_file="$1" marker="$2"
  local _candidate_lines
  _candidate_lines=$(awk -v marker="$marker" '
    /^## Open Questions$/ { in_section=1; next }
    in_section && /^## / { in_section=0 }
    in_section && substr($0, 1, length(marker)) == marker { print }
  ' "$plan_file" 2>/dev/null || true)
  if command -v jq >/dev/null 2>&1; then
    sc_ensure_dir "$plan_file" || return 1
    local _bpath _ts _stripped_marker
    _bpath=$(sc_path "$plan_file" "$SC_BLOCKED")
    _ts=$(_iso_timestamp)
    # _record_blocked strips [BLOCKED...] prefix; reconstruct kind:agent: prefix for category/parse entries.
    _stripped_marker=$(printf '%s' "$marker" | sed 's/^\[BLOCKED:[a-z]*\][[:space:]]*//')
    _sc_rewrite_jsonl "$_bpath" \
      'if (.cleared_at == null and (
         ((.message // "") | startswith($marker)) or
         ((.message // "") | startswith($stripped)) or
         ((.kind + ":" + .agent + ": " + (.message // "")) | startswith($stripped))
       )) then .cleared_at = $ts else . end' \
      "clear-marker" \
      --arg marker "$marker" --arg stripped "$_stripped_marker" --arg ts "$_ts" || return 1
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

# cmd_unblock clears all human-must-clear [BLOCKED:{kind}] lines from ## Open Questions.
# No agent argument — clears all 7 human-must kinds at once (Ring C gated).
# [BLOCKED:transient] is intentionally excluded — it has auto lifecycle.
cmd_unblock() {
  local _explicit="${1:-}"
  local plan_file
  if [[ -n "$_explicit" ]]; then
    plan_file="$_explicit"
    [[ -f "$plan_file" ]] || die "unblock: plan file not found: $plan_file"
  else
    plan_file=$(cmd_find_active) || die "unblock: no active plan found"
  fi
  if command -v jq >/dev/null 2>&1; then
    local _bpath _ts
    _bpath=$(sc_path "$plan_file" "$SC_BLOCKED")
    _ts=$(_iso_timestamp)
    local _ceiling_scopes=()
    if [[ -f "$_bpath" ]]; then
      while IFS= read -r _s; do
        [[ -n "$_s" ]] && _ceiling_scopes+=("$_s")
      done < <(jq -r 'select(.cleared_at == null and .kind == "ceiling") | .scope' "$_bpath" 2>/dev/null || true)
    fi
    # SYNC: HUMAN_MUST_CLEAR_MARKERS in phase-policy.sh has same 7 kinds — update both together.
    _sc_rewrite_jsonl "$_bpath" \
      'if (.cleared_at == null and (.kind | IN("envelope","docs","spec","code","env","harness","ceiling"))) then .cleared_at = $ts else . end' \
      "unblock" --arg ts "$_ts" || return 1
    for _scope in "${_ceiling_scopes[@]+"${_ceiling_scopes[@]}"}"; do
      local _cp_phase="${_scope%%/*}" _cp_agent="${_scope##*/}"
      local _cpath; _cpath=$(sc_conv_path "$plan_file" "$_cp_phase" "$_cp_agent" 2>/dev/null) || continue
      [[ -f "$_cpath" ]] || continue
      local _cs; _cs=$(jq '.ceiling_blocked = false' "$_cpath" 2>/dev/null) \
        || { echo "[unblock] WARN: jq read failed for ${_cpath} — ceiling_blocked may remain true" >&2; continue; }
      sc_update_json "$_cpath" "$_cs" 2>/dev/null \
        || echo "[unblock] WARN: failed to write ceiling_blocked=false to ${_cpath}" >&2
    done
  fi
  local _count=0 _m
  while IFS= read -r _m; do
    [[ -n "$_m" ]] || continue
    cmd_clear_marker "$plan_file" "$_m"
    _count=$((_count + 1))
  done < <(awk '
    /^## Open Questions$/ { s=1; next }
    s && /^## /           { exit }
    s && /^\[BLOCKED:(envelope|docs|spec|code|env|harness|ceiling)\]/ { print }
  ' "$plan_file" 2>/dev/null || true)
  # Events model: append human-clear facts so ev-blocked / ev-ceiling recompute as cleared.
  # This is what actually unblocks an events-keyed stage (the legacy sidecar above is dead).
  ev_unblock_all "$plan_file" 2>/dev/null || true
  echo "[unblock] cleared ${_count} markers in ${plan_file}" >&2
}

cmd_reset_milestone() {
  local plan_file="$1" agent="$2"
  require_file "$plan_file"
  _validate_critic_agent "$agent" "reset-milestone"
  local current_phase
  current_phase=$(_require_phase "$plan_file" "reset-milestone")
  local scope; scope=$(_scope_of "$current_phase" "$agent")
  # Convergence streak/ceiling are recomputed from the events log; the legacy sidecar writes were
  # dead. Keep the transient-counter clear (live) and the human-facing marker clears below.
  _clear_transient_for "$plan_file" "$agent" 2>/dev/null || true
  local ts
  ts=$(_iso_timestamp)
  _append_to_critic_verdicts "$plan_file" \
    "[MILESTONE-BOUNDARY @${ts}] ${scope}:"
  cmd_clear_marker "$plan_file" "[BLOCKED:ceiling] ${agent}:"
  cmd_clear_marker "$plan_file" "[RECURRING] ${agent}:"
  echo "[reset-milestone] cleared convergence markers and added milestone boundary for ${scope}" >&2
}

cmd_reset_pr_review() {
  local plan_file="$1"
  require_file "$plan_file"
  local current_phase
  current_phase=$(_require_phase "$plan_file" "reset-pr-review")
  local ts
  ts=$(_iso_timestamp)
  _append_to_critic_verdicts "$plan_file" \
    "[MILESTONE-BOUNDARY @${ts}] implement/critic-quality:"
  _clear_transient_for "$plan_file" "critic-quality" 2>/dev/null || true
  cmd_clear_marker "$plan_file" "[RECURRING] critic-quality:"
  cmd_clear_marker "$plan_file" "[BLOCKED:ceiling] critic-quality:"
  echo "[reset-pr-review] cleared critic-quality convergence marker for implement phase" >&2
}

cmd_reset_phase_state() {
  local plan_file="$1" target_phase="$2"
  require_file "$plan_file"
  [ -n "$target_phase" ] || die "reset-for-rollback: target-phase required"
  # Convergence/ceiling are recomputed from the events log (the per-scope sidecar reset loop was
  # dead). Keep the human-facing marker clears and the transient-counter reset (both live).
  cmd_reset_pr_review "$plan_file"
  cmd_clear_marker "$plan_file" "[BLOCKED:ceiling] critic-code:"
  cmd_clear_marker "$plan_file" "[RECURRING] critic-code:"
  cmd_clear_marker "$plan_file" "[BLOCKED:ceiling] critic-quality:"
  cmd_clear_marker "$plan_file" "[RECURRING] critic-quality:"
  _reset_all_transient_counters "$plan_file" 2>/dev/null || true
  cmd_set_phase "$plan_file" "$target_phase"
  echo "[reset-for-rollback] phase set to ${target_phase}; all critic convergence and quality-review state cleared" >&2
}

# ── Task ledger / GC ──────────────────────────────────────────────────────────

# Task state is an append-only events fact-log (events/__tasks__.jsonl); the ## Task Ledger
# markdown table is a read-only RENDERED VIEW regenerated from the fold after every write, so
# all existing table readers (scheduler, merge-gate, dev-cycle gates) keep working unchanged.

# _tasks_backfill_if_needed PLAN — one-time seed of the events log from a pre-existing markdown
# ledger (in-flight plans / fresh checkout where __tasks__.jsonl is absent but the committed
# table has rows). No-op once the events log exists (it is then authoritative). Prevents the
# first render-from-empty-fold from wiping committed task history (invariant 5/1a).
_tasks_backfill_if_needed() {
  local plan_file="$1" _path
  _path=$(ev_file "$plan_file" "__tasks__" 2>/dev/null) || return 0
  [[ -f "$_path" ]] && return 0
  awk '/^## Task Ledger$/{s=1;next} s&&/^## /{s=0} s&&/^\| / {
        n=split($0,f,"|"); if(n>=5){
          id=f[2]; gsub(/^[ \t]+|[ \t]+$/,"",id)
          if(id=="task-id"||id ~ /^-+$/||id=="") next
          tier=f[3]; gsub(/^[ \t]+|[ \t]+$/,"",tier)
          st=f[4];   gsub(/^[ \t]+|[ \t]+$/,"",st)
          sha=f[5];  gsub(/^[ \t]+|[ \t]+$/,"",sha)
          print id"\t"tier"\t"st"\t"sha
        }
      }' "$plan_file" 2>/dev/null | while IFS=$'\t' read -r _id _tier _st _sha; do
    [[ -n "$_id" ]] && ev_record_task "$plan_file" "$_id" "$_tier" "$_st" "${_sha:--}"
  done
}

# _render_task_ledger PLAN — regenerate the read-only ## Task Ledger view from the events fold.
_render_task_ledger() {
  local plan_file="$1" _body
  grep -q "^## Task Ledger$" "$plan_file" || printf '\n## Task Ledger\n' >> "$plan_file"
  _body=$(ev_tasks_fold "$plan_file" | while IFS=$'\t' read -r _id _tier _st _sha; do
    [[ -n "$_id" ]] && printf '| %s | %s | %s | %s |\n' "$_id" "$_tier" "$_st" "${_sha:--}"
  done)
  # Pass the multi-line body via the environment (awk -v cannot carry literal newlines).
  export _RENDER_BODY="$_body"
  _awk_inplace "$plan_file" '
    /^## Task Ledger$/ {
      print
      print "| task-id | layer | status | commit-sha |"
      print "|---------|-------|--------|------------|"
      if (ENVIRON["_RENDER_BODY"] != "") print ENVIRON["_RENDER_BODY"]
      insec=1; next
    }
    insec && /^## / { insec=0; print; next }
    insec { next }
    { print }
  '
  unset _RENDER_BODY
}

cmd_add_task() {
  local plan_file="$1" task_id="$2" layer="$3"
  require_file "$plan_file"
  _tasks_backfill_if_needed "$plan_file"
  # idempotent: skip if this task_id is already active in the fold
  ev_tasks_fold "$plan_file" | cut -f1 | grep -qxF "$task_id" && return 0
  ev_record_task "$plan_file" "$task_id" "$layer" pending "-"
  _render_task_ledger "$plan_file"
}

cmd_update_task() {
  local plan_file="$1" task_id="$2" status="$3" commit_sha="${4:--}"
  require_file "$plan_file"
  local valid_statuses="pending in_progress completed blocked"
  local valid=0
  for s in $valid_statuses; do [ "$s" = "$status" ] && valid=1 && break; done
  [ "$valid" -eq 1 ] || die "invalid status: $status (must be one of: $valid_statuses)"
  _tasks_backfill_if_needed "$plan_file"
  # carry the task's existing tier; absence ⇒ unregistered id ⇒ error (mirrors old not-found)
  local tier; tier=$(ev_tasks_fold "$plan_file" | awk -F'\t' -v t="$task_id" '$1==t{print $2; exit}')
  [ -n "$tier" ] || { echo "ERROR: task id '$task_id' not found in $plan_file" >&2; exit 1; }
  ev_record_task "$plan_file" "$task_id" "$tier" "$status" "$commit_sha"
  _render_task_ledger "$plan_file"
}

# cmd_resume_sweep PLAN — interrupted-session recovery: any in_progress task (no commit made)
# is demoted to pending via a synthetic fact append (append-only; replaces the old LLM-driven
# markdown edit at skills/implementing/SKILL.md §Session Recovery).
cmd_resume_sweep() {
  local plan_file="$1"
  require_file "$plan_file"
  _tasks_backfill_if_needed "$plan_file"
  local _id _tier _st _sha
  ev_tasks_fold "$plan_file" | while IFS=$'\t' read -r _id _tier _st _sha; do
    [ "$_st" = "in_progress" ] && ev_record_task "$plan_file" "$_id" "$_tier" pending "-"
  done
  _render_task_ledger "$plan_file"
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
    if grep -qF "[BLOCKED:code] coder:${task_id}:" "$plan_file" 2>/dev/null; then
      blocked_tasks="${blocked_tasks} ${task_id}([BLOCKED:code] coder)"
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
  if (cmd_update_task "$plan_file" "$task_id" "completed"); then
    echo "[record-task-completed] marked task (${task_id}) completed in ${plan_file}" >&2
  else
    echo "[record-task-completed] WARN: could not update task ${task_id} in ${plan_file} — task may not exist in ledger" >&2
  fi
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
    in_section && /\[RECURRING\]/ { next }
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

# _is_blocked_plan_md_count PLAN_FILE [KIND] — count active BLOCKED markers in ## Open Questions.
# Uses HUMAN_MUST_CLEAR_MARKERS from phase-policy.sh for the no-kind case (no hardcoding).
# Uses grep (not awk -v) for pattern matching to avoid awk's backslash-escape processing of -v values.
_is_blocked_plan_md_count() {
  local _pf="$1" _kind="${2:-}"
  local _section _count=0
  _section=$(awk '/^## Open Questions$/{in_s=1;next} in_s&&/^## /{in_s=0} in_s{print}' \
    "$_pf" 2>/dev/null) || _section=""
  [[ -z "$_section" ]] && { echo 0; return 0; }
  if [[ -n "$_kind" ]]; then
    # kind is [a-z]+ — safe to interpolate; \[ and \] are literal brackets in grep ERE
    _count=$(printf '%s\n' "$_section" | grep -cE "^\[BLOCKED:${_kind}\] " 2>/dev/null) || _count=0
  else
    local _m _esc
    for _m in "${HUMAN_MUST_CLEAR_MARKERS[@]}"; do
      _esc=$(printf '%s' "$_m" | sed 's/[][]/\\&/g')
      printf '%s\n' "$_section" | grep -qE "^${_esc}[[:space:]]" 2>/dev/null && _count=$((_count + 1)) || true
    done
  fi
  echo "$_count"
}

cmd_is_blocked() {
  local plan_file="$1" kind="${2:-}"
  require_file "$plan_file"
  local _bpath
  _bpath=$(sc_path "$plan_file" "$SC_BLOCKED")
  local _count=0
  if [[ -f "$_bpath" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "[is-blocked] jq required but not found — preflight should have blocked this run" >&2
      return 2
    fi
    local _jq_rc=0
    if [[ -n "$kind" ]]; then
      _count=$(jq -r --arg k "$kind" 'select(.cleared_at == null and .kind == $k) | 1' \
        "$_bpath" 2>/dev/null | awk 'END{print NR}') || _jq_rc=$?
    else
      _count=$(jq -r 'select(.cleared_at == null and .kind != "transient") | 1' \
        "$_bpath" 2>/dev/null | awk 'END{print NR}') || _jq_rc=$?
    fi
    if [[ "$_jq_rc" -ne 0 ]]; then
      echo "[is-blocked] WARNING: corrupt blocked.jsonl${kind:+ (kind=${kind})} — falling back to plan.md divergence check" >&2
      _count=0
    fi
  else
    echo "[is-blocked] WARNING: blocked.jsonl absent — treating as not-blocked" >&2
  fi
  [[ "$_count" -gt 0 ]] && return 0
  # Divergence check: JSONL has 0 active records — verify plan.md agrees (hard divergence only).
  local _plan_md_active
  _plan_md_active=$(_is_blocked_plan_md_count "$plan_file" "$kind")
  if [[ "$_plan_md_active" -gt 0 ]]; then
    echo "[is-blocked] DIVERGENCE: plan.md has ${_plan_md_active} active [BLOCKED:*] line(s) but blocked.jsonl has 0 active records — treating as blocked" >&2
    return 0
  fi
  return 1
}

# is-implemented / mark-implemented (implemented.json) removed — feature completion is now a
# pure recompute over the events log via ev-implemented (code∧quality convergence).

cmd_get_envelope() {
  local plan_file="$1"
  require_file "$plan_file"
  awk -F'|' '
    /^\| *(Actors|Frequency|Concurrency|Persistence|Failure model|External I\/O) *\|/ {
      axis=$2; val=$3
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", axis)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      print "- **" axis "**: " val
    }
  ' "$plan_file"
}

cmd_set_task_unit() {
  local plan_file="$1" unit_key="$2"
  require_file "$plan_file"
  if grep -q '<!-- task-unit:' "$plan_file" 2>/dev/null; then
    _awk_inplace "$plan_file" -v key="$unit_key" '
      /<!-- task-unit:.*-->/ { print "<!-- task-unit: " key " -->"; next }
      { print }
    '
  else
    _awk_inplace "$plan_file" -v key="$unit_key" '
      /<!-- task-definitions-start -->/ { print; print "<!-- task-unit: " key " -->"; next }
      { print }
    '
  fi
  echo "[set-task-unit] task-definitions bound to unit '${unit_key}' in ${plan_file}" >&2
}

cmd_get_task_unit() {
  local plan_file="$1"
  require_file "$plan_file"
  grep -m1 '<!-- task-unit:' "$plan_file" 2>/dev/null \
    | sed 's/.*<!-- task-unit: *//; s/ *-->.*//' \
    | grep -v '^$' || true
}

cmd_clear_task_state() {
  local plan_file="$1"
  require_file "$plan_file"
  # Delete the (separate) task-definitions JSON block — unchanged.
  _awk_inplace "$plan_file" '
    /<!-- task-definitions-start -->/{skip=1;next}
    /<!-- task-definitions-end -->/{skip=0;next}
    skip{next}
    {print}
  '
  # Tombstone every active ledger task: append-only, so we cannot delete rows — append a
  # `superseded` fact per task (the fold drops superseded), then regenerate the empty view.
  # Carries the inter-feature/rollback tombstone of invariant 7 (stale completed/in_progress
  # from a prior unit no longer resurface in the fold or the merge gate).
  _tasks_backfill_if_needed "$plan_file"
  local _id _tier _st _sha
  ev_tasks_fold "$plan_file" | while IFS=$'\t' read -r _id _tier _st _sha; do
    [ -n "$_id" ] && ev_record_task "$plan_file" "$_id" "$_tier" superseded "-"
  done
  _render_task_ledger "$plan_file"
  echo "[clear-task-state] superseded ledger tasks and cleared task definitions in ${plan_file}" >&2
}

cmd_inter_feature_reset() {
  local plan_file="$1"
  require_file "$plan_file"
  cmd_clear_task_state "$plan_file"
  local _state_dir
  _state_dir=$(sc_dir "$plan_file") || return 0
  rm -f "$_state_dir"/code-reviewed-* 2>/dev/null || true
  rm -f "$_state_dir"/pr-reviewed-* 2>/dev/null || true
  rm -f "$_state_dir"/quality-reviewed-* 2>/dev/null || true
  rm -f "$_state_dir"/test-reviewed-* 2>/dev/null || true
  rm -f "$_state_dir"/manifest-reconcile-* 2>/dev/null || true
  echo "[inter-feature-reset] cleared task definitions, ledger rows, code-reviewed, pr-reviewed, quality-reviewed, test-reviewed, and manifest-reconcile markers in ${plan_file}" >&2
}

