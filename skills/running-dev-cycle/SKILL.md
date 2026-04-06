---
name: running-dev-cycle
description: >
  Runs the full development cycle in order: brainstorming → writing-spec → writing-tests → implementing. Trigger when the user wants to start building something from scratch and go all the way through, or says "run the full cycle", "start the dev cycle", "let's go through the whole process". Also trigger on /running-dev-cycle.
disable-model-invocation: true
---

# Development Cycle

Run each skill in order. Do not skip or reorder steps. Wait for each step to fully complete — including critic PASS and user approval — before invoking the next.

## Step 1 — Brainstorming

Invoke the `brainstorming` skill.

Do not proceed to Step 2 until:
- `docs/requirements/{name}.md` is created
- Feature branch `feature/{name}` is created
- `critic-feature` returns PASS

## Step 2 — Spec

Invoke the `writing-spec` skill for each feature identified in Step 1.

Do not proceed to Step 3 until:
- All `spec.md` files are written
- `critic-spec` returns PASS for each

## Step 3 — Tests

Invoke the `writing-tests` skill.

Do not proceed to Step 4 until:
- All failing tests are written
- `critic-test` returns PASS

## Step 4 — Implementation

Invoke the `implementing` skill.

Cycle is complete when:
- All tasks are checked off in TodoWrite
- `critic-code` returns PASS
- `pr-review-toolkit` returns no unresolved issues
