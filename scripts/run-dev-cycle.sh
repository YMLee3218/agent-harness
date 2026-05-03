#!/usr/bin/env bash
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF="$SCRIPTS_DIR/plan-file.sh"
PROFILE="feature" BATCH=0 PLAN=""

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
  PLAN=$(bash "$PF" find-active 2>/dev/null || true)
  find_rc=$?
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
UNIT_CMD=$(grep -m1 '^\- Test:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | sed 's/^- Test: *//' || echo "")
INTEGRATION_CMD=$(grep -m1 '^\- Integration test:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | sed 's/^- Integration test: *//' || echo "")

run_llm() {
  local prompt="$1" model="${2:-opus}"
  CLAUDE_NONINTERACTIVE=1 CLAUDE_PLAN_FILE="${PLAN:-}" \
    claude --model "$model" --permission-mode auto --dangerously-skip-permissions -p "$prompt"
}

run_critic() {
  local agent="$1" phase="$2" prompt="$3"
  bash "$SCRIPTS_DIR/run-critic-loop.sh" --agent "$agent" --phase "$phase" --plan "$PLAN" --prompt "$prompt"
  return $?
}

llm_exit() {
  local rc=$? label="$1"
  case $rc in
    0) return 0 ;;
    1) echo "[BLOCKED] ${label} failed — see ## Open Questions" >&2; exit 1 ;;
    2) echo "[BLOCKED-CEILING] ${label} — manual review required" >&2; exit 2 ;;
    *) echo "Script failure: ${label} exited ${rc}" >&2; exit $rc ;;
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
    "Review docs/requirements/$(basename "$(dirname "$PLAN")").md. Original requirement: $(head -5 "$PLAN")."
  llm_exit "critic-feature"
  current_phase="brainstorm"
fi

# Read feature list
SLUG=$(basename "$PLAN" .md)
REQ_FILE=$(find "$PROJECT_DIR/docs/requirements" -name "*.md" 2>/dev/null | head -1 || echo "")

get_features() {
  [[ -f "$REQ_FILE" ]] && grep -E '^[-*] ' "$REQ_FILE" | sed 's/^[-*] *//' || echo ""
}

# ── Feature-slice mode ───────────────────────────────────────────────────────
if [[ "$MODE" == "feature" ]]; then
  while IFS= read -r feature; do
    [[ -z "$feature" ]] && continue

    # Skip done: spec exists + all tasks completed
    spec_path=$(find "$PROJECT_DIR" -path "*/features/*/spec.md" -o -path "*/domain/*/spec.md" -o \
      -path "*/infrastructure/*/spec.md" 2>/dev/null | head -1 || true)
    if [[ -f "$spec_path" ]]; then
      task_status=$(awk '/^## Task Ledger/{f=1;next} f&&/^## /{exit} f' "$PLAN" 2>/dev/null || true)
      [[ -n "$task_status" ]] && ! echo "$task_status" | grep -qE '\| pending|\| in_progress|\| blocked' && continue
    fi

    # Step 2a — Spec
    if [[ "$(bash "$PF" get-phase "$PLAN")" != "spec" ]] || \
       ! grep -q '\[CONVERGED\] spec/critic-spec' "$PLAN" 2>/dev/null; then
      run_llm "Invoke the writing-spec skill for feature: ${feature}. Plan: ${PLAN}." opus
      llm_exit "writing-spec"
      bash "$PF" reset-milestone "$PLAN" critic-spec
      run_critic critic-spec spec "Review spec for feature: ${feature}. Plan: ${PLAN}."
      llm_exit "critic-spec"
      spec_path=$(git status --porcelain 2>/dev/null | grep 'spec\.md' | awk '{print $2}' | head -1 || true)
      [[ -n "$spec_path" ]] && git add "$spec_path" && git commit -m "feat(spec): add BDD scenarios for ${feature}"
    fi

    # Step 2b — Tests
    if [[ "$(bash "$PF" get-phase "$PLAN")" != "red" ]] || \
       ! grep -q '\[CONVERGED\] red/critic-test' "$PLAN" 2>/dev/null; then
      run_llm "Invoke the writing-tests skill for feature: ${feature}. Plan: ${PLAN}." sonnet
      llm_exit "writing-tests"
      bash "$PF" reset-milestone "$PLAN" critic-test
      run_critic critic-test red "Review tests for feature: ${feature}. Plan: ${PLAN}. Test command: ${UNIT_CMD}."
      llm_exit "critic-test"
    fi

    # Step 2c — Implement
    run_llm "Invoke the implementing skill for feature: ${feature}. Plan: ${PLAN}." opus
    llm_exit "implementing (Step 1)"

    [[ -n "$UNIT_CMD" ]] && bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD"

    # Critic-code
    bash "$PF" reset-milestone "$PLAN" critic-code
    run_critic critic-code implement "Review changed files. Plan: ${PLAN}."
    llm_exit "critic-code"

    # PR review
    bash "$PF" transition "$PLAN" review "critic-code converged — starting pr-review"
    bash "$PF" reset-pr-review "$PLAN"
    gh pr view 2>/dev/null || gh pr create --draft --title "feat: ${feature}"
    pr_url=$(gh pr view --json url -q .url 2>/dev/null || echo "")
    run_critic pr-review review "PR: ${pr_url}. Plan: ${PLAN}." || {
      rc=$?
      [[ $rc -eq 0 ]] || { echo "[BLOCKED] pr-review failed" >&2; exit 1; }
    }
    bash "$PF" transition "$PLAN" green "pr-review converged — feature complete"

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
    spec_path=$(git status --porcelain 2>/dev/null | grep 'spec\.md' | awk '{print $2}' | head -1 || true)
    [[ -n "$spec_path" ]] && git add "$spec_path" && git commit -m "feat(spec): add BDD scenarios for ${feature}"
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
  [[ -n "$UNIT_CMD" ]] && bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD"

  bash "$PF" reset-milestone "$PLAN" critic-code
  run_critic critic-code implement "Review changed files. Plan: ${PLAN}."
  llm_exit "critic-code"

  bash "$PF" transition "$PLAN" review "critic-code converged — starting pr-review"
  bash "$PF" reset-pr-review "$PLAN"
  gh pr view 2>/dev/null || gh pr create --draft --title "feat: ${SLUG}"
  pr_url=$(gh pr view --json url -q .url 2>/dev/null || echo "")
  run_critic pr-review review "PR: ${pr_url}. Plan: ${PLAN}."
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
