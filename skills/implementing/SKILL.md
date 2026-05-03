---
name: implementing
description: >
  Step 1 only: read spec + failing tests, plan task list, write ## Task Definitions JSON.
  Do NOT proceed to Steps 2-3.5 — run-implement.sh handles those.
  Trigger: "implement", "make the tests pass", "implement phase", "go", "proceed", after critic-test returns PASS.
  Do NOT trigger when no spec or tests exist — route to brainstorming instead.
  Do NOT trigger on plan mode exit or post-plan summary commands.
effort: high
context: fork
agent: implementer
paths:
  - src/**
  - tests/**
---

# Implementation Workflow

## Step 1 — Read plan file + plan implementation order

Phase entry protocol: @reference/phase-ops.md §Skill phase entry — expected phases: `red`, `implement` (recovery). Read `plans/{slug}.md`. For non-`red` phases or non-empty Task Ledgers, consult §Session Recovery. For unexpected phases: `[BLOCKED] implementing entered from unexpected phase {phase} — cannot proceed`.

**Phase `red` — plan task list:**

- Read failing tests, `spec.md`, and existing domain/feature structure.

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
- `failing_test` is the path (and optionally `::test_name`) of the primary failing test for this task
- `parallel: true` only when there is no cross-task dependency within the same layer tier
- `depends_on` is the `id` of the task this one depends on, or `null`

After writing the JSON block, stop. Do not proceed to Step 2. `run-implement.sh` handles Steps 2–3.5.

## Session Recovery

Read `plans/{slug}.md` and check the `## Task Ledger` section. Mark any `in_progress` task that has a `commit-sha` as `completed`. Mark any `in_progress` task without a `commit-sha` as `pending` (interrupted session — no commit was made). Then branch:

| Phase / Ledger state | Entry point |
|---|---|
| `red`, empty ledger | Step 1 (task planning) |
| `implement` or `red`, has pending tasks | Signal caller — re-run run-implement.sh |
| `implement` or `red`, all tasks complete | Tasks complete — signal caller |
| any, has `blocked` task | clear `[BLOCKED] coder:` marker → `update-task … pending` → signal caller to re-run run-implement.sh |
| `implement`, empty ledger (fresh-start) | Step 1 |
