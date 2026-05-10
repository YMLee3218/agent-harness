#!/usr/bin/env bash
set -euo pipefail
export CLAUDE_PLAN_CAPABILITY=harness
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF="$SCRIPTS_DIR/plan-file.sh"
PROFILE="feature" PLAN="" _CALL_RC=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --profile) PROFILE="$2"; shift 2 ;;
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
UNIT_CMD=$(grep -m1 '^\- Test:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | sed 's/^- Test: *//;s/^`//;s/`.*$//' || echo "")
INTEGRATION_CMD=$(grep -m1 '^\- Integration test:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | sed 's/^- Integration test: *//;s/^`//;s/`.*$//' || echo "")
# Treat unfilled placeholders (from workspace/CLAUDE.md template) as unconfigured
[[ "$UNIT_CMD" == _\(run* ]] && UNIT_CMD=""
[[ "$INTEGRATION_CMD" == _\(run* ]] && INTEGRATION_CMD=""

# Layer boundary context — computed once from project layout and .claude/local.md
_lang=$(grep -m1 '^- Language:' "$PROJECT_DIR/.claude/local.md" 2>/dev/null \
  | sed 's/^- Language: *//;s/ .*//' | tr '[:upper:]' '[:lower:]' \
  | sed 's/python.*/python/;s/typescript.*/ts/;s/javascript.*/ts/;s/kotlin.*/kotlin/;s/java.*/java/;s/go.*/go/;s/rust.*/rust/;s/c#.*/cs/;s/ruby.*/rb/')
_lang="${_lang:-python}"
_domain_root="${PROJECT_DIR}/src/domain"
[[ ! -d "$_domain_root" ]] && _domain_root="${PROJECT_DIR}/domain"
_infra_root="${PROJECT_DIR}/src/infrastructure"
[[ ! -d "$_infra_root" ]] && _infra_root="${PROJECT_DIR}/infrastructure"
_features_root="${PROJECT_DIR}/src/features"
[[ ! -d "$_features_root" ]] && _features_root="${PROJECT_DIR}/features"

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
    *) echo "Script failure: ${label} exited ${rc}" >&2
       [[ -n "${PLAN:-}" ]] && bash "$PF" append-note "$PLAN" "[BLOCKED] script-failure:${label}: exited ${rc}" 2>/dev/null || true
       exit $rc ;;
  esac
}

# Preflight: abort if preflight-blocked (sidecar-first, falls back to plan.md grep)
if [[ -n "$PLAN" ]]; then
  if bash "$PF" is-blocked "$PLAN" preflight 2>/dev/null; then
    echo "[BLOCKED] preflight marker present — resolve and re-run" >&2; exit 1
  fi
fi

# Phase-aware routing when plan exists
if [[ -n "$PLAN" ]]; then
  current_phase=$(bash "$PF" get-phase "$PLAN" 2>/dev/null || echo "")

  # Check for any active BLOCKED markers before proceeding (sidecar-first, falls back to plan.md grep)
  if bash "$PF" is-blocked "$PLAN" 2>/dev/null; then
    echo "[BLOCKED] active block marker present — resolve markers before proceeding" >&2; exit 1
  fi

  case "$current_phase" in
    brainstorm|spec|red|implement|review|green|integration) ;;  # handled below
    done)
      _found_next=0
      for _p in "${PROJECT_DIR}/plans/"*.md; do
        [[ -f "$_p" && "$_p" != "$PLAN" ]] || continue
        _p_phase=$(bash "$PF" get-phase "$_p" 2>/dev/null || echo "")
        if [[ -n "$_p_phase" && "$_p_phase" != "done" ]]; then
          PLAN="$_p"; current_phase="$_p_phase"; _found_next=1; break
        fi
      done
      if [[ $_found_next -eq 0 ]]; then
        echo "[DONE] All requirements complete. Run /brainstorming to start a new requirement." >&2
        exit 0
      fi
      ;;
    *) echo "[BLOCKED] unrecognised plan phase: ${current_phase}" >&2; exit 1 ;;
  esac
fi

# Determine mode
MODE="feature"

