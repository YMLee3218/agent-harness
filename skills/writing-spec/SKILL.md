---
name: writing-spec
description: >
  Write BDD spec.md (Given/When/Then scenarios) for features and domain concepts.
  Trigger: "write the spec", "define scenarios", "document the behaviour", after brainstorming is approved.
  References only docs/*.md and brainstorming output — never reads src/.
  Do NOT trigger automatically — only on explicit user request or when called by running-dev-cycle.
effort: medium
paths:
  - features/**
  - domain/**
  - docs/**
  - plans/**
---

# BDD Spec Writing

## Step 1 — Read plan file + sources

Phase entry protocol: @reference/phase-ops.md §Skill phase entry — expected phases: `brainstorm`, `spec`.
On unexpected phase: apply **## Phase rollback** at the bottom of this skill (except phase `done`: `[BLOCKED] writing-spec entered from phase done — run /brainstorming to start a new feature`).

Read only:
1. `docs/requirements/*.md` — brainstorming output
2. `docs/*.md` — domain knowledge

Do not `Read` or `Glob` anything in `src/`.

If `docs/*.md` appears stale or contradictory to the requirement: log `[WARN] writing-spec: docs/{file}.md may contradict the requirement — continuing; critic-spec will flag [DOCS CONTRADICTION] if the spec needs updating`. Continue writing the spec.

## Step 2 — Draft scenarios

Write the full scenario structure to the plan file. Cover all Angle 1 checks in `critic-spec`.

Proceed directly to Step 3.

## Step 3 — Write spec.md

```
features/{verb}-{noun}/spec.md   ← feature spec
domain/{concept}/spec.md         ← domain spec
```

Set plan file phase (skip if phase is already `spec` — do not re-transition to the same phase; see `@reference/phase-ops.md §Skill phase entry`):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" spec \
  "approved plan — writing spec"
```

## Phase rollback

@reference/phase-ops.md §Phase Rollback Procedure — `{target-phase}` = `spec`, `{critic-name}` = `critic-spec`.

## Rules

@reference/bdd-templates.md §Rules

## Scenario templates

Templates and required boundary rows: `@reference/bdd-templates.md`
