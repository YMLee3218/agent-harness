---
name: implementing
description: >
  Step 1 only: read spec + failing tests, plan task list, write ## Task Definitions JSON.
  Do NOT proceed to Steps 2-3.5 — run-implement.sh handles those.
  Trigger: "implement", "make the tests pass", "implement phase", "go", "proceed", after critic-test returns PASS.
  Do NOT trigger when no spec or tests exist — route to brainstorming instead.
  Do NOT trigger on plan mode exit or post-plan summary commands.
context: fork
agent: implementer
paths:
  - src/**
  - tests/**
  - plans/**
  - features/**
  - domain/**
  - infrastructure/**
  - docs/**
---

# Implementation Workflow

## Step 1 — Read plan file + plan implementation order

Phase entry protocol: @reference/phase-ops.md §Skill phase entry — expected phases: `red`, `implement` (recovery). Read `plans/{slug}.md`. For non-`red` phases or non-empty Task Ledgers, consult §Session Recovery. For unexpected phases: `[BLOCKED:env] implementing: unexpected-phase — entered from {phase}; cannot proceed`.

**Phase `red` — plan task list:**

- The harness pre-resolves the primary spec path; it is available in `${IMPLEMENTING_SPEC_PATH}`. If unset (interactive mode), locate it from `${IMPLEMENTING_PLAN_PATH:-$CLAUDE_PLAN_FILE}` via the feature slug. Read the `## Test Manifest` from the plan file; generate tasks **only** for entries marked `→ RED` — skip entries marked `→ GREEN (pre-existing)` (these already pass and must not receive implementation tasks). Then read the failing test files, the spec file, and existing domain/feature structure.

Reuse any existing adapter whose interface already matches the requirement; if none, create a minimal new adapter. Log `[AUTO-DECIDED] implementing/Step1: {decision}` to `## Open Questions`.

Write task list to plan file (human-readable form):

```
Task N: {verb} {object}
  Files: {exact paths}
  Spec: {spec path — e.g. domain/{concept}/spec.md}
  Layer: {derived from spec path prefix per @reference/layers.md §Naming conventions}
  Depends on: Task M (omit if none)
  Parallel: yes/no
```

Layer order: domain tasks first, then infrastructure, then features. Mark tasks that can run in parallel within the same layer tier (no cross-task dependency within the tier).

Then write the `## Task Definitions` JSON block in the plan file:

```
<!-- task-definitions-start -->
[
  {
    "id": "task-1",
    "goal": "{verb} {object}",
    "files": ["{exact path}", ...],
    "spec": "{spec path}",
    "layer": "{domain|infrastructure|features}",
    "failing_test": "{tests/path/file.py::test_name}",
    "depends_on": null,
    "parallel": false
  }
]
<!-- task-definitions-end -->
```

- `layer` must be one of: `domain`, `infrastructure`, `features`
- `files` is an array of exact file paths to create or modify
- `failing_test` is the path (and optionally `::test_name`) of the primary failing test for this task; must be passable as a positional argument to the `- Test:` command (e.g. `pytest tests/foo.py::test_bar`, `jest src/foo.test.ts`); leave empty for test runners that do not support positional file path selection (e.g. `go test`, `cargo test`)
- `parallel: true` only when there is no cross-task dependency within the same layer tier
- `depends_on` is the `id` of the task this one depends on, or `null` — informational for JSON ordering only; the scheduler executes sequential tasks in JSON array order, not by this field; place dependent tasks after their dependencies in the array

After writing the JSON block, stop. Do not proceed to Step 2. `run-implement.sh` handles Steps 2–3.5.

## Session Recovery

Read `plans/{slug}.md` and check the `## Task Ledger` section. Mark any `in_progress` task as `pending` (interrupted session — no commit was made). Then branch:

| Phase / Ledger state | Entry point |
|---|---|
| `red`, empty ledger | Step 1 (task planning) |
| `implement` or `red`, has pending tasks | Signal caller — re-run run-implement.sh |
| `red`, all tasks complete | Step 1 (task replanning needed — completed tasks in `red` phase indicate rollback; prior tasks are stale) |
| `implement`, all tasks complete | Tasks complete — signal caller |
| any, has `blocked` task | Stop. Tell the user _(render in conversation language per `@reference/language.md`)_: "A `[BLOCKED:code] coder:` marker is present — clear it from a terminal with `export CLAUDE_PLAN_CAPABILITY=human && bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" unblock "$CLAUDE_PROJECT_DIR/plans/{slug}.md"`; Claude cannot clear this marker (blocked by pretooluse hook)." Do not attempt to call plan-file.sh unblock yourself. |
| `implement`, empty ledger (fresh-start) | Step 1 |
