#!/usr/bin/env bash
# Phase helpers for run-dev-cycle.sh — extracted to keep the orchestrator under 200 lines.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_DEV_CYCLE_PHASES_LOADED:-}" ]] && return 0
_DEV_CYCLE_PHASES_LOADED=1

# All functions use globals set by run-dev-cycle.sh:
#   PF PLAN PROJECT_DIR SCRIPTS_DIR UNIT_CMD _lang _domain_root _infra_root _features_root

# _phase_spec_prepass — write spec and run critic-spec for each feature (skip if converged).
_phase_spec_prepass() {
  while IFS= read -r feature; do
    [[ -z "$feature" ]] && continue
    local feat_slug _spec_path _new_specs _spec_for_critic _other_specs _csp _cross_ctx _sp_file _rev_marker
    feat_slug=$(_slugify_feature "$feature")
    _spec_path=$(find_spec_path "$feat_slug")
    # Per-feature marker avoids false-skip: global is-converged scope would let A's convergence skip B.
    _rev_marker="${PLAN%.md}.state/spec-reviewed-${feat_slug}"
    [[ -f "$_spec_path" ]] && git ls-files --error-unmatch "$_spec_path" 2>/dev/null && \
      [[ -f "$_rev_marker" ]] && continue

    if [[ ! -f "$_spec_path" ]]; then
      run_llm "Invoke the writing-spec skill for feature: ${feature}. Plan: ${PLAN}." opus
      llm_exit "writing-spec"
    fi

    _new_specs=$(git status --porcelain 2>/dev/null \
      | awk '$0 ~ /spec\.md$/{print $NF}' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    _spec_for_critic="${_new_specs:-$(find_spec_path "$feat_slug")}"

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
    touch "$_rev_marker" 2>/dev/null || true

    while IFS= read -r _sp_file; do
      [[ -n "$_sp_file" ]] && git add "$_sp_file"
    done < <(git status --porcelain 2>/dev/null | grep 'spec\.md' | awk '{print $2}')
    git diff --cached --quiet || git commit -m "feat(spec): add BDD scenarios for ${feature}"
  done < <(get_features)
}

# _phase_cross_spec_review — run critic-cross once across all spec files.
_phase_cross_spec_review() {
  bash "$PF" is-converged "$PLAN" spec critic-cross 2>/dev/null && return 0
  local _all_specs="" _spec_dir _sp
  for _spec_dir in "${PROJECT_DIR}/src/features" "${PROJECT_DIR}/src/domain" "${PROJECT_DIR}/src/infrastructure" \
                   "${PROJECT_DIR}/features" "${PROJECT_DIR}/domain" "${PROJECT_DIR}/infrastructure"; do
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
}

_impl_reset_for_green() {
  local feature="$1"
  local phase_now; phase_now=$(bash "$PF" get-phase "$PLAN")
  [[ "$phase_now" != "green" ]] && return 0
  bash "$PF" reset-pr-review "$PLAN"
  bash "$PF" inter-feature-reset "$PLAN"
  bash "$PF" transition "$PLAN" implement "inter-feature reset: clearing stale implement-phase markers"
  bash "$PF" reset-milestone "$PLAN" critic-code
  bash "$PF" transition "$PLAN" red "inter-feature reset: starting tests for ${feature}"
  bash "$PF" reset-milestone "$PLAN" critic-test
}

_impl_run_test_phase() {
  local feature="$1" feat_slug="$2"
  local phase_now; phase_now=$(bash "$PF" get-phase "$PLAN")
  [[ "$phase_now" == "spec" || "$phase_now" == "red" ]] || return 0
  bash "$PF" is-converged "$PLAN" red critic-test 2>/dev/null && return 0
  run_llm "Invoke the writing-tests skill for feature: ${feature}. Plan: ${PLAN}." sonnet
  llm_exit "writing-tests"
  bash "$PF" reset-milestone "$PLAN" critic-test
  local _test_files; _test_files=$(_recent_test_files)
  run_critic critic-test red "Review tests for feature: ${feature}. Spec: $(find_spec_path "$feat_slug"). Test files: ${_test_files:-tests/}. Plan: ${PLAN}. Test command: ${UNIT_CMD}."
  llm_exit "critic-test"
}

_impl_run_implement_phase() {
  local feature="$1" feat_slug="$2"
  local phase_now has_task_defs pending any_task_in_ledger
  phase_now=$(bash "$PF" get-phase "$PLAN")
  has_task_defs=$(grep -c 'task-definitions-start' "$PLAN" 2>/dev/null) || has_task_defs=0
  if [[ "$phase_now" == "red" && "$has_task_defs" -eq 0 ]]; then
    run_llm "Invoke the implementing skill for feature: ${feature}. Plan: ${PLAN}." opus
    llm_exit "implementing (Step 1)"
  fi
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
  phase_now=$(bash "$PF" get-phase "$PLAN")
  if [[ "$phase_now" == "implement" ]] && \
     ! bash "$PF" is-converged "$PLAN" implement critic-code 2>/dev/null; then
    bash "$PF" reset-milestone "$PLAN" critic-code
    run_critic critic-code implement "Review changed files for feature: ${feature}. Spec: $(find_spec_path "$feat_slug"). Docs: $(docs_paths). Plan: ${PLAN}. language: ${_lang}. domain_root: ${_domain_root}. infra_root: ${_infra_root}. features_root: ${_features_root}."
    llm_exit "critic-code"
  fi
}

_impl_run_review_phase() {
  local feature="$1" feat_slug="$2"
  local phase_now pr_url
  phase_now=$(bash "$PF" get-phase "$PLAN")
  if [[ "$phase_now" == "implement" ]]; then
    bash "$PF" transition "$PLAN" review "critic-code converged — starting pr-review"
    bash "$PF" reset-pr-review "$PLAN"
    gh pr view 2>/dev/null || gh pr create --draft --title "feat: ${feature}"
  fi
  phase_now=$(bash "$PF" get-phase "$PLAN")
  if [[ "$phase_now" == "review" ]] && \
     ! bash "$PF" is-converged "$PLAN" review pr-review 2>/dev/null; then
    pr_url=$(gh pr view --json url -q .url 2>/dev/null || echo "")
    run_critic pr-review review "PR: ${pr_url}. Plan: ${PLAN}." "@reference/pr-review-loop.md §PR-review one-shot iteration"
    llm_exit "pr-review"
  fi
  phase_now=$(bash "$PF" get-phase "$PLAN")
  if [[ "$phase_now" == "review" ]] && \
     bash "$PF" is-converged "$PLAN" review pr-review 2>/dev/null; then
    bash "$PF" transition "$PLAN" green "pr-review converged — feature complete"
    bash "$PF" mark-implemented "$PLAN" "$feat_slug"
    gh pr close --delete-branch --comment "Changes merged via task-by-task workflow" 2>/dev/null || true
  fi
}

# _phase_implement_cycle — implement + review loop for each feature.
_phase_implement_cycle() {
  while IFS= read -r feature; do
    [[ -z "$feature" ]] && continue
    local feat_slug
    feat_slug=$(_slugify_feature "$feature")
    bash "$PF" is-implemented "$PLAN" "$feat_slug" 2>/dev/null && continue
    _impl_reset_for_green "$feature"
    _impl_run_test_phase "$feature" "$feat_slug"
    _impl_run_implement_phase "$feature" "$feat_slug"
    _impl_run_review_phase "$feature" "$feat_slug"
  done < <(get_features)
}
