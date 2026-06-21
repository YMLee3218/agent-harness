#!/usr/bin/env bash
# Phase helpers for run-dev-cycle.sh — extracted to keep the orchestrator under 200 lines.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_DEV_CYCLE_PHASES_LOADED:-}" ]] && return 0
_DEV_CYCLE_PHASES_LOADED=1

# events.sh provides _ev_qualified_unit / _ev_stage_of_agent used to set CRITIC_UNIT below.
[[ -n "${_EVENTS_LOADED:-}" ]] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/events.sh"

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
    local feat_slug _spec_path _new_specs _spec_for_critic _other_specs _csp _cross_ctx _sp_file
    feat_slug=$(_slugify_feature "$feature")
    export CLAUDE_BLOCK_UNIT="features-${feat_slug}" CLAUDE_BLOCK_STAGE="spec"
    _spec_path=$(find_spec_path "$feat_slug")
    # Per-unit events skip — converged spec is recomputed from the log. The old check also
    # required git-committed+clean, which permanently skipped committed-but-changed specs
    # (root defect #1); the working-tree hash now reopens on any edit regardless of commit state.
    bash "$PF" stage-satisfied "$PLAN" "features-${feat_slug}" spec 2>/dev/null && continue

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
      # Plan is past spec phase; spec was already reviewed in a prior run (events-converged).
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

    _naming_path_gate "${_spec_for_critic}"
    _bdd_format_gate "${_spec_for_critic}"
    _envelope_axes_gate "${_spec_for_critic}"
    bash "$PF" reset-milestone "$PLAN" critic-spec
    bash "$PF" reset-milestone "$PLAN" critic-cross 2>/dev/null || true
    CRITIC_SPEC_PATH="${_spec_for_critic}" \
    CRITIC_DOCS_PATHS="$(docs_paths)" \
    CRITIC_PLAN_PATH="${PLAN}" \
    CRITIC_UNIT="features-${feat_slug}" \
    run_critic critic-spec spec \
      "Review spec for feature: ${feature}. Spec: ${_spec_for_critic}. Docs: $(docs_paths). Plan: ${PLAN}.${_cross_ctx}"
    llm_exit "critic-spec"

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
  local _di_specs _spec_rel _spec _layer _slug _ph

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
    export CLAUDE_BLOCK_UNIT="${_layer}-${_slug}" CLAUDE_BLOCK_STAGE="spec"

    # Per-unit events skip (replaces committed+clean+marker; see _phase_spec_prepass).
    bash "$PF" stage-satisfied "$PLAN" "${_layer}-${_slug}" spec 2>/dev/null && continue

    # Ensure plan is in spec phase before critic-spec runs.
    _ph=$(bash "$PF" get-phase "$PLAN" 2>/dev/null || echo "")
    if [[ "$_ph" == "brainstorm" ]]; then
      bash "$PF" transition "$PLAN" spec "advancing to spec phase for ${_layer}/${_slug} critic-spec"
    elif [[ "$_ph" != "spec" ]]; then
      continue
    fi

    _naming_path_gate "${_spec_rel}"
    _bdd_format_gate "${_spec}"
    bash "$PF" reset-milestone "$PLAN" critic-spec
    bash "$PF" reset-milestone "$PLAN" critic-cross 2>/dev/null || true
    CRITIC_SPEC_PATH="${_spec}" \
    CRITIC_DOCS_PATHS="$(docs_paths)" \
    CRITIC_PLAN_PATH="${PLAN}" \
    CRITIC_UNIT="${_layer}-${_slug}" \
    run_critic critic-spec spec \
      "Review spec for ${_layer} concept: ${_slug}. Spec: ${_spec}. Docs: $(docs_paths). Plan: ${PLAN}."
    llm_exit "critic-spec"

    git -C "$PROJECT_DIR" add "$_spec_rel" 2>/dev/null || true
    git -C "$PROJECT_DIR" diff --cached --quiet || \
      git -C "$PROJECT_DIR" commit -m "feat(spec): add BDD scenarios for ${_layer}/${_slug}"
  done <<< "$_di_specs"
}

# _phase_cross_spec_review — run critic-cross once across all spec files.
_phase_cross_spec_review() {
  export CLAUDE_BLOCK_UNIT="__cross__" CLAUDE_BLOCK_STAGE="cross"
  bash "$PF" ev-converged "$PLAN" __cross__ cross 2>/dev/null && return 0
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
    CRITIC_UNIT="__cross__" \
    run_critic critic-cross spec \
      "Cross-feature consistency review. All specs: ${_all_specs}. Docs: $(docs_paths). Plan: ${PLAN}."
    llm_exit "critic-cross"
  fi
}

