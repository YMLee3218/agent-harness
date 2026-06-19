#!/usr/bin/env bash
set -euo pipefail
if [[ "${CLAUDE_PLAN_CAPABILITY:-}" != "harness" ]] && [[ "${CLAUDE_PLAN_CAPABILITY:-}" != "human" ]]; then
  exec /usr/bin/env CLAUDE_PLAN_CAPABILITY=harness "$0" "$@"
fi
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF="$SCRIPTS_DIR/plan-file.sh"
PLAN="" _CALL_RC=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --plan) PLAN="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Resolve plan file if not provided
if [[ -z "$PLAN" ]]; then
  find_rc=0
  PLAN=$(bash "$PF" find-active 2>/dev/null) || find_rc=$?
  case $find_rc in
    0) ;;
    2) PLAN="" ;;
    3) echo "[BLOCKED] Multiple active plan files — set CLAUDE_PLAN_FILE=\"$CLAUDE_PROJECT_DIR/plans/{slug}.md\" then re-run" >&2; exit 1 ;;
    4) echo "[BLOCKED] Plan file phase unreadable — restore plans/{slug}.phase sidecar (schema 2) or repair ## Phase section (legacy plans)" >&2; exit 1 ;;
    *) PLAN="" ;;
  esac
fi

# When find-active returns empty (CLAUDE_PLAN_FILE points to a done plan), check for
# merge-gate failure blocks that would otherwise be invisible to the "no active plan" path.
if [[ -z "$PLAN" && -n "${CLAUDE_PLAN_FILE:-}" && -f "${CLAUDE_PLAN_FILE}" ]]; then
  if [[ "$(bash "$PF" get-phase "${CLAUDE_PLAN_FILE}" 2>/dev/null || echo "")" == "done" ]]; then
    if bash "$PF" is-blocked "${CLAUDE_PLAN_FILE}" 2>/dev/null; then
      echo "[merge-gate] done plan $(basename "${CLAUDE_PLAN_FILE}" .md) has an active block — run: bash \"${PF}\" context \"${CLAUDE_PLAN_FILE}\" to see the specific block kind; resolve it, then re-run with --plan flag" >&2
      exit 1
    fi
  fi
fi

# shellcheck source=lib/run-context.sh
source "$SCRIPTS_DIR/lib/run-context.sh"
setup_run_context

