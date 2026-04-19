---
name: writing-spec
description: >
  Write BDD spec.md (Given/When/Then scenarios) for features and domain concepts.
  Trigger: "write the spec", "define scenarios", "document the behaviour", after brainstorming is approved.
  References only docs/*.md and brainstorming output — never reads src/.
effort: medium
paths:
  - features/**
  - domain/**
  - docs/**
  - plans/**
---

# BDD Spec Writing

## Step 1 — Read plan file + sources

Phase entry protocol: @reference/critics.md §Skill phase entry — expected phases: `brainstorm`, `spec`.
On unexpected phase: apply **## Phase rollback** at the bottom of this skill.

Read only:
1. `docs/requirements/*.md` — brainstorming output
2. `docs/*.md` — domain knowledge

Do not `Read` or `Glob` anything in `src/`.

If `docs/*.md` appears stale or contradictory to the requirement: log `[WARN] writing-spec: docs/{file}.md may contradict the requirement — continuing; critic-spec will flag [DOCS CONTRADICTION] if the spec needs updating`. Continue writing the spec.

## Step 2 — Draft scenarios

Write the full scenario structure to the plan file. Cover for every scenario:
- Fails / partially succeeds / times out / external system down?
- Same request while processing? Prior step incomplete?
- Events out of order? Duplicate events?

Every `Scenario Outline` Examples table must include boundaries per §Required boundary rows by input type.

Proceed directly to Step 3.

## Step 3 — Write spec.md

After approval:

```
features/{verb}-{noun}/spec.md   ← feature spec
domain/{concept}/spec.md         ← domain spec
```

Set plan file phase:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" spec \
  "approved plan — writing spec"
```

## Step 4 — Run critic-spec (convergence loop)

Full protocol: @reference/critics.md §Loop convergence

```
Skill("critic-spec", "Review spec at [path]. Relevant docs: [paths].")
```

After each run, follow @reference/critics.md §Running the critic and @reference/critics.md §Skill branching logic, substituting `critic-spec` for `{agent}`.

On `[CONVERGED] {phase}/critic-spec`: proceed to Step 5.
On `[DOCS CONTRADICTION]`: @reference/critics.md §DOCS CONTRADICTION cascade

## Step 5 — Commit spec file

After critic-spec PASS, commit the spec file so it is visible to coder subagents running in isolated worktrees:

```bash
git add features/{verb}-{noun}/spec.md   # feature spec
# or
git add domain/{concept}/spec.md         # domain spec
git commit -m "feat(spec): add BDD scenarios for {name}"
```

Commit all spec files written in this run in a single commit. Do not commit any src/ or tests/ files here.

## Phase rollback

Triggered when re-entering from a later phase (slice mode or explicit rollback).

Apply @reference/critics.md §Phase Rollback Procedure with `{target-phase}` = `spec`, `{critic-name}` = `critic-spec`, `{skill-name}` = `writing-spec`.

## Rules

- One `Feature:` block per file
- Every `Scenario Outline` must have `Examples:`
- No technology names (no DB engines, HTTP libraries, framework names)
- No implementation details in Given/When/Then steps
- Domain specs: no DB, HTTP, queue, or file system references
- One `Scenario:` per distinct flow; same flow + different values → `Scenario Outline`.

## Scenario templates

Templates and required boundary rows: `@reference/bdd-templates.md`
