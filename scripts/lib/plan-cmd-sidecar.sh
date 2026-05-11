#!/usr/bin/env bash
# Plan sidecar-query and migration commands. Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PLAN_CMD_SIDECAR_LOADED:-}" ]] && return 0
_PLAN_CMD_SIDECAR_LOADED=1
_PLAN_CMD_SIDECAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_PLAN_LIB_LOADED:-}" ]] || . "$_PLAN_CMD_SIDECAR_DIR/plan-lib.sh"

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
