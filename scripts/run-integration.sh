#!/usr/bin/env bash
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF="$SCRIPTS_DIR/plan-file.sh"
PLAN="" UNIT_CMD="" INTEGRATION_CMD=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --plan)             PLAN="$2";             shift 2 ;;
    --unit-cmd)         UNIT_CMD="$2";         shift 2 ;;
    --integration-cmd)  INTEGRATION_CMD="$2";  shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -z "$PLAN" || -z "$INTEGRATION_CMD" ]] && {
  echo "Usage: run-integration.sh --plan PATH --integration-cmd CMD [--unit-cmd CMD]" >&2; exit 1; }
[[ -f "$PLAN" ]] || { echo "Plan file not found: $PLAN" >&2; exit 1; }
# Treat unfilled placeholder (from workspace/CLAUDE.md template) as unconfigured
[[ "$UNIT_CMD" == _\(run* ]] && UNIT_CMD=""; [[ "$INTEGRATION_CMD" == _\(run* ]] && { echo "run-integration: integration-cmd is unfilled — run /initializing-project first" >&2; exit 1; }
# Layer boundary context — needed for critic-code Angle 2
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
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

# Spec path helpers — needed for critic-spec
_plan_slug=$(basename "$PLAN" .md)
_req_file="${PROJECT_DIR}/docs/requirements/${_plan_slug}.md"
# Derive feature slug for find_spec_path: use first feature in req file so that
# plans named differently from their feature slug still resolve the correct spec.
_feat_slug="$_plan_slug"
if [[ -f "$_req_file" ]]; then
  _first_feat=$(awk '/^## (Small|Large) Features/{f=1;next} /^## /{f=0} f&&/^[-*] /{sub(/^[-*] *`/,""); sub(/`.*/,""); print; exit}' "$_req_file" 2>/dev/null || true)
  [[ -n "$_first_feat" ]] && \
    _feat_slug=$(printf '%s' "$_first_feat" | tr '[:upper:] ' '[:lower:]-' | tr -dc 'a-z0-9-')
fi
find_spec_path() {
  local slug="$1"
  for _sp in "${PROJECT_DIR}/features/${slug}/spec.md" \
             "${PROJECT_DIR}/domain/${slug}/spec.md" \
             "${PROJECT_DIR}/infrastructure/${slug}/spec.md"; do
    [[ -f "$_sp" ]] && echo "$_sp" && return
  done
  echo "features/${slug}/spec.md"
}
# Collect all spec paths (space-separated) so critics see every feature's spec in multi-feature plans.
# Critics are constrained to the explicit file list in their prompt (reference/critics.md:9).
_all_specs=""
if [[ -f "$_req_file" ]]; then
  while IFS= read -r _feat; do
    [[ -z "$_feat" ]] && continue
    _fslug=$(printf '%s' "$_feat" | tr '[:upper:] ' '[:lower:]-' | tr -dc 'a-z0-9-')
    _sp=$(find_spec_path "$_fslug")
    _all_specs="${_all_specs:+$_all_specs }${_sp}"
  done < <(awk '/^## (Small|Large) Features/{f=1;next} /^## /{f=0} f&&/^[-*] /{sub(/^[-*] *`/,""); sub(/`.*/,""); print}' "$_req_file" 2>/dev/null || true)
fi
[[ -z "$_all_specs" ]] && _all_specs=$(find_spec_path "$_feat_slug")
docs_paths() {
  [[ -f "$_req_file" ]] && echo "$_req_file ${PROJECT_DIR}/docs/" || echo "${PROJECT_DIR}/docs/"
}
run_llm() {
  local prompt="$1"
  CLAUDE_NONINTERACTIVE=1 CLAUDE_PLAN_FILE="$PLAN" \
    claude --model opus --permission-mode auto --dangerously-skip-permissions -p "$prompt"
}

run_critic() {
  local agent="$1" phase="$2" prompt="$3"
  bash "$SCRIPTS_DIR/run-critic-loop.sh" --agent "$agent" --phase "$phase" --plan "$PLAN" --prompt "$prompt"
  return $?
}

# Step 1.5 — unit test pre-check (skipped when UNIT_CMD not configured)
if [[ -n "$UNIT_CMD" ]] && ! bash -c "$UNIT_CMD" 2>&1; then
  bash "$PF" transition "$PLAN" implement "unit tests failing at integration entry — clearing implement-phase markers"
  bash "$PF" reset-for-rollback "$PLAN" implement
  bash "$PF" transition "$PLAN" red "unit tests failing at integration entry — fresh task planning needed"
  bash "$PF" reset-milestone "$PLAN" critic-test
  bash "$PF" append-note "$PLAN" "[BLOCKED] unit tests failing before integration tests — resolve via /implementing before re-running"
  exit 1
fi

bash "$PF" transition "$PLAN" integration "starting integration test run"

attempt=0
max_attempts=2

while true; do
  if test_output=$(bash -c "$INTEGRATION_CMD" 2>&1); then
    bash "$PF" transition "$PLAN" done "integration tests passed"
    exit 0
  fi

  attempt=$((attempt + 1))

  tail_output=$(printf '%s' "$test_output" | tail -50)
  today=$(date +%Y-%m-%d)

  if [[ $attempt -ge $max_attempts ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED] integration tests failed after $((max_attempts - 1)) fix attempt(s) — manual review required"
    exit 1
  fi

  # Invoke LLM to categorize failure and write fix into plan
  run_llm "Integration test failure categorization. Plan file: $PLAN. Test output tail:
${tail_output}

Read the plan file, then under ## Integration Failures (create the section if absent) append:
### Run ${attempt} — ${today}
Then for each failing test:
#### {test name}
Category: {docs conflict | spec gap | implementation bug}
Description: {one sentence}
Log [AUTO-CATEGORIZED-INTEGRATION] {test name}: {category} for each.
If ambiguous, append [BLOCKED] integration:{test name}: cannot determine category automatically — manual review required to ## Open Questions and stop." || true

  # Check for blocked marker from LLM categorization
  blocked=$(awk '/^## Open Questions/{f=1} f&&/\[BLOCKED\] integration:/{print;exit}' "$PLAN" || true)
  if [[ -n "$blocked" ]]; then exit 1; fi

  # Read auto-categorized entries from the CURRENT run only (### Run N section)
  run_header="### Run ${attempt} "
  all_cats=$(awk -v rh="$run_header" \
    '/^## Integration Failures$/{f=1;next} f&&/^## /{exit} f&&g&&/^### /{exit} f&&index($0,rh)==1{g=1;next} f&&g&&/\[AUTO-CATEGORIZED-INTEGRATION\]/{print}' \
    "$PLAN" | grep -oE 'docs conflict|spec gap|implementation bug' || true)
  if [[ -n "$all_cats" ]]; then
    unique_cats=$(printf '%s\n' "$all_cats" | sort -u)
    n_unique=$(printf '%s\n' "$unique_cats" | wc -l | tr -d '[:space:]')
    if [[ "$n_unique" -gt 1 ]]; then
      bash "$PF" append-note "$PLAN" "[BLOCKED] integration: mixed failure categories ($(printf '%s\n' "$unique_cats" | tr '\n' '/')) — manual review required"
      exit 1
    fi
    category="$unique_cats"
  else
    category=""
  fi

  case "$category" in
    "implementation bug")
      bash "$PF" transition "$PLAN" implement "integration failure: implementation bug"
      bash "$PF" reset-for-rollback "$PLAN" implement
      awk '/<!-- task-definitions-start -->/{s=1;next} s&&/<!-- task-definitions-end -->/{s=0;next} s{next} /^## Task Ledger$/{t=1;print;next} t&&/^## /{t=0} t&&/\| (pending|in_progress|completed|blocked)/{next} {print}' "$PLAN" > "${PLAN}.tmp" && mv "${PLAN}.tmp" "$PLAN" 2>/dev/null || true
      run_llm "Invoke the implementing skill to replan tasks for the integration failure. Plan: $PLAN"
      if [[ -n "$UNIT_CMD" ]]; then
        bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD"
      else
        bash "$PF" append-note "$PLAN" "[BLOCKED] integration: implementation bug requires unit test command — add '- Test: {cmd}' to CLAUDE.md and re-run"
        exit 1
      fi
      bash "$PF" reset-milestone "$PLAN" critic-code
      run_critic critic-code implement "Review integration bug fix implementation. Spec: ${_all_specs}. Docs: $(docs_paths). Plan: $PLAN. language: ${_lang}. domain_root: ${_domain_root}. infra_root: ${_infra_root}. features_root: ${_features_root}."
      bash "$PF" transition "$PLAN" integration "re-entering integration after implementation bug fix"
      ;;
    "spec gap")
      if [[ -z "$UNIT_CMD" ]]; then
        bash "$PF" append-note "$PLAN" "[BLOCKED] integration: spec-gap fix requires unit test command — add '- Test: {cmd}' to CLAUDE.md and re-run"
        exit 1
      fi
      bash "$PF" transition "$PLAN" spec "integration failure: spec gap"
      bash "$PF" reset-for-rollback "$PLAN" spec
      bash "$PF" reset-milestone "$PLAN" critic-spec
      bash "$PF" transition "$PLAN" red "clearing stale red/critic-test marker before restoring spec"
      bash "$PF" reset-milestone "$PLAN" critic-test
      bash "$PF" transition "$PLAN" spec "restoring spec phase for writing-spec invocation"
      run_llm "Invoke the writing-spec skill to fix the spec gap. Plan: $PLAN"
      while IFS= read -r _sp; do
        [[ -n "$_sp" ]] && git add "$_sp"
      done < <(git status --porcelain 2>/dev/null | grep 'spec\.md' | awk '{print $2}')
      git diff --cached --quiet || git commit -m "fix(spec): update scenarios for integration spec-gap fix ($(basename "$PLAN" .md))"
      bash "$PF" reset-milestone "$PLAN" critic-spec
      run_critic critic-spec spec "Review updated spec for integration fix. Spec: ${_all_specs}. Docs: $(docs_paths). Plan: $PLAN."
      bash "$PF" transition "$PLAN" red "spec updated for integration fix — updating tests"
      bash "$PF" reset-milestone "$PLAN" critic-test
      run_llm "Invoke the writing-tests skill for the updated spec. Plan: $PLAN"
      _test_files=$(git diff HEAD~1 HEAD --name-only 2>/dev/null | grep -E '^tests/|_test\.' | tr '\n' ' ' || true)
      run_critic critic-test red "Review updated tests for integration fix. Spec: ${_all_specs}. Test files: ${_test_files:-tests/}. Plan: $PLAN. Test command: ${UNIT_CMD}."
      bash "$PF" transition "$PLAN" implement "tests updated for integration fix — implementing"
      awk '/<!-- task-definitions-start -->/{s=1;next} s&&/<!-- task-definitions-end -->/{s=0;next} s{next} /^## Task Ledger$/{t=1;print;next} t&&/^## /{t=0} t&&/\| (pending|in_progress|completed|blocked)/{next} {print}' "$PLAN" > "${PLAN}.tmp" && mv "${PLAN}.tmp" "$PLAN" 2>/dev/null || true
      run_llm "Invoke the implementing skill for updated spec. Plan: $PLAN"
      bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD"
      bash "$PF" reset-milestone "$PLAN" critic-code
      run_critic critic-code implement "Review integration spec-gap fix implementation. Spec: ${_all_specs}. Docs: $(docs_paths). Plan: $PLAN. language: ${_lang}. domain_root: ${_domain_root}. infra_root: ${_infra_root}. features_root: ${_features_root}."
      bash "$PF" transition "$PLAN" integration "re-entering integration after spec gap fix"
      ;;
    "docs conflict")
      if [[ -z "$UNIT_CMD" ]]; then
        bash "$PF" append-note "$PLAN" "[BLOCKED] integration: docs-conflict fix requires unit test command — add '- Test: {cmd}' to CLAUDE.md and re-run"
        exit 1
      fi
      bash "$PF" transition "$PLAN" spec "integration failure: docs conflict"
      bash "$PF" reset-for-rollback "$PLAN" spec
      bash "$PF" reset-milestone "$PLAN" critic-spec
      bash "$PF" transition "$PLAN" red "clearing stale red/critic-test marker before restoring spec"
      bash "$PF" reset-milestone "$PLAN" critic-test
      bash "$PF" transition "$PLAN" spec "restoring spec phase for writing-spec invocation"
      run_llm "Invoke the writing-spec skill to fix the docs conflict. Plan: $PLAN"
      while IFS= read -r _sp; do
        [[ -n "$_sp" ]] && git add "$_sp"
      done < <(git status --porcelain 2>/dev/null | grep 'spec\.md' | awk '{print $2}')
      git diff --cached --quiet || git commit -m "fix(spec): update scenarios for integration docs-conflict fix ($(basename "$PLAN" .md))"
      bash "$PF" reset-milestone "$PLAN" critic-spec
      run_critic critic-spec spec "Review updated spec for integration fix. Spec: ${_all_specs}. Docs: $(docs_paths). Plan: $PLAN."
      bash "$PF" transition "$PLAN" red "spec updated for integration fix — updating tests"
      bash "$PF" reset-milestone "$PLAN" critic-test
      run_llm "Invoke the writing-tests skill for the updated spec. Plan: $PLAN"
      _test_files=$(git diff HEAD~1 HEAD --name-only 2>/dev/null | grep -E '^tests/|_test\.' | tr '\n' ' ' || true)
      run_critic critic-test red "Review updated tests for integration fix. Spec: ${_all_specs}. Test files: ${_test_files:-tests/}. Plan: $PLAN. Test command: ${UNIT_CMD}."
      bash "$PF" transition "$PLAN" implement "tests updated for integration fix — implementing"
      awk '/<!-- task-definitions-start -->/{s=1;next} s&&/<!-- task-definitions-end -->/{s=0;next} s{next} /^## Task Ledger$/{t=1;print;next} t&&/^## /{t=0} t&&/\| (pending|in_progress|completed|blocked)/{next} {print}' "$PLAN" > "${PLAN}.tmp" && mv "${PLAN}.tmp" "$PLAN" 2>/dev/null || true
      run_llm "Invoke the implementing skill for updated spec. Plan: $PLAN"
      bash "$SCRIPTS_DIR/run-implement.sh" --plan "$PLAN" --test-cmd "$UNIT_CMD"
      bash "$PF" reset-milestone "$PLAN" critic-code
      run_critic critic-code implement "Review integration docs-conflict fix implementation. Spec: ${_all_specs}. Docs: $(docs_paths). Plan: $PLAN. language: ${_lang}. domain_root: ${_domain_root}. infra_root: ${_infra_root}. features_root: ${_features_root}."
      bash "$PF" transition "$PLAN" integration "re-entering integration after docs conflict fix"
      ;;
    *)
      bash "$PF" append-note "$PLAN" "[BLOCKED] integration: could not determine fix category — manual review required"
      exit 1
      ;;
  esac
done
