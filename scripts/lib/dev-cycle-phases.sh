#!/usr/bin/env bash
# Phase helpers for run-dev-cycle.sh — extracted to keep the orchestrator under 200 lines.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_DEV_CYCLE_PHASES_LOADED:-}" ]] && return 0
_DEV_CYCLE_PHASES_LOADED=1

# All functions use globals set by run-dev-cycle.sh:
#   PF PLAN PROJECT_DIR SCRIPTS_DIR UNIT_CMD LINT_CMD _lang _domain_root _infra_root _features_root

# _finalize_pr SLUG — idempotent: closes the plan's PR after merge into main.
# No-op if plan is not done or PR is not OPEN.
_finalize_pr() {
  local _slug="$1"
  [[ "$(bash "$PF" get-phase "$PLAN")" == "done" ]] || return 0
  [[ "$(gh pr view "feature/${_slug}" --json state -q .state 2>/dev/null || echo)" == "OPEN" ]] || return 0
  gh pr close "feature/${_slug}" --delete-branch --comment "Merged into main via merge gate" 2>/dev/null || true
}

# _phase_spec_prepass — write spec and run critic-spec for each feature (skip if converged).
_phase_spec_prepass() {
  while IFS= read -r feature; do
    [[ -z "$feature" ]] && continue
    local feat_slug _spec_path _new_specs _spec_for_critic _other_specs _csp _cross_ctx _sp_file _rev_marker
    feat_slug=$(_slugify_feature "$feature")
    _spec_path=$(find_spec_path "$feat_slug")
    # Per-feature marker avoids false-skip: global is-converged scope would let A's convergence skip B.
    _rev_marker="${PLAN%.md}.state/spec-reviewed-${feat_slug}"
    [[ -f "$_spec_path" ]] && git -C "$PROJECT_DIR" ls-files --error-unmatch "$_spec_path" 2>/dev/null && \
      [[ -z "$(git -C "$PROJECT_DIR" status --porcelain "$_spec_path" 2>/dev/null)" ]] && \
      [[ -f "$_rev_marker" ]] && continue

    if [[ ! -f "$_spec_path" ]]; then
      WRITING_SPEC_PLAN_PATH="${PLAN}" \
      WRITING_SPEC_ENVELOPE="" \
      run_llm "Invoke the writing-spec skill for feature: ${feature}. Plan: ${PLAN}." opus
      llm_exit "writing-spec"
    fi

    # Ensure plan is in "spec" before critic-spec runs so record-verdict stores verdicts
    # in the correct "spec/critic-spec" scope. writing-spec skill runs via run_llm which
    # strips CLAUDE_PLAN_CAPABILITY; it cannot call plan-file.sh transition (Ring B).
    # The harness does the transition here for both the new-spec and skipped-spec paths.
    local _ph; _ph=$(bash "$PF" get-phase "$PLAN" 2>/dev/null || echo "")
    if [[ "$_ph" == "brainstorm" ]]; then
      bash "$PF" transition "$PLAN" spec "spec already committed — advancing to spec phase for critic-spec"
    elif [[ "$_ph" != "spec" ]]; then
      # Plan is past spec phase; spec was already reviewed in a prior run.
      # Recreate rev_marker to prevent re-entry on next run and skip.
      touch "$_rev_marker" 2>/dev/null || true
      continue
    fi

    _new_specs=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null \
      | awk '$0 ~ /spec\.md$/{print $NF}' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    _spec_for_critic="${_new_specs:-$(find_spec_path "$feat_slug")}"

    _other_specs=""
    while IFS= read -r _csp; do
      [[ -z "$_csp" ]] && continue
      printf '%s\n' $_new_specs | grep -qxF "$_csp" && continue
      _other_specs="${_other_specs:+$_other_specs }${_csp}"
    done < <(git -C "$PROJECT_DIR" ls-files '*/spec.md' 2>/dev/null)
    _cross_ctx=""
    [[ -n "$_other_specs" ]] && \
      _cross_ctx=" Also verify consistency against existing specs: ${_other_specs}."

    bash "$PF" reset-milestone "$PLAN" critic-spec
    bash "$PF" reset-milestone "$PLAN" critic-cross 2>/dev/null || true
    rm -f "$_rev_marker" 2>/dev/null || true
    CRITIC_SPEC_PATH="${_spec_for_critic}" \
    CRITIC_DOCS_PATHS="$(docs_paths)" \
    CRITIC_PLAN_PATH="${PLAN}" \
    run_critic critic-spec spec \
      "Review spec for feature: ${feature}. Spec: ${_spec_for_critic}. Docs: $(docs_paths). Plan: ${PLAN}.${_cross_ctx}"
    llm_exit "critic-spec"
    touch "$_rev_marker" 2>/dev/null || true

    while IFS= read -r _sp_file; do
      [[ -n "$_sp_file" ]] && git -C "$PROJECT_DIR" add "$_sp_file"
    done < <(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | awk '{print $NF}' \
             | grep -E '(^|/)spec\.md$|\.spec\.md$')
    git -C "$PROJECT_DIR" diff --cached --quiet || \
      git -C "$PROJECT_DIR" commit -m "feat(spec): add BDD scenarios for ${feature}"
  done < <(get_features)
}

