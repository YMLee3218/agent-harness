---
name: running-integration-tests
description: >
  Run end-to-end integration tests (no mocks, real connections).
  Invoked by running-dev-cycle after all features complete, or manually via `/running-integration-tests`.
  Do NOT trigger automatically — only on explicit user request or when called by running-dev-cycle.
---

# Integration Testing

## Scope

Default test path convention: `tests/integration/**`. The actual integration test command is defined in project `CLAUDE.md` (`- Integration test:` line) and may target any directory.

## Phase entry

Phase entry protocol: @reference/phase-ops.md §Skill phase entry — expected phases: `green`, `integration` (re-run after previous failure). For unexpected phases: `[BLOCKED:env] running-integration-tests: unexpected-phase — entered from {phase}; expected green or integration`.

## When to run

- Major features completed (milestone boundary)
- Before deployment
- User explicitly requests

## Run

Run the block below as-is — do not modify any values:

```bash
_boot=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || _boot="${CLAUDE_PROJECT_DIR:-$(pwd)}"
source "$_boot/.claude/scripts/lib/run-context.sh" && _resolve_project_dir
_active_plan=$(bash "$PROJECT_DIR/.claude/scripts/plan-file.sh" find-active 2>/dev/null || echo '')
if [[ -z "$_active_plan" ]]; then
  echo "running-integration-tests: no active plan — start a dev cycle first with /running-dev-cycle" >&2; exit 1
fi
_phase=$(bash "$PROJECT_DIR/.claude/scripts/plan-file.sh" get-phase "$_active_plan" 2>/dev/null || echo '')
if [[ "$_phase" != "green" && "$_phase" != "integration" ]]; then
  bash "$PROJECT_DIR/.claude/scripts/plan-file.sh" append-note "$_active_plan" \
    "[BLOCKED:env] running-integration-tests: unexpected-phase — entered from ${_phase:-unknown}; expected green or integration"
  exit 1
fi
_unit_cmd=$(grep -m1 '^\- Test:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null \
  | sed 's/^- Test: *//;s/^`//;s/`.*$//' || echo '')
_integration_cmd=$(grep -m1 '^\- Integration test:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null \
  | sed 's/^- Integration test: *//;s/^`//;s/`.*$//' || echo '')
[[ -z "$_integration_cmd" ]] && { echo "running-integration-tests: no '- Integration test:' line found in CLAUDE.md — add it or run /initializing-project first." >&2; exit 1; }
bash "$PROJECT_DIR/.claude/scripts/run-integration.sh" \
  --plan "${_active_plan}" \
  --unit-cmd "${_unit_cmd}" \
  --integration-cmd "${_integration_cmd}"
```

Use `run_in_background=true` — this script may run for minutes.

`run-integration.sh` handles:
- Step 1.5: unit test pre-check with rollback on failure
- Phase transition to `integration` before running tests
- Pass → `done` transition
- Fail → LLM failure categorization (one B-session): `implementation bug` → rollback + fix + re-run (blocks on second failure); `spec gap` → spec/test/implement rollback + re-run; `docs conflict` → `[BLOCKED:docs]` (human ground-truth determination required per @reference/phase-ops.md §DOCS CONTRADICTION cascade)
- Blocked on ambiguous category → `[BLOCKED:code]` marker written to plan file

After the completion notification, read `## Open Questions` for any `[BLOCKED:{kind}]` markers and report to the user. If any markers are present, immediately follow `@reference/blocked-guidance.md` to present each block in the conversation language (Korean by default) with root-cause-first recommendations. All human-must kinds except `ceiling` (`envelope`, `docs`, `spec`, `code`, `env`, `harness`) require `plan-file.sh unblock` after fixing the root cause. Exception: `[BLOCKED:docs]` requires `unblock` first (before the fix — required to enable cascade sub-runs that would otherwise exit 1), then determine ground truth → fix → re-run critics per `@reference/blocked-guidance.md §docs`. Exception: for `[BLOCKED:ceiling]`, always use `reset-milestone {agent}` instead — `reset-milestone` both clears the marker and increments the milestone counter so the next run starts fresh. `unblock` alone does not increment the milestone counter and immediately re-triggers the ceiling block. See `@reference/markers.md §Clearing stop markers`.