_impl_reset_for_green() {
  local feature="$1"
  local phase_now; phase_now=$(bash "$PF" get-phase "$PLAN")
  [[ "$phase_now" != "green" ]] && return 0
  # Next unit starting after a completed one. Per-unit events scopes mean no cross-feature
  # convergence contamination, so the old milestone/pr-review sidecar resets are unnecessary
  # (and transient counters are already cleared on each critic's successful completion). Only
  # clear the prior unit's task ledger (+ manifest-reconcile counters) and move the phase pointer.
  bash "$PF" inter-feature-reset "$PLAN"
  bash "$PF" transition "$PLAN" implement "inter-feature reset: starting next unit ${feature}"
  bash "$PF" transition "$PLAN" red "inter-feature reset: starting tests for ${feature}"
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
  export CLAUDE_BLOCK_UNIT="$(_ev_qualified_unit "$feat_slug")" CLAUDE_BLOCK_STAGE="test"
  # Per-unit events skip — recomputed from the log, so a later spec/test edit (hash change)
  # auto-reopens this stage (cascade), unlike the old sticky touch marker that blocked re-review.
  local _unit; _unit="$(_ev_qualified_unit "$feat_slug")"
  bash "$PF" stage-satisfied "$PLAN" "$_unit" test 2>/dev/null && return 0
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
  _red_failure_gate "${UNIT_CMD}"
  CRITIC_SPEC_PATH="$_spec_path" \
  CRITIC_TEST_FILES="${_test_files}" \
  CRITIC_PLAN_PATH="${PLAN}" \
  CRITIC_TEST_COMMAND="${UNIT_CMD}" \
  CRITIC_UNIT="$(_ev_qualified_unit "$feat_slug")" \
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
  # No marker touch — convergence is recomputed from the events log (stage-satisfied above).
}

_impl_run_implement_phase() {
  local feature="$1" feat_slug="$2"
  local _spec_path="${3:-}"
  [[ -z "$_spec_path" ]] && _spec_path="$(find_spec_path "$feat_slug")"
  export CLAUDE_BLOCK_UNIT="$(_ev_qualified_unit "$feat_slug")" CLAUDE_BLOCK_STAGE="code"
  local phase_now has_task_defs pending any_task_in_ledger
  local _unit; _unit="$(_ev_qualified_unit "$feat_slug")"
  # Per-unit events re-entry guard (replaces code+quality touch markers). is_implemented(U) =
  # code AND quality converged in the events log; recomputed, so a later src/spec edit reopens it.
  if bash "$PF" ev-implemented "$PLAN" "$_unit" 2>/dev/null; then
    phase_now=$(bash "$PF" get-phase "$PLAN")
    [[ "$phase_now" != "implement" && "$phase_now" != "green" ]] && \
      bash "$PF" transition "$PLAN" implement "implement re-entry: code and quality already reviewed for ${feature}"
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
      local _trap_pending _trap_any _code_done=0
      _trap_pending=$(awk '/^## Task Ledger/{f=1;next} f&&/^## /{exit} f&&/\| pending[ |]|\| in_progress[ |]|\| blocked[ |]/' "$PLAN" 2>/dev/null || true)
      _trap_any=$(awk '/^## Task Ledger$/{f=1;next} f&&/^## /{exit} f&&/\| (pending|in_progress|completed|blocked)[ |]/{print;exit}' "$PLAN" 2>/dev/null || true)
      bash "$PF" stage-satisfied "$PLAN" "$_unit" code 2>/dev/null && _code_done=1
      if [[ -z "$_trap_pending" && -n "$_trap_any" && "$_code_done" -eq 0 ]]; then
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
     ! bash "$PF" stage-satisfied "$PLAN" "$_unit" code 2>/dev/null; then
    _forbidden_artifact_gate "$_unit"
    _test_mock_gate "$_unit"
    _forbidden_import_gate "$_unit"
    _dep_reconciliation_gate "$_unit"
    bash "$PF" reset-milestone "$PLAN" critic-code
    CRITIC_SPEC_PATH="$_spec_path" \
    CRITIC_DOCS_PATHS="$(docs_paths)" \
    CRITIC_PLAN_PATH="${PLAN}" \
    CRITIC_LANGUAGE="${_lang}" \
    CRITIC_DOMAIN_ROOT="${_domain_root}" \
    CRITIC_INFRA_ROOT="${_infra_root}" \
    CRITIC_FEATURES_ROOT="${_features_root}" \
    CRITIC_UNIT="$(_ev_qualified_unit "$feat_slug")" \
    run_critic critic-code implement "Review changed files for feature: ${feature}. Spec: ${_spec_path}. Docs: $(docs_paths). Plan: ${PLAN}. language: ${_lang}. domain_root: ${_domain_root}. infra_root: ${_infra_root}. features_root: ${_features_root}."
    llm_exit "critic-code"
    # No marker touch — code convergence is recomputed from the events log.
  fi
  phase_now=$(bash "$PF" get-phase "$PLAN")
  if [[ "$phase_now" == "implement" ]] && \
     ! bash "$PF" stage-satisfied "$PLAN" "$_unit" quality 2>/dev/null; then
    bash "$PF" reset-milestone "$PLAN" critic-quality
    CRITIC_SPEC_PATH="$_spec_path" \
    CRITIC_DOCS_PATHS="$(docs_paths)" \
    CRITIC_PLAN_PATH="${PLAN}" \
    CRITIC_LANGUAGE="${_lang}" \
    CRITIC_DOMAIN_ROOT="${_domain_root}" \
    CRITIC_INFRA_ROOT="${_infra_root}" \
    CRITIC_FEATURES_ROOT="${_features_root}" \
    CRITIC_UNIT="$(_ev_qualified_unit "$feat_slug")" \
    run_critic critic-quality implement "Review quality for feature: ${feature}. Spec: ${_spec_path}. Docs: $(docs_paths). Plan: ${PLAN}. language: ${_lang}."
    llm_exit "critic-quality"
    # No marker touch — quality convergence is recomputed from the events log.
  fi
}

