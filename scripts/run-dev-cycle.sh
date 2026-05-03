#!/usr/bin/env bash
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF="$SCRIPTS_DIR/plan-file.sh"
PROFILE="feature" BATCH=0 PLAN="" _CALL_RC=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --profile) PROFILE="$2"; shift 2 ;;
    --batch)   BATCH=1;       shift ;;
    --plan)    PLAN="$2";     shift 2 ;;
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
    3) echo "[BLOCKED] Multiple active plan files — set CLAUDE_PLAN_FILE=plans/{slug}.md then re-run" >&2; exit 1 ;;
    4) echo "[BLOCKED] Plan file phase unreadable — check ## Phase section" >&2; exit 1 ;;
    *) PLAN="" ;;  # error — fall through to Step 1
  esac
fi

# Read project CLAUDE.md for test commands
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
UNIT_CMD=$(grep -m1 '^\- Test:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | sed 's/^- Test: *//;s/^`//;s/`$//' || echo "")
INTEGRATION_CMD=$(grep -m1 '^\- Integration test:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | sed 's/^- Integration test: *//;s/^`//;s/`$//' || echo "")

run_llm() {
  local prompt="$1" model="${2:-opus}"
  _CALL_RC=0
  CLAUDE_NONINTERACTIVE=1 CLAUDE_PLAN_FILE="${PLAN:-}" \
    claude --model "$model" --permission-mode auto --dangerously-skip-permissions -p "$prompt" || _CALL_RC=$?
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
    *) echo "Script failure: ${label} exited ${rc}" >&2
       [[ -n "${PLAN:-}" ]] && bash "$PF" append-note "$PLAN" "[BLOCKED] script-failure:${label}: exited ${rc}" 2>/dev/null || true
       exit $rc ;;
  esac
}

# Preflight: checked by SessionStart hook; abort if markers present
if [[ -n "$PLAN" ]]; then
  blocked=$(awk '/^## Open Questions/{f=1} f&&/\[BLOCKED\] preflight:/{print;exit}' "$PLAN" 2>/dev/null || true)
  [[ -n "$blocked" ]] && { echo "$blocked" >&2; exit 1; }
fi

# Phase-aware routing when plan exists
if [[ -n "$PLAN" ]]; then
  current_phase=$(bash "$PF" get-phase "$PLAN" 2>/dev/null || echo "")

  # Check for any BLOCKED markers before proceeding
  blocked=$(awk '/^## Open Questions/{f=1} f&&/\[BLOCKED/{print;exit}' "$PLAN" 2>/dev/null || true)
  [[ -n "$blocked" ]] && { echo "$blocked" >&2; exit 1; }

  case "$current_phase" in
    brainstorm|spec|red|implement|review|green|integration) ;;  # handled below
    done) PLAN=""; current_phase="" ;;  # treat as fresh start
    *) echo "[BLOCKED] unrecognised plan phase: ${current_phase}" >&2; exit 1 ;;
  esac
fi

# Determine mode
[[ "$PROFILE" == "greenfield" || $BATCH -eq 1 ]] && MODE="greenfield" || MODE="feature"

# ── Step 1: Brainstorming ────────────────────────────────────────────────────
if [[ -z "$PLAN" ]] || \
   { [[ -n "${current_phase:-}" ]] && [[ "$current_phase" == "brainstorm" ]] && \
     ! grep -q '\[CONVERGED\] brainstorm/critic-feature' "$PLAN" 2>/dev/null; }; then

  run_llm "Invoke the brainstorming skill." opus
  llm_exit "brainstorming"

  PLAN=$(bash "$PF" find-active 2>/dev/null || true)
  [[ -z "$PLAN" ]] && { echo "ERROR: plan file not created by brainstorming" >&2; exit 1; }

  # Insert mode into frontmatter
  sed -i '' "s/^mode:.*$/mode: ${MODE}/" "$PLAN" 2>/dev/null || \
    sed -i "0,/^---/{s/^---$/---\nmode: ${MODE}/}" "$PLAN" 2>/dev/null || true

  bash "$PF" reset-milestone "$PLAN" critic-feature
  run_critic critic-feature brainstorm \
    "Review docs/requirements/$(basename "$PLAN" .md).md. Original requirement: $(head -5 "$PLAN")."
  llm_exit "critic-feature"
  current_phase="brainstorm"
