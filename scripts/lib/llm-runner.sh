#!/usr/bin/env bash
# LLM and critic runner helpers shared between run-dev-cycle.sh and run-integration.sh.
# Source this file; do not execute directly.
# Requires globals: SCRIPTS_DIR, PLAN (may be empty), _CALL_RC (set to 0 before each call).
set -euo pipefail
[[ -n "${_LLM_RUNNER_LOADED:-}" ]] && return 0
_LLM_RUNNER_LOADED=1

_LLM_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_SANDBOX_LIB_LOADED:-}" ]] || . "$_LLM_RUNNER_DIR/sandbox-lib.sh"

# run_llm — outer ORCHESTRATOR session (brainstorm/spec/tests/implement dispatch).
# DELIBERATELY UNGUARDED by wall-clock: a single cap would falsely kill a phase that
# legitimately runs long (e.g. implementing supervises many already-guarded codex
# leaves). Guard policy is LAYERED: leaf work (codex workers, test/lint gates, critic
# sessions) carries the --kill-after=$TG_KILL_AFTER cap; the orchestrator session does
# not. A hung orchestrator is bounded only by operator attention / the 600s hook
# timeout, by design. Do NOT add a timeout wrapper here without revisiting this policy.
run_llm() {
  local prompt="$1" model="${2:-opus}"
  _CALL_RC=0
  CLAUDE_NONINTERACTIVE=1 CLAUDE_PLAN_FILE="${PLAN:-}" \
    env -u CLAUDE_PLAN_CAPABILITY worker_exec claude --model "$model" --permission-mode auto --dangerously-skip-permissions -p "$prompt" || _CALL_RC=$?
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
    1) echo "[BLOCKED] ${label} failed — see ## Open Questions for [BLOCKED:*] markers; if no markers are present, check sidecar at plans/<slug>.state/blocked.jsonl" >&2; exit 1 ;;
    2) echo "[BLOCKED:ceiling] ${label} — manual review required" >&2; exit 2 ;;
    3) echo "[BLOCKED] ${label}: critic loop already running — wait or remove .critic.lock" >&2; exit 1 ;;
    *) echo "Script failure: ${label} exited ${rc}" >&2
       [[ -n "${PLAN:-}" ]] && bash "${PF:-}" append-note "$PLAN" "[BLOCKED:env] ${label}: script-failure — exit ${rc}" 2>/dev/null || true
       exit $rc ;;
  esac
}

# _recent_test_files [since_sha] — test files from the latest test(red): commit.
# With since_sha, restrict to commits in since_sha..HEAD so a feature whose writing-tests
# produced no commit does NOT inherit a prior feature's test files (cross-feature contamination).
_recent_test_files() {
  local _since="${1:-}" _red_sha _files=""
  if [[ -n "$_since" ]]; then
    _red_sha=$(git -C "$PROJECT_DIR" log --grep='^test(red):' --format='%H' "${_since}..HEAD" 2>/dev/null | head -1 || true)
  else
    _red_sha=$(git -C "$PROJECT_DIR" log --grep='^test(red):' --format='%H' 2>/dev/null | head -1 || true)
  fi
  if [[ -n "$_red_sha" ]]; then
    _files=$(git -C "$PROJECT_DIR" show --name-only --format= "$_red_sha" 2>/dev/null | grep -E '(^|/)tests/|_test\.|(^|/)test_|\.test\.|\.spec\.|_spec\.' | grep -v '\.spec\.md$' | tr '\n' ' ' || true)
  elif [[ -z "$_since" ]]; then
    # Legacy callers only: fall back to last commit's test files when no test(red): exists.
    _files=$(git -C "$PROJECT_DIR" diff HEAD~1 HEAD --name-only 2>/dev/null | grep -E '(^|/)tests/|_test\.|(^|/)test_|\.test\.|\.spec\.|_spec\.' | grep -v '\.spec\.md$' | tr '\n' ' ' || true)
  fi
  echo "${_files:-}"
}

find_spec_path() {
  local slug="$1"
  # Canonical paths (per layers.md §Naming conventions: spec files are top-level) checked first;
  # src/ paths are legacy fallback for non-standard layouts.
  for _sp in "${PROJECT_DIR}/features/${slug}/spec.md" \
             "${PROJECT_DIR}/domain/${slug}/spec.md" \
             "${PROJECT_DIR}/infrastructure/${slug}/spec.md" \
             "${PROJECT_DIR}/src/features/${slug}/spec.md" \
             "${PROJECT_DIR}/src/domain/${slug}/spec.md" \
             "${PROJECT_DIR}/src/infrastructure/${slug}/spec.md"; do
    [[ -f "$_sp" ]] && echo "$_sp" && return
  done
  echo "features/${slug}/spec.md"
}

docs_paths() {
  local _req="${1:-${REQ_FILE:-}}"
  local _docs_root="${PROJECT_DIR}"
  [[ -f "$_req" ]] && echo "${_req} ${_docs_root}/docs/" || echo "${_docs_root}/docs/"
}