UNIT_CMD=$(grep -m1 '^\- Test:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | sed 's/^- Test: *//;s/^`//;s/`.*$//' || echo "")
INTEGRATION_CMD=$(grep -m1 '^\- Integration test:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | sed 's/^- Integration test: *//;s/^`//;s/`.*$//' || echo "")
LINT_CMD=$(grep -m1 '^\- Lint:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | sed 's/^- Lint: *//;s/^`//;s/`.*$//' || echo "")
[[ "$UNIT_CMD" == _\(run* || "$UNIT_CMD" == \{* ]] && UNIT_CMD=""
[[ "$INTEGRATION_CMD" == _\(run* || "$INTEGRATION_CMD" == \{* ]] && INTEGRATION_CMD=""
[[ "$LINT_CMD" == _\(run* || "$LINT_CMD" == \{* ]] && LINT_CMD=""

# shellcheck source=lib/dev-cycle-phases.sh
source "$SCRIPTS_DIR/lib/dev-cycle-phases.sh"
# shellcheck source=lib/llm-runner.sh
source "$SCRIPTS_DIR/lib/llm-runner.sh"

# Initialize Tier 1 worker sandbox (macOS Seatbelt via sandbox-exec).
# Must run after setup_run_context has set PROJECT_DIR.
_init_worker_sandbox "${PROJECT_DIR:-}"
if [[ "${_SANDBOX_REQUIRED_FAIL:-0}" == "1" ]]; then
  [[ -n "$PLAN" ]] && bash "$PF" append-note "$PLAN" "[BLOCKED:env] dev-cycle: sandbox-unavailable — Tier 1 sandbox inactive; set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined"
  [[ -z "$PLAN" ]] && echo "[BLOCKED:env] dev-cycle: sandbox-unavailable — Tier 1 sandbox inactive; set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined" >&2
  exit 1
fi

# Preflight: abort if any block present (catches [BLOCKED:env] preflight markers)
if [[ -n "$PLAN" ]]; then
  if bash "$PF" is-blocked "$PLAN" env 2>/dev/null; then
    echo "[BLOCKED:env] env/preflight block present — resolve and re-run" >&2; exit 1
  fi
fi

# Phase-aware routing when plan exists
if [[ -n "$PLAN" ]]; then
  current_phase=$(bash "$PF" get-phase "$PLAN" 2>/dev/null || echo "")
  if bash "$PF" is-blocked "$PLAN" 2>/dev/null; then
    echo "[BLOCKED] active block marker present — resolve markers before proceeding" >&2; exit 1
  fi
  if [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "human" && "$current_phase" != "done" ]]; then
    exec /usr/bin/env CLAUDE_PLAN_CAPABILITY=harness "$0" "$@"
  fi
  case "$current_phase" in
    brainstorm|spec|red|implement|green|integration) ;;
    done)
      # A2/A3: Merge gate + human approval gate before continuing
      _main_root="${PROJECT_DIR}"
      _MERGE_PENDING="${PLAN%.md}.state/merge-approval.pending"
      if [[ -f "$_MERGE_PENDING" ]]; then
        if [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "human" ]]; then
          # Human cleared merge-approval: do the merge and clean up
          # shellcheck source=lib/worktree-lib.sh
          source "$SCRIPTS_DIR/lib/worktree-lib.sh"
          _main_root=$(main_checkout_root "$PROJECT_DIR") || _main_root="$PROJECT_DIR"
          merge_plan_worktree "$(basename "$PLAN" .md)" "$_main_root" || {
            echo "[merge-gate] ERROR: merge failed — resolve conflicts and re-run with CLAUDE_PLAN_CAPABILITY=human" >&2; exit 1
          }
          rm -f "$_MERGE_PENDING"
          echo "[merge-gate] Merged feature/$(basename "$PLAN" .md) into main."
          _slug_merged=$(basename "$PLAN" .md)
          PLAN="${_main_root}/plans/${_slug_merged}.md"
          _finalize_pr "$_slug_merged"
        else
          echo "[BLOCKED:merge-approval] Awaiting human merge approval for $(basename "$PLAN" .md). Review ${PLAN%.md}.state/merge-gate-report.txt, then from main checkout: CLAUDE_PLAN_CAPABILITY=human bash .claude/scripts/run-dev-cycle.sh --plan ${PLAN}" >&2
          exit 3
        fi
      else
        _mg_rc=0
        bash "$SCRIPTS_DIR/run-merge-gate.sh" --plan "$PLAN" || _mg_rc=$?
        if [[ $_mg_rc -eq 2 ]]; then
          bash "$PF" append-note "$PLAN" "[BLOCKED:env] merge-gate: sandbox-unavailable — Tier 1 sandbox inactive; set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined"
          exit 1
        elif [[ $_mg_rc -ne 0 ]]; then
          exit 1
        fi
        touch "$_MERGE_PENDING"
        # shellcheck source=lib/telegram-notify.sh
        source "$SCRIPTS_DIR/lib/telegram-notify.sh"
        _tg_slug=$(basename "$PLAN" .md)
        telegram_send_human_must_clear "$_tg_slug" \
          "[BLOCKED:merge-approval] Branch feature/${_tg_slug} passed merge gate — ready to merge into main. Review: ${PLAN%.md}.state/merge-gate-report.txt. To merge (from main checkout): CLAUDE_PLAN_CAPABILITY=human bash .claude/scripts/run-dev-cycle.sh --plan ${PLAN}" \
          "$HOME/.claude/channels/telegram/.env" "$HOME/.claude/channels/telegram/access.json" || true
        echo "[merge-gate] PASS — plan ${_tg_slug} awaiting human merge approval." >&2
        exit 3
      fi
      _pending_count=0; _next_wt=""; _wl_wt=""
      while IFS= read -r _wl_line; do
        case "$_wl_line" in
          "worktree "*) _wl_wt="${_wl_line#worktree }" ;;
          "branch refs/heads/feature/"*)
            _pending_count=$(( _pending_count + 1 ))
            [[ -z "$_next_wt" ]] && _next_wt="$_wl_wt"
            ;;
        esac
      done < <(git -C "$_main_root" worktree list --porcelain 2>/dev/null)
      if [[ $_pending_count -ge 1 ]]; then
        echo "[RESTART] Plan $(basename "$PLAN" .md) merged. ${_pending_count} feature worktree(s) still active — cd to the worktree and re-invoke /running-dev-cycle. Next: ${_next_wt}" >&2
        exit 0
      fi
      echo "[DONE] All requirements complete. Run /brainstorming to start a new requirement." >&2
      exit 0
      ;;
    *) echo "[BLOCKED] unrecognised plan phase: ${current_phase}" >&2; exit 1 ;;
  esac
fi

MODE="feature"

# ── Step 1: Brainstorming ─────────────────────────────────────────────────────
if [[ -z "$PLAN" ]]; then
  echo "[BLOCKED:env] run-dev-cycle: no active plan — run /brainstorming first to create a plan, then re-run" >&2
  exit 1
fi

if [[ -n "${current_phase:-}" ]] && [[ "$current_phase" == "brainstorm" ]] && \
   ! bash "$PF" is-converged "$PLAN" brainstorm critic-feature 2>/dev/null; then
  run_llm "Invoke the brainstorming skill." opus
  llm_exit "brainstorming"
  find_rc=0
  PLAN=$(bash "$PF" find-active 2>/dev/null) || find_rc=$?
  case $find_rc in
    0) [[ -n "$PLAN" ]] || { echo "ERROR: plan file not created by brainstorming" >&2; exit 1; } ;;
    3) echo "ERROR: multiple active plan files after brainstorming — set CLAUDE_PLAN_FILE=\"$CLAUDE_PROJECT_DIR/plans/{slug}.md\"" >&2; exit 1 ;;
    4) echo "ERROR: plan file phase unreadable after brainstorming — restore plans/{slug}.phase sidecar or repair the ## Phase section" >&2; exit 1 ;;
    *) echo "ERROR: plan file not created by brainstorming (find-active rc=$find_rc)" >&2; exit 1 ;;
  esac
  if grep -q '^mode:' "$PLAN" 2>/dev/null; then
    sed -i '' "s/^mode:.*$/mode: ${MODE}/" "$PLAN" 2>/dev/null || true
  else
    awk -v m="${MODE}" '/^---$/ && ++n==2 {print "mode: " m} 1' \
      "$PLAN" > "${PLAN}.tmp" && mv "${PLAN}.tmp" "$PLAN" 2>/dev/null || true
  fi
  bash "$PF" reset-milestone "$PLAN" critic-feature
  CRITIC_PLAN_PATH="${PLAN}" \
  run_critic critic-feature brainstorm \
    "Review docs/requirements/$(basename "$PLAN" .md).md."
  llm_exit "critic-feature"
  current_phase="brainstorm"