fi

# Read feature list
SLUG=$(basename "$PLAN" .md)
REQ_FILE="$PROJECT_DIR/docs/requirements/${SLUG}.md"

get_features() {
  [[ -f "$REQ_FILE" ]] && \
    awk '/^## (Small|Large) Features/{f=1;next} /^## /{f=0} f&&/^[-*] /{sub(/^[-*] *`/,""); sub(/`.*/,""); print}' "$REQ_FILE" || echo ""
}

# ── Feature-slice mode ───────────────────────────────────────────────────────
if [[ "$MODE" == "feature" ]]; then

  # integration phase re-entry: skip feature loop, go straight to integration
  if [[ "${current_phase:-}" == "integration" ]]; then
    [[ -n "$INTEGRATION_CMD" ]] && \
      bash "$SCRIPTS_DIR/run-integration.sh" --plan "$PLAN" \
        --unit-cmd "$UNIT_CMD" --integration-cmd "$INTEGRATION_CMD"
    exit $?
  fi

  while IFS= read -r feature; do
    [[ -z "$feature" ]] && continue

    # Skip done: feature-specific spec exists + no pending/in_progress/blocked tasks
    feat_slug=$(printf '%s' "$feature" | tr '[:upper:] ' '[:lower:]-' | tr -dc 'a-z0-9-')
    spec_found=0
    for sp in "features/${feat_slug}/spec.md" "domain/${feat_slug}/spec.md" "infrastructure/${feat_slug}/spec.md"; do
      [[ -f "$sp" ]] && spec_found=1 && break
    done
    if [[ $spec_found -eq 1 ]]; then
      pending_tasks=$(awk '/^## Task Ledger/{f=1;next} f&&/^## /{exit} f&&/\| pending[ |]|\| in_progress[ |]|\| blocked[ |]/' "$PLAN" 2>/dev/null || true)
      [[ -z "$pending_tasks" ]] && continue
    fi

    # Inter-feature reset: previous feature just reached green, this feature not yet started
    phase_now=$(bash "$PF" get-phase "$PLAN")
    if [[ $spec_found -eq 0 && "$phase_now" == "green" ]]; then
      bash "$PF" reset-milestone "$PLAN" critic-spec
      bash "$PF" reset-milestone "$PLAN" critic-test
      bash "$PF" reset-milestone "$PLAN" critic-code
      bash "$PF" reset-pr-review "$PLAN"
      sed -i '' '/<!-- task-definitions-start -->/,/<!-- task-definitions-end -->/d' "$PLAN" 2>/dev/null || \
        sed -i '/<!-- task-definitions-start -->/,/<!-- task-definitions-end -->/d' "$PLAN" 2>/dev/null || true
      # Clear Task Ledger data rows so next feature's task gate fires correctly
      awk '/^## Task Ledger$/{sec=1; print; next} sec&&/^## /{sec=0} sec&&/\| (pending|in_progress|completed|blocked)/{next} {print}' \
        "$PLAN" > "${PLAN}.tmp" && mv "${PLAN}.tmp" "$PLAN" 2>/dev/null || true
      bash "$PF" transition "$PLAN" spec "starting spec phase for next feature: ${feature}"
    fi

    # Step 2a — Spec
    phase_now=$(bash "$PF" get-phase "$PLAN")
    if [[ "$phase_now" == "brainstorm" || "$phase_now" == "spec" ]] && \
       ! grep -q '\[CONVERGED\] spec/critic-spec' "$PLAN" 2>/dev/null; then
      run_llm "Invoke the writing-spec skill for feature: ${feature}. Plan: ${PLAN}." opus
      llm_exit "writing-spec"
      bash "$PF" reset-milestone "$PLAN" critic-spec
      run_critic critic-spec spec "Review spec for feature: ${feature}. Plan: ${PLAN}."
      llm_exit "critic-spec"
      while IFS= read -r spec_path; do
        [[ -n "$spec_path" ]] && git add "$spec_path"
      done < <(git status --porcelain 2>/dev/null | grep 'spec\.md' | awk '{print $2}')
      git diff --cached --quiet || git commit -m "feat(spec): add BDD scenarios for ${feature}"
    fi

    # Step 2b — Tests
    phase_now=$(bash "$PF" get-phase "$PLAN")
    if [[ "$phase_now" == "spec" || "$phase_now" == "red" ]] && \
       ! grep -q '\[CONVERGED\] red/critic-test' "$PLAN" 2>/dev/null; then
      run_llm "Invoke the writing-tests skill for feature: ${feature}. Plan: ${PLAN}." sonnet
      llm_exit "writing-tests"
      bash "$PF" reset-milestone "$PLAN" critic-test
      run_critic critic-test red "Review tests for feature: ${feature}. Plan: ${PLAN}. Test command: ${UNIT_CMD}."
      llm_exit "critic-test"
    fi

    # Step 2c — Implement Step 1 (LLM task planning): only when tasks not yet defined
    phase_now=$(bash "$PF" get-phase "$PLAN")
    has_task_defs=$(grep -c 'task-definitions-start' "$PLAN" 2>/dev/null || echo 0)
    if [[ "$phase_now" == "red" && "$has_task_defs" -eq 0 ]]; then
      run_llm "Invoke the implementing skill for feature: ${feature}. Plan: ${PLAN}." opus
      llm_exit "implementing (Step 1)"
    fi

    # run-implement.sh: execute pending tasks
    phase_now=$(bash "$PF" get-phase "$PLAN")
    has_task_defs=$(grep -c 'task-definitions-start' "$PLAN" 2>/dev/null || echo 0)
    pending=$(awk '/^## Task Ledger/{f=1;next} f&&/^## /{exit} f&&/\| pending[ |]|\| in_progress[ |]/' "$PLAN" 2>/dev/null || true)
    any_task_in_ledger=$(awk '/^## Task Ledger$/{f=1;next} f&&/^## /{exit} f&&/\| (pending|in_progress|completed|blocked)[ |]/{print;exit}' "$PLAN" 2>/dev/null || true)
    if [[ ( "$phase_now" == "red" || "$phase_now" == "implement" ) && \
          ( -n "$pending" || ( "$has_task_defs" -gt 0 && -z "$any_task_in_ledger" ) ) ]]; then
      if [[ -z "$UNIT_CMD" ]]; then
        bash "$PF" append-note "$PLAN" "[BLOCKED] run-implement: unit test command not configured — add '- Test: {cmd}' to CLAUDE.md"
        exit 1
      fi
      bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD"
    fi

    # Critic-code
    phase_now=$(bash "$PF" get-phase "$PLAN")
    if [[ "$phase_now" == "implement" ]] && \
       ! grep -q '\[CONVERGED\] implement/critic-code' "$PLAN" 2>/dev/null; then
      bash "$PF" reset-milestone "$PLAN" critic-code
      run_critic critic-code implement "Review changed files. Plan: ${PLAN}."
      llm_exit "critic-code"
    fi

    # PR review transition (fires once critic-code converges and phase is still implement)
    phase_now=$(bash "$PF" get-phase "$PLAN")
    if [[ "$phase_now" == "implement" ]]; then
      bash "$PF" transition "$PLAN" review "critic-code converged — starting pr-review"
      bash "$PF" reset-pr-review "$PLAN"
      gh pr view 2>/dev/null || gh pr create --draft --title "feat: ${feature}"
    fi

    # pr-review loop
    phase_now=$(bash "$PF" get-phase "$PLAN")
    if [[ "$phase_now" == "review" ]] && \
       ! grep -q '\[CONVERGED\] review/pr-review' "$PLAN" 2>/dev/null; then
      pr_url=$(gh pr view --json url -q .url 2>/dev/null || echo "")
      run_critic pr-review review "PR: ${pr_url}. Plan: ${PLAN}." "@reference/pr-review-loop.md §PR-review one-shot iteration"
      llm_exit "pr-review"
    fi

    # green transition
    phase_now=$(bash "$PF" get-phase "$PLAN")
    if [[ "$phase_now" == "review" ]] && \
       grep -q '\[CONVERGED\] review/pr-review' "$PLAN" 2>/dev/null; then
      bash "$PF" transition "$PLAN" green "pr-review converged — feature complete"
    fi

  done < <(get_features)

