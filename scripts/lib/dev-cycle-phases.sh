#!/usr/bin/env bash
# Phase helpers for run-dev-cycle.sh — extracted to keep the orchestrator under 200 lines.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_DEV_CYCLE_PHASES_LOADED:-}" ]] && return 0
_DEV_CYCLE_PHASES_LOADED=1

# All functions use globals set by run-dev-cycle.sh:
#   PF PLAN PROJECT_DIR SCRIPTS_DIR UNIT_CMD LINT_CMD _lang _domain_root _infra_root _features_root

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
    bash "$PF" clear-converged "$PLAN" critic-cross 2>/dev/null || true
    rm -f "$_rev_marker" 2>/dev/null || true
    CRITIC_SPEC_PATH="${_spec_for_critic}" \
    CRITIC_DOCS_PATHS="$(docs_paths)" \
    CRITIC_PLAN_PATH="${PLAN}" \
    run_critic critic-spec spec \
      "Review spec for feature: ${feature}. Spec: ${_spec_for_critic}. Docs: $(docs_paths). Plan: ${PLAN}.${_cross_ctx}"
    llm_exit "critic-spec"
    touch "$_rev_marker" 2>/dev/null || true
    git -C "$PROJECT_DIR" add "$_rev_marker" 2>/dev/null || true

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
    bash "$PF" clear-converged "$PLAN" critic-cross 2>/dev/null || true
    rm -f "$_rev_marker" 2>/dev/null || true
    CRITIC_SPEC_PATH="${_spec}" \
    CRITIC_DOCS_PATHS="$(docs_paths)" \
    CRITIC_PLAN_PATH="${PLAN}" \
    run_critic critic-spec spec \
      "Review spec for ${_layer} concept: ${_slug}. Spec: ${_spec}. Docs: $(docs_paths). Plan: ${PLAN}."
    llm_exit "critic-spec"
    touch "$_rev_marker" 2>/dev/null || true

    git -C "$PROJECT_DIR" add "$_spec_rel" "$_rev_marker" 2>/dev/null || true
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
  bash "$PF" reset-milestone "$PLAN" critic-test
  local _test_files; _test_files=$(_recent_test_files "$_pre_test_sha")
  CRITIC_SPEC_PATH="$_spec_path" \
  CRITIC_TEST_FILES="${_test_files:-tests/}" \
  CRITIC_PLAN_PATH="${PLAN}" \
  CRITIC_TEST_COMMAND="${UNIT_CMD}" \
  run_critic critic-test red "Review tests for feature: ${feature}. Spec: ${_spec_path}. Test files: ${_test_files:-tests/}. Plan: ${PLAN}. Test command: ${UNIT_CMD}."
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
  if [[ ( "$phase_now" == "red" || "$phase_now" == "implement" ) && "$has_task_defs" -eq 0 ]]; then
    IMPLEMENTING_SPEC_PATH="$_spec_path" \
    IMPLEMENTING_PLAN_PATH="${PLAN}" \
    run_llm "Invoke the implementing skill for feature: ${feature}. Plan: ${PLAN}." opus
    llm_exit "implementing (Step 1)"
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
    bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD" --lint-cmd "$LINT_CMD"
  fi
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
    gh pr view 2>/dev/null || gh pr create --draft --title "feat: ${feature}" --fill 2>/dev/null || {
      bash "$PF" append-note "$PLAN" "[BLOCKED:env] run-dev-cycle: pr-create-failed — gh pr create failed; create PR manually then re-run"
      exit 1
    }
  fi
  phase_now=$(bash "$PF" get-phase "$PLAN")
  if [[ "$phase_now" == "review" ]] && \
     [[ ! -f "$_review_marker" ]]; then
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
    gh pr close --delete-branch --comment "PR review converged — closing without merge (changes developed via task-by-task workflow on the feature branch)" 2>/dev/null || true
  fi
}

# _spec_coverage_gate — block implement if no tracked test files exist for this spec's concept.
# Uses segment-boundary regex to avoid substring false-positives (e.g. slug 'alert' matching
# 'inbound_alert'). Matches both kebab and snake forms of the concept slug to handle either
# naming convention in the tests/ directory.
_spec_coverage_gate() {
  local spec_path="$1" unit_key="$2"
  local _concept _concept_snake _concept_kebab _test_count
  _concept=$(basename "$(dirname "$spec_path")")
  _concept_snake=$(printf '%s' "$_concept" | tr '-' '_')
  _concept_kebab=$(printf '%s' "$_concept" | tr '_' '-')
  # Segment-boundary matching: concept must appear as a full path component or as test_{concept}.filename
  _test_count=$(git -C "$PROJECT_DIR" ls-files "tests/" 2>/dev/null \
    | grep -cE "/${_concept_snake}/|/test_${_concept_snake}\.|/${_concept_kebab}/|/test_${_concept_kebab}\." \
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
  _spec_scenarios=$(grep -cE '^[[:space:]]*(Scenario|Scenario Outline):' "$spec_path" 2>/dev/null || echo 0)
  [[ "$_spec_scenarios" -eq 0 ]] && return 0  # No BDD scenarios in spec — gate not applicable

  local _test_dir_snake="${PROJECT_DIR}/tests/${_layer}/${_concept_snake}"
  local _test_dir_kebab="${PROJECT_DIR}/tests/${_layer}/${_concept_kebab}"
  _test_dir=""
  [[ -d "$_test_dir_snake" ]] && _test_dir="tests/${_layer}/${_concept_snake}"
  [[ -z "$_test_dir" && -d "$_test_dir_kebab" ]] && _test_dir="tests/${_layer}/${_concept_kebab}"
  if [[ -z "$_test_dir" ]]; then
    return 0  # No test directory yet — coverage gate already blocked for this case
  fi

  _collect_output=$(cd "$PROJECT_DIR" && ${UNIT_CMD} --collect-only -q "$_test_dir" 2>/dev/null)
  _collect_rc=$?
  if [[ "$_collect_rc" -ne 0 ]]; then
    echo "[SKIP] scenario-count gate — pytest collection failed (rc=${_collect_rc}); collection failure is not under-coverage (likely RED-phase import error)" >&2
    return 0
  fi
  # Count lines containing '::' — each collected test item appears as path::testname
  _test_count=$(printf '%s\n' "$_collect_output" | grep -cE '::[a-zA-Z]' || true)
  if [[ "$_test_count" -lt "$_spec_scenarios" ]]; then
    bash "$PF" append-note "$PLAN" \
      "[BLOCKED:code] coverage: under-scenario-count — ${spec_path}; ${_test_count} tests < ${_spec_scenarios} scenarios (하한 미달) — 사람 조사"
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
