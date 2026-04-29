#!/usr/bin/env bash
# SessionStart hook: verify autonomous run prerequisites before any skill executes.
# In interactive mode (CLAUDE_NONINTERACTIVE unset/0), exits 0 immediately.
# In autonomous mode (CLAUDE_NONINTERACTIVE=1), checks required tools and files;
# on failure, appends [BLOCKED] preflight: markers to ## Open Questions and exits 2.
#
# Required tools (single source of truth):
#   gh CLI (authenticated)  — implementing runs gh pr create; without auth PR step fails (skipped in B-sessions: CLAUDE_CRITIC_SESSION=1)
#   jq                      — phase-gate.sh and pretooluse-bash.sh parse hook payloads
#   context7-plugin         — critic-code and critic-spec use context7 to verify external API usage
#   pr-review-toolkit       — implementing calls pr-review-toolkit:review-pr per feature
#   codex                   — coder agent delegates implementation via codex exec --full-auto
#   codex-auth              — Codex requires OPENAI_API_KEY or ~/.codex/auth.json
# Required files:
#   .claude/local.md        — language, runtime, test/lint/integration-test commands
#   CLAUDE.md (project)     — created by initializing-project; absence triggers re-init
#
# Exit 2 = block the session (missing prerequisites)
# Exit 0 = allow

[ "${CLAUDE_NONINTERACTIVE:-0}" = "1" ] || exit 0

PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"
BLOCKED_LABEL="preflight"
# shellcheck source=lib/active-plan.sh
source "$(dirname "$0")/lib/active-plan.sh"

# Locate active plan for [BLOCKED] preflight: writes; non-fatal if none found.
_active_plan="" _active_plan_phase=""
resolve_active_plan_and_phase _active_plan _active_plan_phase 2>/dev/null || _active_plan=""

_blocked=0

# Append a [BLOCKED] preflight marker for <tool> with <fix> advice.
# Idempotent: skips if a marker for this tool already exists in ## Open Questions.
# If no active plan, prints to stderr only.
_append_blocked() {
  local tool="$1" fix="$2"
  local marker="[BLOCKED] preflight:${tool}: ${fix}"
  if [ -n "$_active_plan" ] && [ -f "$_active_plan" ]; then
    if grep -qF "[BLOCKED] preflight:${tool}:" "$_active_plan" 2>/dev/null; then
      return
    fi
    bash "$PLAN_FILE_SH" append-note "$_active_plan" "$marker" 2>/dev/null || true
  else
    echo "$marker" >&2
  fi
  _blocked=1
}

# Check: gh CLI authenticated (skipped in B-sessions — critic/pr-review never call gh)
if [ "${CLAUDE_CRITIC_SESSION:-0}" != "1" ] && ! gh auth status >/dev/null 2>&1; then
  _append_blocked "gh" "run 'gh auth login' to authenticate the GitHub CLI"
fi

# Check: jq installed
if ! command -v jq >/dev/null 2>&1; then
  _append_blocked "jq" "install jq (brew install jq or apt install jq)"
fi

# Check: context7-plugin
if ! claude plugin list 2>/dev/null | grep -q 'context7-plugin'; then
  _append_blocked "context7-plugin" "install via settings.json enabledPlugins or 'claude plugin install'"
fi

# Check: pr-review-toolkit
if ! claude plugin list 2>/dev/null | grep -q 'pr-review-toolkit'; then
  _append_blocked "pr-review-toolkit" "install via settings.json enabledPlugins or 'claude plugin install'"
fi

# Check: codex plugin
if ! claude plugin list 2>/dev/null | grep -q 'codex'; then
  _append_blocked "codex" "install via settings.json enabledPlugins or 'claude plugin install codex@openai-codex'"
fi

# Check: codex auth (OPENAI_API_KEY or ~/.codex/auth.json)
if [ -z "${OPENAI_API_KEY:-}" ] && [ ! -f "${HOME}/.codex/auth.json" ]; then
  _append_blocked "codex-auth" "set OPENAI_API_KEY or run 'codex login' to authenticate (creates ~/.codex/auth.json)"
fi

# Check: .claude/local.md
if [ -z "${CLAUDE_PROJECT_DIR:-}" ] || [ ! -f "${CLAUDE_PROJECT_DIR}/.claude/local.md" ]; then
  _append_blocked "local.md" "create .claude/local.md with language, test command, and lint command"
fi

# Check: project CLAUDE.md
if [ -z "${CLAUDE_PROJECT_DIR:-}" ] || [ ! -f "${CLAUDE_PROJECT_DIR}/CLAUDE.md" ]; then
  _append_blocked "CLAUDE.md" "run /initializing-project to create the project CLAUDE.md"
fi

if [ "$_blocked" = "1" ]; then
  echo "[BLOCKED] preflight: Prerequisites missing — inspect ## Open Questions in the active plan" >&2
  exit 2
fi

exit 0