# _di_spec_list — relative paths of every domain/infrastructure spec.md (pending or tracked).
# Single source for both the implement cycle and the green barrier so they enumerate identically.
_di_spec_list() {
  {
    git -C "$PROJECT_DIR" status --porcelain 2>/dev/null \
      | awk '$0 ~ /spec\.md$/{print $NF}' | grep -E '^(src/)?(domain|infrastructure)/' || true
    git -C "$PROJECT_DIR" ls-files '*/spec.md' 2>/dev/null \
      | grep -E '^(src/)?(domain|infrastructure)/' || true
  } | sort -u
}

# _unit_key_of_spec REL → {layer}-{slug} unit key for a domain/infra spec relative path.
_unit_key_of_spec() {
  local _rel="$1" _layer _slug
  _layer=$(printf '%s' "$_rel" | sed 's|^src/||' | cut -d/ -f1)
  _slug=$(printf '%s'  "$_rel" | sed 's|^src/||' | cut -d/ -f2)
  printf '%s-%s' "$_layer" "$_slug"
}

# _all_units_implemented — phase-level ∀U green barrier (invariant 4). rc0 iff every enumerated
# unit (domain/infra specs + features) is_implemented (code ∧ quality converged), recomputed from
# the events log — trusts the log, not the .phase pointer. Empty enumerate → rc1 (|U|>=1
# fail-closed: never green a plan with no units). Replaces the old per-unit transition, which
# flipped the WHOLE plan to green on the first unit and let the phase-gated implement loop skip
# every remaining unit.
# _depends_on_closure_units — emit {layer}-{slug} unit keys for every concept any feature spec
# declares in its Depends-on line (1-level closure). Each concept is resolved through the canonical
# _ev_find_spec_path resolver, so a declared-but-UNWRITTEN dep still resolves (to its default path)
# and is therefore STILL enumerated — fail-closed: its events log is empty → ev-implemented false →
# the ∀U barrier blocks instead of greening over a missing declared dependency (invariant 4).
_depends_on_closure_units() {
  local feature _slug _spec _concept _dep _rel _layer _dslug
  while IFS= read -r feature; do
    [[ -z "$feature" ]] && continue
    _slug=$(_slugify_feature "$feature")
    _spec=$(find_spec_path "$_slug" 2>/dev/null) || _spec=""
    [[ -f "$_spec" ]] || continue
    grep -iE '^[[:space:]]*Depends-on:' "$_spec" 2>/dev/null \
      | sed 's/^[[:space:]]*[Dd]epends-on:[[:space:]]*//' | tr ',' '\n' \
      | while read -r _concept; do
          _concept=$(printf '%s' "$_concept" | tr -dc 'a-z0-9-')
          [[ -z "$_concept" ]] && continue
          _dep=$(_ev_find_spec_path "$_concept")
          _rel=${_dep#"${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}/"}
          _layer=$(printf '%s' "$_rel" | sed 's|^src/||' | cut -d/ -f1)
          _dslug=$(printf '%s' "$_rel" | sed 's|^src/||' | cut -d/ -f2)
          [[ -n "$_layer" && -n "$_dslug" ]] && printf '%s-%s\n' "$_layer" "$_dslug"
        done
  done < <(get_features)
}

# _enumerate_units — the phase-transition unit set (invariant 4): every feature, every disk
# domain/infra spec, AND the Depends-on closure (declared deps, written or not). Deduped. This is
# the authoritative ∀U enumerate — distinct from _di_spec_list, which only drives the implement
# loop. Using the declaration closure (not just disk) makes the gate fail-closed for a feature that
# declares a dependency whose spec has not been written yet.
_enumerate_units() {
  {
    local _rel feature
    while IFS= read -r _rel; do [[ -n "$_rel" ]] && _unit_key_of_spec "$_rel"; done < <(_di_spec_list)
    while IFS= read -r feature; do [[ -n "$feature" ]] && printf 'features-%s\n' "$(_slugify_feature "$feature")"; done < <(get_features)
    _depends_on_closure_units
  } | LC_ALL=C sort -u
}

_all_units_implemented() {
  local _any=0 _u
  while IFS= read -r _u; do
    [[ -z "$_u" ]] && continue
    _any=1
    bash "$PF" ev-implemented "$PLAN" "$_u" 2>/dev/null || return 1
  done < <(_enumerate_units)
  [[ "$_any" -eq 1 ]]   # |enumerate| >= 1 fail-closed: never green a plan with no units
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

# _red_failure_gate TEST_CMD — deterministic RED verification. In the Red phase the implementation
# does not exist yet, so the test suite must FAIL; the test runner is the oracle (not an LLM
# judgment — critic-test stays backup). A clean exit 0 means the suite passes with no
# implementation (vacuous tests or a pre-existing impl), violating TDD red → block. Any non-zero
# exit (assertion failures, import errors, pytest's exit 5 "no tests collected") is a valid red.
# Empty TEST_CMD is a no-op (the no-unit-test-cmd case is handled upstream). Called after the
# test(red) commit, before critic-test. Language-agnostic: only a clean pass triggers the block.
_red_failure_gate() {
  local _cmd="$1"
  [[ -z "$_cmd" ]] && return 0
  if ( cd "$PROJECT_DIR" && eval "$_cmd" ) >/dev/null 2>&1; then
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] red-failure: tests-pass-without-impl — '${_cmd}' exited 0 in the Red phase; new tests must fail before any implementation exists (vacuous tests or a pre-existing implementation). Make the tests genuinely RED before proceeding."
    exit 1
  fi
}

# _forbidden_import_gate UNIT — deterministic boundary check for the EXCEPTION-FREE forbidden
# edges in @reference/layers.md §Forbidden imports: a domain unit must not import infrastructure/
# or features/; an infrastructure unit must not import features/. These edges have no documented
# exception, so they are promoted from critic-code (LLM) to a pre-critic deterministic gate
# (critic-code stays backup). The HYBRID edges — features→domain (small features may import value
# objects; large features may type-import) — are NOT gated here; they remain LLM judgment. Feature
# units therefore get no check. The domain→external-system rule stays in critic-code's curated
# STDLIB_PATTERNS (per-language; not re-derived here per anti-hallucination). The grep anchors on
# import syntax with the forbidden layer as a *module-path* token so a domain symbol merely *named*
# `features`/`infrastructure` is not a false positive. Any hit → block + exit 1. Called before
# critic-code. UNIT is layer-qualified (domain-todo / infrastructure-store / features-add-todo).
_forbidden_import_gate() {
  local _unit="$1" _ls _layer _slug _files _f _hit="" _pat=""
  _ls=$(_ev_unit_layer_slug "$_unit" 2>/dev/null || true)
  [[ -z "$_ls" ]] && return 0
  read -r _layer _slug <<< "$_ls"
  case "$_layer" in
    domain)         _pat='infrastructure|features' ;;
    infrastructure) _pat='features' ;;
    *)              return 0 ;;   # feature-layer edges are HYBRID — left to critic-code
  esac
  _files=$(_ev_unit_src_files "$_unit" 2>/dev/null | LC_ALL=C sort -u)
  [[ -z "$_files" ]] && return 0
  # Three import forms: python `from <path-with-layer> import …`, python `import <path-with-layer>`,
  # and js/ts `… from '<path-with-layer>'` / `require('<path-with-layer>')`. The layer token must be
  # in the module path (before `import` for `from`, or inside the quoted module string), never the
  # imported symbol — that excludes `from src.domain.x import features` and bare comment mentions.
  local _re="^[[:space:]]*from[[:space:]]+[A-Za-z0-9_.]*(${_pat})[A-Za-z0-9_.]*[[:space:]]+import|^[[:space:]]*import[[:space:]]+[A-Za-z0-9_.]*(${_pat})|(from|require[[:space:]]*[(])[[:space:]]*['\"][^'\"]*(${_pat})"
  while IFS= read -r _f; do
    [[ -z "$_f" ]] && continue
    [[ -f "$_f" ]] || continue
    if grep -nE "$_re" "$_f" >/dev/null 2>&1; then
      _hit="$_f"; break
    fi
  done <<< "$_files"
  if [[ -n "$_hit" ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] forbidden-import: ${_layer}-cross-boundary — ${_hit} imports a forbidden layer (${_pat//|/ or }); see reference/layers.md §Forbidden imports"
    exit 1
  fi
}

# _dep_reconciliation_gate UNIT — §invariant 11. At code-stage RUN, verify the spec's Depends-on
# DECLARATIONS equal the unit's actual cross-unit IMPORTS (compared at concept level — Depends-on
# names concepts, not layers). Declared deps feed the code-stage input hash, so an undeclared
# import means a dependency edit will not reopen this stage (the cascade bootstrap hole), and an
# over-declaration hashes a spec that is not a real dep. Either → block [BLOCKED:code]. This is the
# forcing half of the declaration-based cascade (writing-spec emits Depends-on). Python + JS/TS
# import grammar only — other languages are skipped with a note (anti-hallucination: their import
# grammar is not assumed). Domain units carry no deps (forbidden-import covers them) → skipped.
# Self-imports are excluded by (layer,slug). critic-code stays backup.
_dep_reconciliation_gate() {
  local _unit="$1" _ls _layer _slug
  _ls=$(_ev_unit_layer_slug "$_unit" 2>/dev/null || true)
  [[ -z "$_ls" ]] && return 0
  read -r _layer _slug <<< "$_ls"
  [[ "$_layer" == "domain" ]] && return 0
  local _files; _files=$(_ev_unit_src_files "$_unit" 2>/dev/null | LC_ALL=C sort -u)
  [[ -z "$_files" ]] && return 0
  if ! printf '%s\n' "$_files" | grep -qE '\.(py|ts|js|tsx|jsx|mjs|cjs)$'; then
    echo "[SKIP] dep-reconciliation — ${_unit}: non-python/js sources; import grammar not assumed" >&2
    return 0
  fi
  local _own; _own=$(printf '%s' "$_slug" | tr '_' '-')

  # Imported cross-unit concepts (kebab), self (layer,slug) excluded. Three import forms emit
  # "<layer> <concept>" pairs: (A) python path-into-concept `from|import …layer.concept[.sub]`
  # (absolute or relative); (B) python path-to-layer `from …layer import c1, c2` (lowercase module
  # names are concepts); (C) js/ts `from '…/layer/concept'` / `require('…/layer/concept')`.
  local _imported _f
  _imported=$( {
    while IFS= read -r _f; do
      [[ -f "$_f" ]] || continue
      grep -oE "^[[:space:]]*(from|import)[[:space:]]+[A-Za-z0-9_.]*(domain|infrastructure|features)\.[a-z0-9_]+" "$_f" 2>/dev/null \
        | grep -oE "(domain|infrastructure|features)\.[a-z0-9_]+" | tr '.' ' '
      grep -oE "^[[:space:]]*from[[:space:]]+[A-Za-z0-9_.]*(domain|infrastructure|features)[[:space:]]+import[[:space:]]+[a-zA-Z0-9_,[:space:]]+" "$_f" 2>/dev/null \
        | sed -E 's/^[[:space:]]*from[[:space:]]+//' \
        | awk '{ n=split($1, mp, "."); layer="";
                 for (i=1;i<=n;i++) if (mp[i]=="domain"||mp[i]=="infrastructure"||mp[i]=="features") layer=mp[i];
                 if (layer=="") next;
                 for (i=3;i<=NF;i++) { name=$i; gsub(/,/,"",name); if (name ~ /^[a-z][a-z0-9_]*$/) print layer" "name } }'
      grep -oE "(from|require[[:space:]]*\()[[:space:]]*['\"][^'\"]*(domain|infrastructure|features)/[a-z0-9_-]+" "$_f" 2>/dev/null \
        | grep -oE "(domain|infrastructure|features)/[a-z0-9_-]+" | tr '/' ' '
    done <<< "$_files"
  } | while read -r _il _ic; do
        [[ -z "$_ic" ]] && continue
        _ic=$(printf '%s' "$_ic" | tr '_' '-')
        [[ "$_il" == "$_layer" && "$_ic" == "$_own" ]] && continue
        printf '%s\n' "$_ic"
      done | LC_ALL=C sort -u )

  # Declared concepts (kebab) from the spec's Depends-on line.
  local _spec _declared=""
  _spec=$(_ev_unit_spec_path "$_unit" 2>/dev/null)
  if [[ -f "$_spec" ]]; then
    _declared=$(grep -iE '^[[:space:]]*Depends-on:' "$_spec" 2>/dev/null \
      | sed 's/^[[:space:]]*[Dd]epends-on:[[:space:]]*//' | tr ',' '\n' \
      | while read -r _d; do _d=$(printf '%s' "$_d" | tr -dc 'a-z0-9-'); [[ -n "$_d" ]] && printf '%s\n' "$_d"; done \
      | LC_ALL=C sort -u)
  fi

  local _undeclared _overdeclared
  _undeclared=$(comm -23 <(printf '%s\n' "$_imported" | sed '/^$/d') <(printf '%s\n' "$_declared" | sed '/^$/d'))
  _overdeclared=$(comm -13 <(printf '%s\n' "$_imported" | sed '/^$/d') <(printf '%s\n' "$_declared" | sed '/^$/d'))
  if [[ -n "$_undeclared" ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] dep-reconciliation: undeclared-import — ${_unit} imports [$(printf '%s' "$_undeclared" | tr '\n' ' ')] not in the spec Depends-on; declare them so a dependency edit reopens the code stage (reference/layers.md dependency declaration)"
    exit 1
  fi
  if [[ -n "$_overdeclared" ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] dep-reconciliation: over-declared-dep — ${_unit} declares Depends-on [$(printf '%s' "$_overdeclared" | tr '\n' ' ')] but never imports them; remove the stale declaration"
    exit 1
  fi
}

# _forbidden_artifact_gate UNIT — grep the unit's src+test files for skip/TODO markers that have
# NO documented exception (these are no-exception per @reference/effort.md Root-cause obligation):
# @pytest.mark.skip, @pytest.mark.xfail, '# TODO', '# FIXME', xit(, it.skip(, xdescribe(.
# Empty stubs (pass/.../return null) are intentionally NOT checked — ABC/Protocol/Exception bodies
# are legal there; that is a HYBRID judgment left to the LLM critic. Any hit → block + exit 1.
# Called before critic-code. UNIT is a layer-qualified key (e.g. domain-todo / features-add-todo).
_forbidden_artifact_gate() {
  local _unit="$1" _files _f _hit=""
  _files=$( { _ev_unit_src_files "$_unit"; _ev_unit_test_files "$_unit"; } 2>/dev/null | LC_ALL=C sort -u )
  [[ -z "$_files" ]] && return 0
  while IFS= read -r _f; do
    [[ -z "$_f" ]] && continue
    [[ -f "$_f" ]] || continue
    if grep -nE '@pytest\.mark\.skip|@pytest\.mark\.xfail|#[[:space:]]*TODO|#[[:space:]]*FIXME|xit\(|it\.skip\(|xdescribe\(' "$_f" >/dev/null 2>&1; then
      _hit="$_f"
      break
    fi
  done <<< "$_files"
  if [[ -n "$_hit" ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] forbidden-artifact: skip-or-todo — ${_hit}"
    exit 1
  fi
}

# _test_mock_gate UNIT — for the unit's test files under a DOMAIN layer, and for any test files
# under tests/integration/, grep for mocking constructs. Domain tests and integration tests are
# the two no-exception "No mocks" scopes in @reference/layers.md §Test mocking levels. Small/large
# feature mock rules are HYBRID and deliberately NOT gated (left to critic-test). Any hit →
# block + exit 1. Called before critic-code.
_test_mock_gate() {
  local _unit="$1" _ls _layer _slug _files _f _hit=""
  _ls=$(_ev_unit_layer_slug "$_unit" 2>/dev/null || true)
  _layer=""
  [[ -n "$_ls" ]] && read -r _layer _slug <<< "$_ls"
  # Only domain-layer test files are in a no-mock scope; feature-layer mocks are HYBRID. But also
  # always include any of the unit's test files that live under tests/integration/.
  _files=$(_ev_unit_test_files "$_unit" 2>/dev/null | LC_ALL=C sort -u)
  [[ -z "$_files" ]] && return 0
  while IFS= read -r _f; do
    [[ -z "$_f" ]] && continue
    [[ -f "$_f" ]] || continue
    # In scope when: the unit is a domain unit, OR the file lives under tests/integration/.
    if [[ "$_layer" != "domain" ]] && ! printf '%s' "$_f" | grep -q '/tests/integration/'; then
      continue
    fi
    if grep -nE 'unittest\.mock|MagicMock|Mock|patch\(|monkeypatch' "$_f" >/dev/null 2>&1; then
      _hit="$_f"
      break
    fi
  done <<< "$_files"
  if [[ -n "$_hit" ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] test-mock: mock-in-no-mock-scope — ${_hit}"
    exit 1
  fi
}

# _naming_path_gate SPEC_PATH — verify the spec path matches the @reference/layers.md canonical
# layer-to-spec mapping: features/{verb}-{noun}/spec.md, domain/{noun}/spec.md,
# infrastructure/{noun}/spec.md (a leading src/ prefix is also accepted, matching the existing
# resolvers _ev_find_spec_path / find_spec_path). Mismatch → block + exit 1. Called before
# critic-spec.
_naming_path_gate() {
  # Arg may be a single path OR a whitespace-joined list (e.g. _spec_for_critic from git status).
  # Validate EACH path so a multi-spec batch does not false-positive on the joined string.
  local _arg="$1" _spec _rel
  [[ -z "$_arg" ]] && return 0
  for _spec in $_arg; do   # intentional word-split
    [[ -z "$_spec" ]] && continue
    _rel="$_spec"
    case "$_spec" in
      "${PROJECT_DIR%/}/"*) _rel="${_spec#${PROJECT_DIR%/}/}" ;;
    esac
    # Canonical: [src/]{features|domain|infrastructure}/{slug}/spec.md
    # Slug segment: kebab-case lowercase (verb-noun for features; noun for domain/infra).
    printf '%s' "$_rel" | grep -qE '^(src/)?(features|domain|infrastructure)/[a-z0-9]+(-[a-z0-9]+)*/spec\.md$' && continue
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] naming: spec-path — ${_spec}"
    exit 1
  done
}

# _bdd_format_gate SPEC_PATH — structural Gherkin check against @reference/bdd-templates.md §Rules:
# (1) the spec must contain a 'Feature:' declaration; (2) every 'Scenario Outline:' must be
# followed (later in the same file) by an 'Examples:' block. PRESENCE/STRUCTURE only — Given/When/Then
# per scenario is NOT required (a 'Background:' may hold the common Given — legal Gherkin; gating it
# would false-positive). Missing Feature OR an Outline with no later Examples → block + exit 1.
# Called before critic-spec. Arg may be a single path OR a whitespace-joined list — validate EACH.
_bdd_format_gate() {
  local _arg="$1" _spec _outline_line _ex_line
  [[ -z "$_arg" ]] && return 0
  for _spec in $_arg; do   # intentional word-split
    [[ -z "$_spec" ]] && continue
    [[ -f "$_spec" ]] || continue   # missing input → no-op for this path
    # (1) Feature: declaration must be present.
    if ! grep -qE '^[[:space:]]*Feature:' "$_spec"; then
      bash "$PF" append-note "$PLAN" "[BLOCKED:spec] bdd-format: missing-Feature — ${_spec}"
      exit 1
    fi
    # (2) Every 'Scenario Outline:' must have an 'Examples:' on a LATER line.
    #     Walk each Outline's 1-based line number; require an Examples: at a greater line number.
    while IFS= read -r _outline_line; do
      [[ -z "$_outline_line" ]] && continue
      _outline_line="${_outline_line%%:*}"
      _ex_line=$(grep -nE '^[[:space:]]*Examples:' "$_spec" 2>/dev/null \
        | awk -F: -v n="$_outline_line" '$1 > n {print $1; exit}')
      if [[ -z "$_ex_line" ]]; then
        bash "$PF" append-note "$PLAN" "[BLOCKED:spec] bdd-format: scenario-outline-without-Examples — ${_spec}"
        exit 1
      fi
    done < <(grep -nE '^[[:space:]]*Scenario Outline:' "$_spec" 2>/dev/null)
  done
}

# _envelope_axes_gate SPEC_PATH — for FEATURE specs only (per @reference/operating-envelope.md §Scope,
# domain/infrastructure specs do NOT carry an Operating Envelope and are skipped). Within the spec's
# '## Operating Envelope' markdown-list section, verify the PRESENCE of each of the six canonical axis
# names: Actors, Frequency, Concurrency, Persistence, Failure model, External I/O. A missing axis name
# → block '[BLOCKED:envelope] envelope-axes: missing-{axis}' + exit 1. PRESENCE ONLY — placeholder-vs-
# filled judgment stays the LLM critic's job. Called before critic-spec for feature specs. Multi-path safe.
_envelope_axes_gate() {
  local _arg="$1" _spec _rel _section _axis _key
  [[ -z "$_arg" ]] && return 0
  for _spec in $_arg; do   # intentional word-split
    [[ -z "$_spec" ]] && continue
    [[ -f "$_spec" ]] || continue   # missing input → no-op for this path
    _rel="$_spec"
    case "$_spec" in
      "${PROJECT_DIR%/}/"*) _rel="${_spec#${PROJECT_DIR%/}/}" ;;
    esac
    # Scope: features only. domain/ + infrastructure/ specs carry no envelope — skip them.
    printf '%s' "$_rel" | grep -qE '^(src/)?features/' || continue
    # Extract the '## Operating Envelope' section: from its heading to the next '## ' heading (or EOF).
    _section=$(awk '
      /^##[[:space:]]+Operating Envelope[[:space:]]*$/ {f=1; next}
      f && /^##[[:space:]]/ {exit}
      f {print}
    ' "$_spec" 2>/dev/null)
    # Check presence of each axis name within the section. Each axis name is a fixed literal.
    for _axis in "Actors" "Frequency" "Concurrency" "Persistence" "Failure model" "External I/O"; do
      if ! printf '%s' "$_section" | grep -qF "$_axis"; then
        _key=$(printf '%s' "$_axis" | tr '[:upper:] ' '[:lower:]-')
        bash "$PF" append-note "$PLAN" "[BLOCKED:envelope] envelope-axes: missing-${_key} — ${_spec}"
        exit 1
      fi
    done
  done
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

  _di_specs=$(_di_spec_list)
  [[ -z "$_di_specs" ]] && return 0

  while IFS= read -r _spec_rel; do
    [[ -z "$_spec_rel" ]] && continue
    _spec="${PROJECT_DIR}/${_spec_rel}"
    _layer=$(printf '%s' "$_spec_rel" | sed 's|^src/||' | cut -d/ -f1)
    _slug=$(printf '%s' "$_spec_rel"  | sed 's|^src/||' | cut -d/ -f2)
    _unit_key="${_layer}-${_slug}"

    bash "$PF" ev-implemented "$PLAN" "$_unit_key" 2>/dev/null && continue
    _impl_reset_for_green "${_layer}/${_slug}"
    _impl_run_test_phase "${_layer}/${_slug}" "$_unit_key" "$_spec"
    _impl_run_implement_phase "${_layer}/${_slug}" "$_unit_key" "$_spec"
  done <<< "$_di_specs"
}

# _phase_implement_cycle — implement + review loop for each feature.
_phase_implement_cycle() {
  while IFS= read -r feature; do
    [[ -z "$feature" ]] && continue
    local feat_slug
    feat_slug=$(_slugify_feature "$feature")
    bash "$PF" ev-implemented "$PLAN" "features-${feat_slug}" 2>/dev/null && continue
    _impl_reset_for_green "$feature"
    _impl_run_test_phase "$feature" "$feat_slug"
    _impl_run_implement_phase "$feature" "$feat_slug"
  done < <(get_features)
}
