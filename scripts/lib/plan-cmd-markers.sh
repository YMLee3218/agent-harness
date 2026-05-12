#!/usr/bin/env bash
# Plan marker/reset commands: clear-marker, unblock, clear-converged, reset-milestone, reset-pr-review.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PLAN_CMD_MARKERS_LOADED:-}" ]] && return 0
_PLAN_CMD_MARKERS_LOADED=1

_PLAN_CMD_MARKERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_PLAN_LOOP_HELPERS_LOADED:-}" ]] || . "$_PLAN_CMD_MARKERS_DIR/plan-loop-helpers.sh"
[[ -n "${_PLAN_CMD_STATE_LOADED:-}" ]] || . "$_PLAN_CMD_MARKERS_DIR/plan-cmd-state.sh"

PHASE_CONVERGENCE_MARKERS=(
  "BLOCKED-CEILING"
  "CONVERGED"
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
  # use _with_lock (mkdir-atomic, symlink-safe) instead of flock
  _with_lock "${plan_file}" _cmd_clear_marker_body "$plan_file" "$marker" || _rc=$?
  if [[ $_rc -ne 0 ]]; then
    echo "[clear-marker] failed to clear '$marker' from $plan_file (rc=${_rc})" >&2
    return "$_rc"
  fi
  echo "[clear-marker] removed '$marker' from ## Open Questions in $plan_file" >&2
}

# cmd_unblock clears [BLOCKED*:agent:...] lines from ## Open Questions for the named agent.
# NOTE: BLOCKED-AMBIGUOUS lines use a different colon format and are NOT cleared by this function.
# Use cmd_clear_marker (Ring C) to clear them explicitly after human review.
# Leaving BLOCKED-AMBIGUOUS uncleared after running unblock causes plan.md ↔ blocked.jsonl divergence.
cmd_unblock() {
  local agent="$1"
  _validate_critic_agent "$agent" "unblock"
  local plan_file
  plan_file=$(cmd_find_active) || die "unblock: no active plan found"
  if command -v jq >/dev/null 2>&1; then
    local _bpath _ts
    _bpath=$(sc_path "$plan_file" "$SC_BLOCKED")
    _ts=$(_iso_timestamp)
    # Cleared by agent field match only — harness fallback regex removed (dead: messages strip [BLOCKED*]).
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
        # Anchored string check: must be [BLOCKED-CEILING] <phase>/<agent>: at line start.
        # Prevents false-match when agent name appears in message body.
        # Use index() to avoid AWK regex / inside character-class issues.
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