# ── Step 1: Brainstorming ────────────────────────────────────────────────────
if [[ -z "$PLAN" ]] || \
   { [[ -n "${current_phase:-}" ]] && [[ "$current_phase" == "brainstorm" ]] && \
     ! bash "$PF" is-converged "$PLAN" brainstorm critic-feature 2>/dev/null; }; then

  run_llm "Invoke the brainstorming skill." opus
  llm_exit "brainstorming"

  PLAN=$(bash "$PF" find-active 2>/dev/null || true)
  [[ -z "$PLAN" ]] && { echo "ERROR: plan file not created by brainstorming" >&2; exit 1; }

  # Insert mode into frontmatter (grep guards against sed exiting 0 on no-match)
  if grep -q '^mode:' "$PLAN" 2>/dev/null; then
    sed -i '' "s/^mode:.*$/mode: ${MODE}/" "$PLAN" 2>/dev/null || true
  else
    awk -v m="${MODE}" '/^---$/ && ++n==2 {print "mode: " m} 1' \
      "$PLAN" > "${PLAN}.tmp" && mv "${PLAN}.tmp" "$PLAN" 2>/dev/null || true
  fi

  bash "$PF" reset-milestone "$PLAN" critic-feature
  run_critic critic-feature brainstorm \
    "Review docs/requirements/$(basename "$PLAN" .md).md."
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
  [[ -f "$REQ_FILE" ]] && echo "${REQ_FILE} ${PROJECT_DIR}/docs/" || echo "${PROJECT_DIR}/docs/"
}

