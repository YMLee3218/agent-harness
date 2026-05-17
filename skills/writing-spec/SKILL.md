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

Read only:
1. `docs/requirements/*.md` — brainstorming output
2. `docs/*.md` — domain knowledge

Do not `Read` or `Glob` anything in `src/`.

If `docs/*.md` appears stale or contradictory to the requirement: log `[WARN] writing-spec: docs/{file}.md may contradict the requirement — continuing; critic-spec will flag [DOCS CONTRADICTION] if the spec needs updating`. Continue writing the spec.

## Step 2 — Declare Operating Envelope

Before drafting any scenario, fill in the Operating Envelope in the plan file — it will become the **first section** of spec.md in Step 4:

```markdown
## Operating Envelope

- **Actors**: {1 user | N users | tenants}
- **Frequency**: {one-shot | periodic 1/min | per-request | bursty}
- **Concurrency**: {none | reader-writer | multi-writer}
- **Persistence**: {ephemeral | best-effort | durable | zero-loss}
- **Failure model**: {crash-stop | crash-recover | partial-failure}
- **External I/O**: {none | file | network | distributed}
```

Each axis must be declared explicitly. If an axis cannot be determined from the requirement, write `[BLOCKED:spec] writing-spec: ambiguous — axis {name} cannot be determined` and add it to `## Open Questions` — do not proceed until it is resolved.

Scenarios must stay within this envelope. Do not draft scenarios that require an axis value beyond what is declared above.

## Step 3 — Draft scenarios

Write the full scenario structure to the plan file. Cover all Angle 1 checks in `critic-spec`.

Proceed directly to Step 4.

## Step 4 — Write spec.md

Read `docs/requirements/*.md` and identify ALL components implied by the feature requirements.
Classify each component by layer using `@reference/layers.md §Layers`, then write to the spec path from `@reference/layers.md §Naming conventions` (§Layer-to-spec-path mapping is canonical).

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