fi

SLUG=$(basename "$PLAN" .md)
REQ_FILE="$PROJECT_DIR/docs/requirements/${SLUG}.md"

get_features() {
  [[ -f "$REQ_FILE" ]] && _features_block "$REQ_FILE" || echo ""
}

# Integration phase re-entry: skip feature loop
if [[ "${current_phase:-}" == "integration" ]]; then
  if [[ -n "$INTEGRATION_CMD" ]]; then
    bash "$SCRIPTS_DIR/run-integration.sh" --plan "$PLAN" \
      --unit-cmd "$UNIT_CMD" --integration-cmd "$INTEGRATION_CMD"
  else
    echo "[SKIP] integration tests — no command found in CLAUDE.md"
    bash "$PF" transition "$PLAN" done "no integration test command — skipped"
  fi
  exit $?
fi

if [[ -z "$(get_features)" ]]; then
  bash "$PF" append-note "$PLAN" "[BLOCKED:spec] run-dev-cycle: no-features — no features in ${REQ_FILE}; run /brainstorming first"
  exit 1
fi

# ── Feature-slice phases ──────────────────────────────────────────────────────
_phase_spec_prepass
_phase_domain_infra_spec_review
_phase_cross_spec_review
_phase_domain_infra_implement_cycle
_phase_implement_cycle

# ── Integration Tests ─────────────────────────────────────────────────────────
if [[ -n "$INTEGRATION_CMD" ]]; then
  bash "$SCRIPTS_DIR/run-integration.sh" \
    --plan "$PLAN" \
    --unit-cmd "$UNIT_CMD" \
    --integration-cmd "$INTEGRATION_CMD"
else
  echo "[SKIP] integration tests — no command found in CLAUDE.md"
  bash "$PF" transition "$PLAN" done "no integration test command — skipped"
fi