# ── Feature-slice mode ───────────────────────────────────────────────────────

  # integration phase re-entry: skip feature loop, go straight to integration
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
    bash "$PF" append-note "$PLAN" "[BLOCKED] run-dev-cycle: no features in ${REQ_FILE} — run /brainstorming first"
    exit 1
  fi

  # ── Phase 1: Spec pre-pass ─────────────────────────────────────────────────
  # Write spec + run critic-spec for each feature.
  # Skip entirely only when spec written AND critic-spec already converged.
  while IFS= read -r feature; do
    [[ -z "$feature" ]] && continue
    feat_slug=$(printf '%s' "$feature" | tr '[:upper:] ' '[:lower:]-' | tr -dc 'a-z0-9-')
    _spec_path=$(find_spec_path "$feat_slug")
    [[ -f "$_spec_path" ]] && bash "$PF" is-converged "$PLAN" spec critic-spec 2>/dev/null && continue

    if [[ ! -f "$_spec_path" ]]; then
      run_llm "Invoke the writing-spec skill for feature: ${feature}. Plan: ${PLAN}." opus
      llm_exit "writing-spec"
    fi

    # Collect all spec files written by this writing-spec invocation (may include domain/infra specs)
    _new_specs=$(git status --porcelain 2>/dev/null \
      | awk '$0 ~ /spec\.md$/{print $NF}' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    _spec_for_critic="${_new_specs:-$(find_spec_path "$feat_slug")}"

    # Collect previously committed specs for cross-context review (exclude the new specs)
    _other_specs=""
    while IFS= read -r _csp; do
      [[ -z "$_csp" ]] && continue
      printf '%s\n' $_new_specs | grep -qxF "$_csp" && continue
      _other_specs="${_other_specs:+$_other_specs }${_csp}"
    done < <(git ls-files '*/spec.md' 2>/dev/null)
    _cross_ctx=""
    [[ -n "$_other_specs" ]] && \
      _cross_ctx=" Also verify consistency against existing specs: ${_other_specs}."

    bash "$PF" reset-milestone "$PLAN" critic-spec
    run_critic critic-spec spec \
      "Review spec for feature: ${feature}. Spec: ${_spec_for_critic}. Docs: $(docs_paths). Plan: ${PLAN}.${_cross_ctx}"
    llm_exit "critic-spec"

    while IFS= read -r _sp_file; do
      [[ -n "$_sp_file" ]] && git add "$_sp_file"
    done < <(git status --porcelain 2>/dev/null | grep 'spec\.md' | awk '{print $2}')
    git diff --cached --quiet || git commit -m "feat(spec): add BDD scenarios for ${feature}"
  done < <(get_features)

  # ── Phase 2: Cross-feature spec consistency review (once) ──────────────────
  if ! bash "$PF" is-converged "$PLAN" spec critic-cross 2>/dev/null; then
    # Collect all spec files from all layers (feature, domain, infrastructure)
    _all_specs=""
    for _spec_dir in "${PROJECT_DIR}/features" "${PROJECT_DIR}/domain" "${PROJECT_DIR}/infrastructure"; do
      [[ -d "$_spec_dir" ]] || continue
      while IFS= read -r _sp; do
        _all_specs="${_all_specs:+$_all_specs }${_sp}"
      done < <(find "$_spec_dir" -name "spec.md" 2>/dev/null)
    done
    if [[ -n "$_all_specs" ]]; then
      bash "$PF" reset-milestone "$PLAN" critic-cross
      run_critic critic-cross spec \
        "Cross-feature consistency review. All specs: ${_all_specs}. Docs: $(docs_paths). Plan: ${PLAN}."
      llm_exit "critic-cross"
    fi
  fi

  # ── Phase 3: Implement loop (spec phase excluded — handled in pre-pass) ─────
  while IFS= read -r feature; do
    [[ -z "$feature" ]] && continue
    feat_slug=$(printf '%s' "$feature" | tr '[:upper:] ' '[:lower:]-' | tr -dc 'a-z0-9-')

    # Skip features already fully implemented
    bash "$PF" is-implemented "$PLAN" "$feat_slug" 2>/dev/null && continue

    # Inter-feature reset: previous feature just reached green — reset implement/red phases
    phase_now=$(bash "$PF" get-phase "$PLAN")
    if [[ "$phase_now" == "green" ]]; then
      bash "$PF" reset-pr-review "$PLAN"
      bash "$PF" inter-feature-reset "$PLAN"
      bash "$PF" transition "$PLAN" implement "inter-feature reset: clearing stale implement-phase markers"
      bash "$PF" reset-milestone "$PLAN" critic-code
      bash "$PF" transition "$PLAN" red "inter-feature reset: starting tests for ${feature}"
      bash "$PF" reset-milestone "$PLAN" critic-test
    fi

    # Step 2b — Tests
    phase_now=$(bash "$PF" get-phase "$PLAN")
    if [[ "$phase_now" == "spec" || "$phase_now" == "red" ]] && \
       ! bash "$PF" is-converged "$PLAN" red critic-test 2>/dev/null; then
      run_llm "Invoke the writing-tests skill for feature: ${feature}. Plan: ${PLAN}." sonnet
      llm_exit "writing-tests"
      bash "$PF" reset-milestone "$PLAN" critic-test
      _test_files=$(git diff HEAD~1 HEAD --name-only 2>/dev/null | grep -E '^tests/|_test\.' | tr '\n' ' ' || true)
      run_critic critic-test red "Review tests for feature: ${feature}. Spec: $(find_spec_path "$feat_slug"). Test files: ${_test_files:-tests/}. Plan: ${PLAN}. Test command: ${UNIT_CMD}."
      llm_exit "critic-test"
    fi

    # Step 2c — Implement Step 1 (LLM task planning): only when tasks not yet defined
    phase_now=$(bash "$PF" get-phase "$PLAN")
    has_task_defs=$(grep -c 'task-definitions-start' "$PLAN" 2>/dev/null) || has_task_defs=0
    if [[ "$phase_now" == "red" && "$has_task_defs" -eq 0 ]]; then
      run_llm "Invoke the implementing skill for feature: ${feature}. Plan: ${PLAN}." opus
      llm_exit "implementing (Step 1)"
    fi

    # run-implement.sh: execute pending tasks
    phase_now=$(bash "$PF" get-phase "$PLAN")
    has_task_defs=$(grep -c 'task-definitions-start' "$PLAN" 2>/dev/null) || has_task_defs=0
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
       ! bash "$PF" is-converged "$PLAN" implement critic-code 2>/dev/null; then
      bash "$PF" reset-milestone "$PLAN" critic-code
      run_critic critic-code implement "Review changed files for feature: ${feature}. Spec: $(find_spec_path "$feat_slug"). Docs: $(docs_paths). Plan: ${PLAN}. language: ${_lang}. domain_root: ${_domain_root}. infra_root: ${_infra_root}. features_root: ${_features_root}."
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
       ! bash "$PF" is-converged "$PLAN" review pr-review 2>/dev/null; then
      pr_url=$(gh pr view --json url -q .url 2>/dev/null || echo "")
      run_critic pr-review review "PR: ${pr_url}. Plan: ${PLAN}." "@reference/pr-review-loop.md §PR-review one-shot iteration"
      llm_exit "pr-review"
    fi

    # green transition + feature completion marker + PR cleanup
    phase_now=$(bash "$PF" get-phase "$PLAN")
    if [[ "$phase_now" == "review" ]] && \
       bash "$PF" is-converged "$PLAN" review pr-review 2>/dev/null; then
      bash "$PF" transition "$PLAN" green "pr-review converged — feature complete"
      bash "$PF" mark-implemented "$PLAN" "$feat_slug"
      gh pr close --delete-branch --comment "Changes merged via task-by-task workflow" 2>/dev/null || true
    fi

  done < <(get_features)

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
