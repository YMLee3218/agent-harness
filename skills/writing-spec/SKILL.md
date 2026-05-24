---
name: writing-spec
description: >
  Write BDD spec.md (Given/When/Then scenarios) for features, domain concepts, and infrastructure components.
  Trigger: "write the spec", "define scenarios", "document the behaviour", after brainstorming is approved.
  References only docs/*.md and brainstorming output — never reads src/.
  Do NOT trigger automatically — only on explicit user request or when called by running-dev-cycle.
context: fork
agent: spec-writer
paths:
  - features/**
  - domain/**
  - infrastructure/**
  - docs/**
  - plans/**
---

# BDD Spec Writing

## Step 1 — Read plan file + sources

Phase entry protocol: @reference/phase-ops.md §Skill phase entry — expected phases: `brainstorm`, `spec`.
On unexpected phase: apply **## Phase rollback** at the bottom of this skill (except phase `done`: `[BLOCKED:env] writing-spec: unexpected-phase — entered from done; run /brainstorming to start a new feature`).

Content sources:
1. `docs/requirements/*.md` — brainstorming output
2. `docs/*.md` — domain knowledge

Do not `Read` or `Glob` anything in `src/`.

If `docs/*.md` appears stale or contradictory to the requirement: log `[INFO] writing-spec: docs/{file}.md may contradict the requirement — continuing; critic-spec will flag [DOCS CONTRADICTION] if the spec needs updating`. Continue writing the spec.

## Step 2 — Carry Operating Envelope into spec

Brainstorming declares all 6 envelope axes per candidate in the plan file (brainstorming Step 2); critic-feature verifies them before writing-spec runs. Read the plan file and extract the declared axis values for this feature. Write them as the `## Operating Envelope` section in the plan file — it becomes the **first section** of spec.md in Step 4:

```markdown
## Operating Envelope

- **Actors**: <value declared by brainstorming>
- **Frequency**: <value declared by brainstorming>
- **Concurrency**: <value declared by brainstorming>
- **Persistence**: <value declared by brainstorming>
- **Failure model**: <value declared by brainstorming>
- **External I/O**: <value declared by brainstorming>
```

Legal axis values and the filled-vs-placeholder definition: `@reference/operating-envelope.md`

If the envelope is absent from the plan file or any axis still has placeholder syntax (curly braces): `[BLOCKED:spec] writing-spec: envelope-incomplete — re-run /brainstorming to declare all axes first` and add to `## Open Questions` — do not proceed until resolved.

If an axis value in the plan file is not a **verbatim match** for a value in `operating-envelope.md §Axis table` (i.e. the value was not in the enum when brainstorming ran, or brainstorming produced a wording variant): do not silently carry the non-conforming value into spec.md. (Exception: where the axis table explicitly permits comma-separated compound values — currently only External I/O — each comma-separated element must independently be a verbatim enum value; the compound form itself counts as a verbatim match.) If brainstorming already emitted a `[BLOCKED:harness] … reference-extension` marker for this axis, halt without re-emitting. Otherwise emit:
```
[BLOCKED:harness] writing-spec: reference-extension — axis {name} value '{value}' is not a verbatim match for operating-envelope.md; proposed addition or correction needed. Feature: {slug}.
```
Add to `## Open Questions` and halt.

Scenarios must stay within this envelope. Do not draft scenarios that require an axis value beyond what is declared above.

If the feature is classified `internal` in the plan file's brainstorm output: carry the `(propagated from: ...)` annotation into spec.md as a comment line immediately after the `## Operating Envelope` block:
```markdown
# Frequency and Concurrency propagated from callers: {caller-list}
# (per @reference/operating-envelope.md §Axis semantic types).
```
Entry-point features omit this comment. If Frequency or Concurrency show `(propagated)` in the plan file without a computed value (propagation sub-step not completed): `[BLOCKED:spec] writing-spec: envelope-propagation-incomplete — re-run /brainstorming Step 2 propagation sub-step`.

## Step 3 — Draft scenarios

Write the full scenario structure to the plan file. Cover all Angle 1 checks in `critic-spec`.

Proceed directly to Step 4.

## Step 4 — Write spec.md

Read `docs/requirements/*.md` and identify ALL components implied by the feature requirements.
Classify each component by layer using `@reference/layers.md §Layers`, then write to the spec path from `@reference/layers.md §Naming conventions` (§Layer-to-spec-path mapping is canonical).

Start spec.md with the `## Operating Envelope` section copied verbatim from the plan file (the values written in Step 2). It must be the first section before any scenarios.

This is the only phase where domain concepts and infrastructure components are identified.

Plan phase transition to `spec`: in autonomous mode the harness (`dev-cycle-phases.sh`) transitions `brainstorm`→`spec` **after** this skill completes, so the plan is still in `brainstorm` during skill execution and advances to `spec` immediately after. In interactive use, the agent cannot call `plan-file.sh transition` (Ring B requires `CLAUDE_PLAN_CAPABILITY=harness`); after the skill completes, run this from a human terminal:
```bash
export CLAUDE_PLAN_CAPABILITY=harness
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" spec \
  "approved plan — writing spec"
```

## Phase rollback

@reference/phase-ops.md §Phase Rollback Procedure — `{target-phase}` = `spec`, `{critic-name}` = `critic-spec`.

## Rules

@reference/bdd-templates.md §Rules

## Scenario templates

Templates and required boundary coverage: `@reference/bdd-templates.md`