# _phase_domain_infra_spec_review — run critic-spec independently for each domain/infra spec.md.
_phase_domain_infra_spec_review() {
  local _di_specs _spec_rel _spec _layer _slug _rev_marker _ph

  # Collect domain/ + infrastructure/ spec.md from both untracked/modified and committed files.
  _di_specs=$(
    {
      git -C "$PROJECT_DIR" status --porcelain 2>/dev/null \
        | awk '$0 ~ /spec\.md$/{print $NF}' \
        | grep -E '^(src/)?(domain|infrastructure)/' || true
      git -C "$PROJECT_DIR" ls-files '*/spec.md' 2>/dev/null \
        | grep -E '^(src/)?(domain|infrastructure)/' || true
    } | sort -u
  )

  [[ -z "$_di_specs" ]] && return 0

  while IFS= read -r _spec_rel; do
    [[ -z "$_spec_rel" ]] && continue
    _spec="${PROJECT_DIR}/${_spec_rel}"
    _layer=$(printf '%s' "$_spec_rel" | sed 's|^src/||' | cut -d/ -f1)
    _slug=$(printf '%s' "$_spec_rel"  | sed 's|^src/||' | cut -d/ -f2)
    _rev_marker="${PLAN%.md}.state/spec-reviewed-${_layer}-${_slug}"

    # Skip if spec is already committed (clean, no uncommitted changes) AND review marker exists.
    git -C "$PROJECT_DIR" ls-files --error-unmatch "$_spec_rel" 2>/dev/null && \
      [[ -z "$(git -C "$PROJECT_DIR" status --porcelain "$_spec_rel" 2>/dev/null)" ]] && \
      [[ -f "$_rev_marker" ]] && continue

    # Ensure plan is in spec phase before critic-spec runs.
    _ph=$(bash "$PF" get-phase "$PLAN" 2>/dev/null || echo "")
    if [[ "$_ph" == "brainstorm" ]]; then
      bash "$PF" transition "$PLAN" spec "advancing to spec phase for ${_layer}/${_slug} critic-spec"
    elif [[ "$_ph" != "spec" ]]; then
      touch "$_rev_marker" 2>/dev/null || true
      continue
    fi

    bash "$PF" reset-milestone "$PLAN" critic-spec
    bash "$PF" reset-milestone "$PLAN" critic-cross 2>/dev/null || true
    rm -f "$_rev_marker" 2>/dev/null || true
    CRITIC_SPEC_PATH="${_spec}" \
    CRITIC_DOCS_PATHS="$(docs_paths)" \
    CRITIC_PLAN_PATH="${PLAN}" \
    run_critic critic-spec spec \
      "Review spec for ${_layer} concept: ${_slug}. Spec: ${_spec}. Docs: $(docs_paths). Plan: ${PLAN}."
    llm_exit "critic-spec"
    touch "$_rev_marker" 2>/dev/null || true

    git -C "$PROJECT_DIR" add "$_spec_rel" 2>/dev/null || true
    git -C "$PROJECT_DIR" diff --cached --quiet || \
      git -C "$PROJECT_DIR" commit -m "feat(spec): add BDD scenarios for ${_layer}/${_slug}"
  done <<< "$_di_specs"
}