# ── Batch (greenfield) mode ──────────────────────────────────────────────────
else
  # Step 2 — All specs
  while IFS= read -r feature; do
    [[ -z "$feature" ]] && continue
    run_llm "Invoke the writing-spec skill for feature: ${feature}. Plan: ${PLAN}." opus
    llm_exit "writing-spec"
    bash "$PF" reset-milestone "$PLAN" critic-spec
    run_critic critic-spec spec "Review spec for feature: ${feature}. Plan: ${PLAN}."
    llm_exit "critic-spec"
    while IFS= read -r spec_path; do
      [[ -n "$spec_path" ]] && git add "$spec_path"
    done < <(git status --porcelain 2>/dev/null | grep 'spec\.md' | awk '{print $2}')
    git diff --cached --quiet || git commit -m "feat(spec): add BDD scenarios for ${feature}"
  done < <(get_features)

  # Step 3 — All tests
  while IFS= read -r feature; do
    [[ -z "$feature" ]] && continue
    run_llm "Invoke the writing-tests skill for feature: ${feature}. Plan: ${PLAN}." sonnet
    llm_exit "writing-tests"
    bash "$PF" reset-milestone "$PLAN" critic-test
    run_critic critic-test red "Review tests for feature: ${feature}. Plan: ${PLAN}. Test command: ${UNIT_CMD}."
    llm_exit "critic-test"
  done < <(get_features)

  # Step 4 — Implement (all features together)
  run_llm "Invoke the implementing skill. Plan: ${PLAN}." opus
  llm_exit "implementing (Step 1)"
  if [[ -z "$UNIT_CMD" ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED] run-implement: unit test command not configured — add '- Test: {cmd}' to CLAUDE.md"
    exit 1
  fi
  bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD"

  bash "$PF" reset-milestone "$PLAN" critic-code
  run_critic critic-code implement "Review changed files. Plan: ${PLAN}."
  llm_exit "critic-code"

  bash "$PF" transition "$PLAN" review "critic-code converged — starting pr-review"
  bash "$PF" reset-pr-review "$PLAN"
  gh pr view 2>/dev/null || gh pr create --draft --title "feat: ${SLUG}"
  pr_url=$(gh pr view --json url -q .url 2>/dev/null || echo "")
  run_critic pr-review review "PR: ${pr_url}. Plan: ${PLAN}." "@reference/pr-review-loop.md §PR-review one-shot iteration"
  llm_exit "pr-review"
  bash "$PF" transition "$PLAN" green "pr-review converged — batch complete"
fi

# ── Integration Tests ────────────────────────────────────────────────────────
if [[ -n "$INTEGRATION_CMD" ]]; then
  bash "$SCRIPTS_DIR/run-integration.sh" \
    --plan "$PLAN" \
    --unit-cmd "$UNIT_CMD" \
    --integration-cmd "$INTEGRATION_CMD"
else
  echo "[SKIP] integration tests — no command found in CLAUDE.md"
  bash "$PF" transition "$PLAN" done "no integration test command — skipped"
fi
