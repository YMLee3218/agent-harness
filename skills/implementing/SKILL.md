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

- The harness pre-resolves the primary spec path; it is available in `${IMPLEMENTING_SPEC_PATH}`. If unset (interactive mode), locate it from `${IMPLEMENTING_PLAN_PATH:-$CLAUDE_PLAN_FILE}` via the feature slug. Read the `## Test Manifest` from the plan file; generate tasks **only** for entries marked `→ RED` — skip entries marked `→ GREEN (pre-existing)` (these already pass and must not receive implementation tasks). One task = one implementation unit (the file/module listed in `files`). Group all RED tests that drive the same unit into that one task, and set `failing_test` to one representative RED test as the gate. Split into separate tasks only when they modify different files/units (enables parallelism and isolates failures). **Never split a test file across tasks**: all test functions within one test file must belong to a single task — the gate runs the entire test file, so a partial implementation of one file will block the task. The Red-phase cardinality check (critic-test Check 5) ensures each test file covers exactly one spec before implementing begins. If a multi-unit test file somehow reaches this stage, the correct resolution is to return to the Red phase and re-split the file — never merge multiple specs into one oversized task. Then read the failing test files, the spec file, and existing domain/feature structure.

Reuse any existing adapter whose interface already matches the requirement; if none, create a minimal new adapter. Log `[AUTO-DECIDED] implementing/Step1: {decision}` to `## Open Questions`.

If you find a Manifest-GREEN test actually fails today (spec changed after manifest was written):
- Do NOT change `failing_test` to the file path.
- Create normal tasks per RED entry, each with a specific `::test_name`.
- If the mismarked GREEN test is fixed by the same change as an existing task, add it to that
  task's goal description; keep `failing_test` pointing to one specific `::test_name` (use the
  first mismarked test if no RED test covers the same change).
- Append to `## Open Questions`:
  `[AUTO-DECIDED] implementing/Step1: manifest-green-actually-red — {test_name} fails due to
  spec change; included in task-N scope; smoke run will confirm.`

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
- `failing_test` must be `tests/path/file.py::test_name` (specific test name required);
  omitting `::test_name` inlines the entire test file verbatim into the Codex prompt (token
  cost); the gate and review run at file scope regardless — do not omit it. This is a hard
  constraint: NOT subject to [AUTO-DECIDED] override. The orchestrator enforces this and will
  block with [BLOCKED:env] missing-test-name if absent.
  Leave the field empty only when the test runner does not support positional path selection
  (e.g. `go test`, `cargo test`).
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
| any, has `blocked` task | Stop. Tell the user _(render in conversation language per `@reference/language.md`)_: "A `[BLOCKED:code] coder:` marker is present — clear it from a terminal with `export CLAUDE_PLAN_CAPABILITY=human && bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" unblock "$CLAUDE_PROJECT_DIR/plans/{slug}.md"`; Claude cannot clear this marker (blocked by pretooluse hook). (`unblock` without an agent argument clears all 6 non-ceiling human-must-clear marker types — envelope, docs, spec, code, env, harness — not only the code marker; for `[BLOCKED:ceiling]`, use `reset-milestone {agent}` instead — `unblock` alone does not increment the milestone counter and the next run immediately re-blocks.)" Do not attempt to call plan-file.sh unblock yourself. |
| `implement`, empty ledger (fresh-start) | Step 1 |