# _phase_cross_spec_review — run critic-cross once across all spec files.
_phase_cross_spec_review() {
  bash "$PF" is-converged "$PLAN" spec critic-cross 2>/dev/null && return 0
  # Ensure plan is in spec phase before running critic-cross so record-verdict writes
  # to the spec/critic-cross scope that this function's is-converged check reads.
  local _cph; _cph=$(bash "$PF" get-phase "$PLAN" 2>/dev/null || echo "")
  if [[ "$_cph" == "brainstorm" ]]; then
    bash "$PF" transition "$PLAN" spec "advancing to spec phase for critic-cross"
  elif [[ "$_cph" != "spec" ]]; then
    return 0  # Past spec phase; cross-spec was already reviewed in a prior run
  fi
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
    CRITIC_ALL_SPEC_PATHS="${_all_specs}" \
    CRITIC_DOCS_PATHS="$(docs_paths)" \
    CRITIC_PLAN_PATH="${PLAN}" \
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

# _green_preexisting_integrity_gate SINCE_SHA — Tier-1 deterministic enforcement of the
# critic-test SKILL.md Check 4 rule. Every test marked "→ GREEN (pre-existing)" in the plan
# must live in a test file that already EXISTED before this unit's test phase began
# (SINCE_SHA = _pre_test_sha, the HEAD captured before writing-tests ran). A file absent at
# SINCE_SHA was (re)created during this Red phase, so a GREEN claim on it means the worker
# self-declared pre-existing to skip implementation — block it. Re-derived from git every
# iteration, so no plan note / REVIEW-NOTE can clear it.
_green_preexisting_integrity_gate() {
  local _since="$1" _green_files _gf _bad=""
  [[ -z "$_since" ]] && return 0   # no baseline → cannot prove; matches SKILL.md degraded SKIP
  # Extract unique test-file paths from every "→ GREEN (pre-existing)" line in the plan.
  # Match all supported test-file patterns, not just tests/ prefix.
  _green_files=$(grep -F '→ GREEN (pre-existing)' "$PLAN" 2>/dev/null \
    | grep -oE '[^[:space:]|:]+' \
    | grep -E '(^|/)tests/|(^|/)conftest\.|_test\.|(^|/)test_|\.test\.|\.spec\.|_spec\.' \
    | grep -v 'spec\.md$' | sort -u || true)
  [[ -z "$_green_files" ]] && return 0
  while IFS= read -r _gf; do
    [[ -z "$_gf" ]] && continue
    # File must have existed in the tree at SINCE_SHA to legitimately be "pre-existing".
    git -C "$PROJECT_DIR" cat-file -e "${_since}:${_gf}" 2>/dev/null || _bad="${_bad:+${_bad} }${_gf}"
  done <<< "$_green_files"
  if [[ -n "$_bad" ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] green-preexisting-integrity — file(s) [${_bad}] marked → GREEN (pre-existing) but did not exist before this unit's Red phase (created in/after test(red): commit). A pre-existing claim requires the test file to predate the Red phase. Resolution: implement the unit so its tests are genuinely RED; OR if reverting the unit, delete the corresponding implementation per reference/phase-ops.md so the tests fail. Fix the root cause before running plan-file.sh unblock."
    exit 1
  fi
}

_impl_run_test_phase() {
  local feature="$1" feat_slug="$2"
  local _spec_path="${3:-}"
  [[ -z "$_spec_path" ]] && _spec_path="$(find_spec_path "$feat_slug")"
  # Per-feature marker must precede the global phase guard.
  # Phase guard first causes the same false-skip as the old is-converged check:
  # Feature A's implement step advancing phase to "implement" skips Feature B's test
  # phase in the same loop iteration even when B's marker is absent.
  local _test_marker="${PLAN%.md}.state/test-reviewed-${feat_slug}"
  [[ -f "$_test_marker" ]] && return 0
  local phase_now; phase_now=$(bash "$PF" get-phase "$PLAN")
  # Transition to red before run_llm: writing-tests runs with CLAUDE_PLAN_CAPABILITY stripped
  # and cannot call plan-file.sh transition from within the session.
  if [[ "$phase_now" == "spec" ]]; then
    bash "$PF" transition "$PLAN" red "entering test phase for ${feature}"
  elif [[ "$phase_now" != "red" ]]; then
    bash "$PF" transition "$PLAN" red "entering test phase for ${feature} — resetting from ${phase_now}"
  fi
  if [[ -z "$UNIT_CMD" ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED:env] run-dev-cycle: no-unit-test-cmd — add '- Test: {cmd}' to CLAUDE.md"
    exit 1
  fi
  local _pre_test_sha; _pre_test_sha=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "")
  WRITING_TESTS_SPEC_PATH="$_spec_path" \
  WRITING_TESTS_PLAN_PATH="${PLAN}" \
  WRITING_TESTS_COMMAND="${UNIT_CMD}" \
  run_llm "Invoke the writing-tests skill for feature: ${feature}. Plan: ${PLAN}." sonnet
  llm_exit "writing-tests"
  # Worker cannot commit (git common dir is outside PROJ_ROOT → Tier 1 EPERM).
  # Commit test files from the orchestrator — same pattern as spec/critic-test commits below.
  while IFS= read -r _tf_file; do
    [[ -n "$_tf_file" ]] && git -C "$PROJECT_DIR" add "$_tf_file"
  done < <(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | awk '{print $NF}' \
           | grep -E '(^|/)tests/|(^|/)conftest\.|_test\.|(^|/)test_|\.test\.|\.spec\.|_spec\.' \
           | grep -v '\.spec\.md$')
  git -C "$PROJECT_DIR" diff --cached --quiet || \
    git -C "$PROJECT_DIR" commit -m "test(red): add failing tests for ${feature}"
  bash "$PF" reset-milestone "$PLAN" critic-test
  local _test_files; _test_files=$(_recent_test_files "$_pre_test_sha")
  if [[ -z "$_test_files" ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED:env] critic-test: cannot-derive-test-files — ${feature}: no test(red): commit found in ${_pre_test_sha}..HEAD; re-run writing-tests"
    exit 1
  fi
  _green_preexisting_integrity_gate "$_pre_test_sha"
  CRITIC_SPEC_PATH="$_spec_path" \
  CRITIC_TEST_FILES="${_test_files}" \
  CRITIC_PLAN_PATH="${PLAN}" \
  CRITIC_TEST_COMMAND="${UNIT_CMD}" \
  run_critic critic-test red "Review tests for feature: ${feature}. Spec: ${_spec_path}. Test files: ${_test_files}. Plan: ${PLAN}. Test command: ${UNIT_CMD}."
  llm_exit "critic-test"
  # critic-test fixes tests in-place (no commit). Commit them now so the implement worktree
  # (branched from HEAD) sees the corrected files, and so the integrity baseline is updated.
  # Same pattern as spec phase committing critic-spec fixes above.
  while IFS= read -r _tf_file; do
    [[ -n "$_tf_file" ]] && git -C "$PROJECT_DIR" add "$_tf_file"
  done < <(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | awk '{print $NF}' \
           | grep -E '(^|/)tests/|(^|/)conftest\.|_test\.|(^|/)test_|\.test\.|\.spec\.|_spec\.' | grep -v '\.spec\.md$')
  git -C "$PROJECT_DIR" diff --cached --quiet || \
    git -C "$PROJECT_DIR" commit -m "test(red): apply critic-test fixes for ${feature}"
  touch "$_test_marker" 2>/dev/null || true
}

_impl_run_implement_phase() {
  local feature="$1" feat_slug="$2"
  local _spec_path="${3:-}"
  [[ -z "$_spec_path" ]] && _spec_path="$(find_spec_path "$feat_slug")"
  local phase_now has_task_defs pending any_task_in_ledger
  # Per-feature marker must precede phase guards — same false-skip pattern as _impl_run_test_phase.
  # When _impl_reset_for_green fires (phase==green) it deletes _code_marker via inter-feature-reset;
  # this early-return is needed for re-entry where reset did NOT fire (phase!=green) and the marker
  # survived — without it the implement phase leaves phase at red and _impl_run_review_phase skips.
  local _code_marker="${PLAN%.md}.state/code-reviewed-${feat_slug}"
  if [[ -f "$_code_marker" ]]; then
    phase_now=$(bash "$PF" get-phase "$PLAN")
    [[ "$phase_now" != "implement" && "$phase_now" != "review" && "$phase_now" != "green" ]] && \
      bash "$PF" transition "$PLAN" implement "implement re-entry: code already reviewed for ${feature}"
    return 0
  fi
  phase_now=$(bash "$PF" get-phase "$PLAN")
  has_task_defs=$(grep -c 'task-definitions-start' "$PLAN" 2>/dev/null) || has_task_defs=0
  if [[ "$has_task_defs" -gt 0 ]]; then
    local bound_unit; bound_unit=$(bash "$PF" get-task-unit "$PLAN")
    if [[ -n "$bound_unit" && "$bound_unit" != "$feat_slug" ]]; then
      echo "[implement] stale task-defs bound to '${bound_unit}', current unit '${feat_slug}' — clearing" >&2
      bash "$PF" clear-task-state "$PLAN"
      bash "$PF" append-note "$PLAN" "[AUTO-DECIDED] implement: cleared-stale-task-defs — leftover from interrupted unit '${bound_unit}' discarded before implementing '${feat_slug}'"
      has_task_defs=0
    else
      # Same-slug re-entry trap: task-defs exist, all ledger rows completed, no pending.
      # This occurs when smoke failed after run-implement succeeded — the manifest gate checks
      # whether the coverage gap (multi-file RED not all represented in task failing_tests)
      # is the cause. If so, clear task state so Step 1 replays below.
      local _trap_pending _trap_any
      _trap_pending=$(awk '/^## Task Ledger/{f=1;next} f&&/^## /{exit} f&&/\| pending[ |]|\| in_progress[ |]|\| blocked[ |]/' "$PLAN" 2>/dev/null || true)
      _trap_any=$(awk '/^## Task Ledger$/{f=1;next} f&&/^## /{exit} f&&/\| (pending|in_progress|completed|blocked)[ |]/{print;exit}' "$PLAN" 2>/dev/null || true)
      if [[ -z "$_trap_pending" && -n "$_trap_any" && ! -f "$_code_marker" ]]; then
        _manifest_reconciliation_gate "$_spec_path" "$feat_slug" || has_task_defs=0
      fi
    fi
  fi
  for (( _impl_attempt=1; _impl_attempt <= ${CLAUDE_MANIFEST_RECONCILE_MAX:-2} + 1; _impl_attempt++ )); do
    phase_now=$(bash "$PF" get-phase "$PLAN")
    has_task_defs=$(grep -c 'task-definitions-start' "$PLAN" 2>/dev/null) || has_task_defs=0
    if [[ ( "$phase_now" == "red" || "$phase_now" == "implement" ) && "$has_task_defs" -eq 0 ]]; then
      IMPLEMENTING_SPEC_PATH="$_spec_path" \
      IMPLEMENTING_PLAN_PATH="${PLAN}" \
      run_llm "Invoke the implementing skill for feature: ${feature}. Plan: ${PLAN}." opus
      llm_exit "implementing (Step 1)"
      bash "$PF" set-task-unit "$PLAN" "$feat_slug"
    fi
    phase_now=$(bash "$PF" get-phase "$PLAN")
    has_task_defs=$(grep -c 'task-definitions-start' "$PLAN" 2>/dev/null) || has_task_defs=0
    # Guard: implementing skill ran but produced no JSON marker block
    if [[ ( "$phase_now" == "red" || "$phase_now" == "implement" ) && "$has_task_defs" -eq 0 ]]; then
      bash "$PF" append-note "$PLAN" \
        "[BLOCKED:code] implement: missing-task-definitions-markers — implementing skill ran but did not write <!-- task-definitions-start --> JSON block; re-run the implementing skill"
      exit 1
    fi
    pending=$(awk '/^## Task Ledger/{f=1;next} f&&/^## /{exit} f&&/\| pending[ |]|\| in_progress[ |]|\| blocked[ |]/' "$PLAN" 2>/dev/null || true)
    any_task_in_ledger=$(awk '/^## Task Ledger$/{f=1;next} f&&/^## /{exit} f&&/\| (pending|in_progress|completed|blocked)[ |]/{print;exit}' "$PLAN" 2>/dev/null || true)
    if [[ ( "$phase_now" == "red" || "$phase_now" == "implement" ) && \
          ( -n "$pending" || ( "$has_task_defs" -gt 0 && -z "$any_task_in_ledger" ) ) ]]; then
      if [[ -z "$UNIT_CMD" ]]; then
        bash "$PF" append-note "$PLAN" "[BLOCKED:env] run-implement: no-unit-test-cmd — add '- Test: {cmd}' to CLAUDE.md"
        exit 1
      fi
      _spec_coverage_gate "$_spec_path" "$feat_slug"
      _scenario_count_gate "$_spec_path"
      _manifest_reconciliation_gate "$_spec_path" "$feat_slug" || continue
      bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD" --lint-cmd "$LINT_CMD"
    fi
    break
  done
  phase_now=$(bash "$PF" get-phase "$PLAN")
  if [[ "$phase_now" == "implement" ]] && \
     [[ ! -f "$_code_marker" ]]; then
    bash "$PF" reset-milestone "$PLAN" critic-code
    CRITIC_SPEC_PATH="$_spec_path" \
    CRITIC_DOCS_PATHS="$(docs_paths)" \
    CRITIC_PLAN_PATH="${PLAN}" \
    CRITIC_LANGUAGE="${_lang}" \
    CRITIC_DOMAIN_ROOT="${_domain_root}" \
    CRITIC_INFRA_ROOT="${_infra_root}" \
    CRITIC_FEATURES_ROOT="${_features_root}" \
    run_critic critic-code implement "Review changed files for feature: ${feature}. Spec: ${_spec_path}. Docs: $(docs_paths). Plan: ${PLAN}. language: ${_lang}. domain_root: ${_domain_root}. infra_root: ${_infra_root}. features_root: ${_features_root}."
    llm_exit "critic-code"
    touch "$_code_marker" 2>/dev/null || true
  fi
}

_impl_run_review_phase() {
  local feature="$1" feat_slug="$2"
  local phase_now pr_url
  # Per-feature marker avoids false-skip: global is-converged scope would let A's convergence skip B.
  local _review_marker="${PLAN%.md}.state/pr-reviewed-${feat_slug}"
  phase_now=$(bash "$PF" get-phase "$PLAN")
  if [[ "$phase_now" == "implement" ]]; then
    bash "$PF" transition "$PLAN" review "critic-code converged — starting pr-review"
    bash "$PF" reset-pr-review "$PLAN"
    if ! gh pr view 2>/dev/null; then
      local pr_log="${PLAN%.md}.state/pr-create.log"
      if ! git push -u origin HEAD >"$pr_log" 2>&1 \
         || ! gh pr create --draft --title "feat: ${feature}" --fill >>"$pr_log" 2>&1; then
        bash "$PF" append-note "$PLAN" "[BLOCKED:env] run-dev-cycle: pr-create-failed — see ${pr_log##*/}; resolve (push/remote/auth) then re-run"
        exit 1
      fi
    fi
  fi
  phase_now=$(bash "$PF" get-phase "$PLAN")
  if [[ "$phase_now" == "review" ]] && \
     [[ ! -f "$_review_marker" ]]; then
    if ! git push origin HEAD >>"${PLAN%.md}.state/pr-create.log" 2>&1; then
      bash "$PF" append-note "$PLAN" "[BLOCKED:env] run-dev-cycle: pr-push-failed — push before pr-review failed; see pr-create.log; resolve (push/remote/auth) then re-run"
      exit 1
    fi
    pr_url=$(gh pr view --json url -q .url 2>/dev/null || echo "")
    run_critic pr-review review "PR: ${pr_url}. Plan: ${PLAN}." "@reference/pr-review-loop.md §PR-review one-shot iteration"
    llm_exit "pr-review"
    touch "$_review_marker" 2>/dev/null || true
  fi
  phase_now=$(bash "$PF" get-phase "$PLAN")
  if [[ "$phase_now" == "review" ]] && \
     [[ -f "$_review_marker" ]]; then
    bash "$PF" transition "$PLAN" green "pr-review converged — feature complete"
    bash "$PF" mark-implemented "$PLAN" "$feat_slug"
  fi
}

# _spec_coverage_gate — block implement if no tracked test files exist for this spec's concept.
# Uses segment-boundary regex to avoid substring false-positives (e.g. slug 'alert' matching
# 'inbound_alert'). Matches both kebab and snake forms of the concept slug to handle either
# naming convention in the tests/ directory.
_spec_coverage_gate() {
  local spec_path="$1" unit_key="$2"
  local _concept _concept_snake _concept_kebab _layer _test_count
  _concept=$(basename "$(dirname "$spec_path")")
  _layer=$(basename "$(dirname "$(dirname "$spec_path")")")
  _concept_snake=$(printf '%s' "$_concept" | tr '-' '_')
  _concept_kebab=$(printf '%s' "$_concept" | tr '_' '-')
  # Segment-boundary matching scoped to layer; avoids cross-layer same-slug contamination.
  _test_count=$(git -C "$PROJECT_DIR" ls-files "tests/" 2>/dev/null \
    | grep -cE "/${_layer}/${_concept_snake}/|/${_layer}/${_concept_kebab}/|/${_layer}/test_${_concept_snake}\.|/${_layer}/test_${_concept_kebab}\." \
    || true)
  if [[ "$_test_count" -eq 0 ]]; then
    bash "$PF" append-note "$PLAN" \
      "[BLOCKED:code] coverage: spec-without-test — ${spec_path}; red-phase MISSING_SCENARIO gate failed for ${unit_key} (harness anomaly) — investigate root cause, do not patch manually"
    exit 1
  fi
}

# _scenario_count_gate — lower-bound check: collected pytest test count must be >= spec scenario count.
# Catches gross under-coverage (e.g. 2 tests vs 30 scenarios) deterministically.
# Only applies when UNIT_CMD includes 'pytest'; other runners require language-specific collection
# flags — do not guess (anti-hallucination policy).
# Exact 1:1 scenario-to-test mapping is intentionally NOT required: Scenario Outline expands to
# N test cases, so collected >= scenarios is the typical passing condition for thorough coverage.
# Whether the tests cover the *correct* scenarios remains critic-test (LLM) responsibility.
_scenario_count_gate() {
  local spec_path="$1"
  if ! printf '%s' "${UNIT_CMD:-}" | grep -qw 'pytest'; then
    echo "[SKIP] scenario-count gate — UNIT_CMD '${UNIT_CMD:-}' does not include pytest; skipping (anti-hallucination: non-pytest collection flags not assumed)" >&2
    return 0
  fi
  local _concept _layer _concept_snake _concept_kebab _spec_scenarios _test_dir _collect_output _collect_rc _test_count
  _concept=$(basename "$(dirname "$spec_path")")
  _layer=$(basename "$(dirname "$(dirname "$spec_path")")")
  _concept_snake=$(printf '%s' "$_concept" | tr '-' '_')
  _concept_kebab=$(printf '%s' "$_concept" | tr '_' '-')
  _spec_scenarios=$(grep -cE '^[[:space:]]*(Scenario|Scenario Outline):' "$spec_path" 2>/dev/null) || _spec_scenarios=0
  [[ "$_spec_scenarios" -eq 0 ]] && return 0  # No BDD scenarios in spec — gate not applicable

  local _test_dir_snake="${PROJECT_DIR}/tests/${_layer}/${_concept_snake}"
  local _test_dir_kebab="${PROJECT_DIR}/tests/${_layer}/${_concept_kebab}"
  _test_dir=""
  [[ -d "$_test_dir_snake" ]] && _test_dir="tests/${_layer}/${_concept_snake}"
  [[ -z "$_test_dir" && -d "$_test_dir_kebab" ]] && _test_dir="tests/${_layer}/${_concept_kebab}"
  if [[ -z "$_test_dir" ]]; then
    # No directory layout — also check for single-file layout (test_concept.py at layer root).
    # _spec_coverage_gate accepts this pattern; keep both gates consistent.
    if [[ -f "${_test_dir_snake%/*}/test_${_concept_snake}.py" ]]; then
      _test_dir="tests/${_layer}/test_${_concept_snake}.py"
    elif [[ -f "${_test_dir_kebab%/*}/test_${_concept_kebab}.py" ]]; then
      _test_dir="tests/${_layer}/test_${_concept_kebab}.py"
    else
      return 0  # No tests yet — coverage gate blocked for this case
    fi
  fi

  local _collect_rc=0
  _collect_output=$(cd "$PROJECT_DIR" && ${UNIT_CMD} --collect-only -q "$_test_dir" 2>/dev/null) \
    || _collect_rc=$?
  if [[ "$_collect_rc" -ne 0 ]]; then
    echo "[SKIP] scenario-count gate — pytest collection failed (rc=${_collect_rc}); collection failure is not under-coverage (likely RED-phase import error)" >&2
    return 0
  fi
  # Count lines containing '::' — each collected test item appears as path::testname
  _test_count=$(printf '%s\n' "$_collect_output" | grep -cE '::[a-zA-Z]' || true)
  if [[ "$_test_count" -lt "$_spec_scenarios" ]]; then
    bash "$PF" append-note "$PLAN" \
      "[BLOCKED:code] coverage: under-scenario-count — ${spec_path}; ${_test_count} tests < ${_spec_scenarios} scenarios — manual investigation required"
    exit 1
  fi
}

# _manifest_reconciliation_gate SPEC_PATH UNIT_KEY — verify every RED manifest file for this unit
# is covered by at least one task's failing_test. Returns 0 when all covered or no RED entries exist.
# On uncovered files: increments .state/manifest-reconcile-<unit>.attempts counter;
# if counter <= CLAUDE_MANIFEST_RECONCILE_MAX (default 2): clears task state and returns 1
# (callers should replay Step 1); if counter exceeds max: appends BLOCKED note and exits 1.
_manifest_reconciliation_gate() {
  local spec_path="$1" unit_key="$2"
  local _concept _concept_snake _concept_kebab _layer
  _concept=$(basename "$(dirname "$spec_path")")
  _layer=$(basename "$(dirname "$(dirname "$spec_path")")")
  _concept_snake=$(printf '%s' "$_concept" | tr '-' '_')
  _concept_kebab=$(printf '%s' "$_concept" | tr '_' '-')

  # Gate only applies when UNIT_CMD includes 'pytest'; other runners (go test, cargo test)
  # use empty failing_test fields by design (implementing/SKILL.md) — skip for those.
  if ! printf '%s' "${UNIT_CMD:-}" | grep -qw 'pytest'; then
    return 0
  fi

  # Collect RED manifest files scoped to this unit and layer (skip GREEN/pre-existing entries).
  # Manifest entry format: "- tests/path/file.py::test_name → RED"
  local _red_files
  _red_files=$(awk '/^## Test Manifest/{f=1;next} f&&/^## /{exit} f&&/→ RED/ && !/GREEN/{n=split($2,parts,"::"); print parts[1]}' "$PLAN" 2>/dev/null \
    | grep -E "/${_layer}/${_concept_snake}/|/${_layer}/${_concept_kebab}/|/${_layer}/test_${_concept_snake}\.|/${_layer}/test_${_concept_kebab}\." \
    | sort -u || true)

  [[ -z "$_red_files" ]] && return 0

  # Collect failing_test file paths from task-defs JSON.
  local _task_files
  _task_files=$(awk '/<!-- task-definitions-start -->/{f=1;next} /<!-- task-definitions-end -->/{f=0} f' "$PLAN" 2>/dev/null \
    | jq -r '.[] | (.failing_test // "") | split("::")[0]' 2>/dev/null \
    | grep -v '^$' | sort -u || true)

  # Find RED files not covered by any task.
  local _uncovered=""
  while IFS= read -r _rf; do
    [[ -z "$_rf" ]] && continue
    printf '%s\n' "$_task_files" | grep -qxF "$_rf" && continue
    _uncovered="${_uncovered:+${_uncovered} }${_rf}"
  done <<< "$_red_files"

  [[ -z "$_uncovered" ]] && return 0

  # Uncovered RED files detected — manage retry counter.
  local _state_dir _attempts_file _attempts _max_attempts
  _state_dir="${PLAN%.md}.state"
  mkdir -p "$_state_dir" 2>/dev/null || true
  _attempts_file="${_state_dir}/manifest-reconcile-${unit_key}.attempts"
  _attempts=0
  [[ -f "$_attempts_file" ]] && _attempts=$(cat "$_attempts_file" 2>/dev/null || echo 0)
  _attempts=$(( _attempts + 1 ))
  printf '%d\n' "$_attempts" > "$_attempts_file"

  _max_attempts="${CLAUDE_MANIFEST_RECONCILE_MAX:-2}"
  if [[ "$_attempts" -le "$_max_attempts" ]]; then
    bash "$PF" clear-task-state "$PLAN"
    bash "$PF" append-note "$PLAN" "[AUTO-DECIDED] reconcile: replanning — RED file(s) [${_uncovered}] not covered by any task failing_test (attempt ${_attempts}/${_max_attempts}); cleared task state for Step 1 replay"
    return 1
  else
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] reconcile: manifest-coverage-incomplete — RED file(s) [${_uncovered}] not covered by any task failing_test after ${_max_attempts} replanning attempts; implementing skill is not generating per-RED-file task coverage — investigate root cause, do not patch manually"
    exit 1
  fi
}

# _phase_domain_infra_implement_cycle — write tests, implement, and review each domain/infra unit.
# Runs before _phase_implement_cycle so domain prereqs exist when features implement.
# Uses ${layer}-${slug} as the marker key to avoid collisions with same-named features.
_phase_domain_infra_implement_cycle() {
  local _di_specs _spec_rel _spec _layer _slug _unit_key

  _di_specs=$(
    {
      git -C "$PROJECT_DIR" status --porcelain 2>/dev/null \
        | awk '$0 ~ /spec\.md$/{print $NF}' \
        | grep -E '^(src/)?(domain|infrastructure)/' || true
      git -C "$PROJECT_DIR" ls-files '*/spec.md' 2>/dev/null \
        | grep -E '^(src/)?(domain|infrastructure)/' || true
    } | sort -u
  )
  [[ -z "$_di_specs" ]] && return 0

  while IFS= read -r _spec_rel; do
    [[ -z "$_spec_rel" ]] && continue
    _spec="${PROJECT_DIR}/${_spec_rel}"
    _layer=$(printf '%s' "$_spec_rel" | sed 's|^src/||' | cut -d/ -f1)
    _slug=$(printf '%s' "$_spec_rel"  | sed 's|^src/||' | cut -d/ -f2)
    _unit_key="${_layer}-${_slug}"

    bash "$PF" is-implemented "$PLAN" "$_unit_key" 2>/dev/null && continue
    _impl_reset_for_green "${_layer}/${_slug}"
    _impl_run_test_phase "${_layer}/${_slug}" "$_unit_key" "$_spec"
    _impl_run_implement_phase "${_layer}/${_slug}" "$_unit_key" "$_spec"
    _impl_run_review_phase "${_layer}/${_slug}" "$_unit_key"
  done <<< "$_di_specs"
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
