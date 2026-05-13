#!/usr/bin/env bash
# LLM and critic runner helpers shared between run-dev-cycle.sh and run-integration.sh.
# Source this file; do not execute directly.
# Requires globals: SCRIPTS_DIR, PLAN (may be empty), _CALL_RC (set to 0 before each call).
set -euo pipefail
[[ -n "${_LLM_RUNNER_LOADED:-}" ]] && return 0
_LLM_RUNNER_LOADED=1

run_llm() {
  local prompt="$1" model="${2:-opus}"
  _CALL_RC=0
  CLAUDE_NONINTERACTIVE=1 CLAUDE_PLAN_FILE="${PLAN:-}" \
    env -u CLAUDE_PLAN_CAPABILITY claude --model "$model" --permission-mode auto --dangerously-skip-permissions -p "$prompt" || _CALL_RC=$?
}

run_critic() {
  local agent="$1" phase="$2" prompt="$3" iter_doc="${4:-}"
  local args=(--agent "$agent" --phase "$phase" --plan "$PLAN" --prompt "$prompt")
  [[ -n "$iter_doc" ]] && args+=(--iteration-doc "$iter_doc")
  _CALL_RC=0
  bash "$SCRIPTS_DIR/run-critic-loop.sh" "${args[@]}" || _CALL_RC=$?
}

llm_exit() {
  local rc=${_CALL_RC} label="$1"
  _CALL_RC=0
  case $rc in
    0) return 0 ;;
    1) echo "[BLOCKED] ${label} failed — see ## Open Questions" >&2; exit 1 ;;
    2) echo "[BLOCKED-CEILING] ${label} — manual review required" >&2; exit 2 ;;
    3) echo "[BLOCKED] ${label}: critic loop already running for this plan — wait for the active run to finish or remove the .critic.lock file" >&2; exit 1 ;;
    4) echo "[ESCALATION] ${label}: operating envelope must be corrected — see [ESCALATION] marker in ## Open Questions" >&2; exit 4 ;;
    *) echo "Script failure: ${label} exited ${rc}" >&2
       [[ -n "${PLAN:-}" ]] && bash "${PF:-}" append-note "$PLAN" "[BLOCKED] script-failure:${label}: exited ${rc}" 2>/dev/null || true
       exit $rc ;;
  esac
}

_recent_test_files() {
  git diff HEAD~1 HEAD --name-only 2>/dev/null | grep -E '^tests/|_test\.' | tr '\n' ' ' || true
}

find_spec_path() {
  local slug="$1"
  for _sp in "${PROJECT_DIR}/features/${slug}/spec.md" \
             "${PROJECT_DIR}/domain/${slug}/spec.md" \
             "${PROJECT_DIR}/infrastructure/${slug}/spec.md"; do
    [[ -f "$_sp" ]] && echo "$_sp" && return
  done
  echo "features/${slug}/spec.md"
}

docs_paths() {
  local _req="${1:-${REQ_FILE:-}}"
  [[ -f "$_req" ]] && echo "${_req} ${PROJECT_DIR}/docs/" || echo "${PROJECT_DIR}/docs/"
}
