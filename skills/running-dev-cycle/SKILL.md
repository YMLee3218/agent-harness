---
name: running-dev-cycle
description: >
  Runs the full development cycle in order: brainstorming → writing-spec → writing-tests → implementing.
  Trigger when the user wants to start building something from scratch and go all the way through,
  or says "run the full cycle", "start the dev cycle", "let's go through the whole process".
  Also trigger on /running-dev-cycle.
disable-model-invocation: true
---

# Development Cycle

User-invocable only via `/running-dev-cycle`.

Run each skill in order. Do not skip or reorder steps. Wait for each step to fully complete — including critic PASS and user approval — before invoking the next.

## Step 1 — Brainstorming

Invoke the `brainstorming` skill.

Do not proceed to Step 2 until:
- `docs/requirements/{name}.md` is created
- Feature branch `feature/{name}` is created
- critic-feature returns PASS (or user has approved manual override)
- Plan file `plans/{slug}.md` exists with Phase `brainstorm`

## Step 2 — Spec (for each feature)

Read `docs/requirements/{name}.md` to get the full feature list (Small Features + Large Features sections).

**For each feature in the list:**
1. Invoke the `writing-spec` skill for that feature
2. Wait for critic-spec PASS before moving to the next feature
3. Confirm `{layer}/{feature-name}/spec.md` is written

Do not proceed to Step 3 until all features have a PASS-verified spec.md.

## Step 3 — Tests

Invoke the `writing-tests` skill.

Do not proceed to Step 4 until:
- All failing tests are written (one per Scenario across all specs)
- critic-test returns PASS
- Plan file Phase is `red`

## Step 4 — Implementation

Invoke the `implementing` skill.

The `implementing` skill handles critic-code and pr-review-toolkit internally. Do not run them separately here.

Cycle is complete when:
- All tasks are `completed`
- Plan file Phase is `done`
- No unresolved critic or pr-review-toolkit issues
