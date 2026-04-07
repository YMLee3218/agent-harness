---
name: running-dev-cycle
description: >
  Run full dev cycle: brainstorming → writing-spec → writing-tests → implementing in order.
  Trigger: "run the full cycle", "start the dev cycle", "whole process", /running-dev-cycle.
  Feature-slice mode by default; use --batch flag to write all specs before any tests.
disable-model-invocation: true
---

# Development Cycle

User-invocable only via `/running-dev-cycle`.

Run each skill in order. Do not skip or reorder steps. Wait for each step to fully complete — including critic PASS and user approval — before invoking the next.

## Mode selection

**Default: feature-slice mode** — processes each feature fully (spec → tests → implement) before starting the next. Reduces WIP and limits blast radius when a spec turns out wrong.

**Batch mode** — writes all specs first, then all tests, then implements everything. Use only when the user explicitly requests it (`/running-dev-cycle --batch`).

---

## Step 1 — Brainstorming

Invoke the `brainstorming` skill.

Do not proceed to Step 2 until:
- `docs/requirements/{name}.md` is created
- Feature branch `feature/{name}` is created
- critic-feature returns PASS (or user has approved manual override)
- Plan file `plans/{slug}.md` exists with Phase `brainstorm`

---

## Feature-slice mode (default)

Read `docs/requirements/{name}.md` to get the full feature list (Small Features + Large Features sections).

**For each feature in the list, in dependency order:**

### Step 2a — Spec

Invoke the `writing-spec` skill for the feature. Wait for critic-spec PASS.

### Step 2b — Tests

Invoke the `writing-tests` skill for the feature. Wait for critic-test PASS and Plan file Phase `red`.

### Step 2c — Implementation

Invoke the `implementing` skill for the feature. Wait until the feature's tasks are `completed`.

Then move to the next feature. Repeat until all features are done.

---

## Batch mode (opt-in)

### Step 2 — Spec (all features)

Read `docs/requirements/{name}.md` to get the full feature list.

For each feature:
1. Invoke the `writing-spec` skill for that feature
2. Wait for critic-spec PASS before moving to the next feature

Do not proceed to Step 3 until all features have a PASS-verified spec.md.

### Step 3 — Tests (all features)

Invoke the `writing-tests` skill.

Do not proceed to Step 4 until:
- All failing tests are written (one per Scenario across all specs)
- critic-test returns PASS
- Plan file Phase is `red`

### Step 4 — Implementation

Invoke the `implementing` skill.

---

## Completion criteria

Cycle is complete when:
- All tasks are `completed`
- Plan file Phase is `done`
- No unresolved critic or pr-review-toolkit issues
