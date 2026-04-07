---
name: writing-spec
description: >
  Write BDD spec.md (Given/When/Then scenarios) for features and domain concepts.
  Trigger: "write the spec", "define scenarios", "document the behaviour", after brainstorming is approved.
  References only docs/*.md and brainstorming output — never reads src/.
---

# BDD Spec Writing

Scenario templates: @reference/bdd-template.md
Layer rules: @reference/layers.md

## Step 1 — Read plan file + sources

Read `plans/{slug}.md` (resume context after `/compact`). Confirm Phase is `brainstorm` or `spec`.

Use `EnterPlanMode`, then read only:
1. `docs/requirements/*.md` — brainstorming output
2. `docs/*.md` — domain knowledge

Do not `Read` or `Glob` anything in `src/`.

If `docs/*.md` appears stale or contradictory to the requirement, use `AskUserQuestion`:
- "docs/{file}.md still says X, but the requirement implies Y. Should docs be updated first?"

If docs need updating, stop. Re-invoke after `docs/*.md` is updated.

## Step 2 — Draft scenarios

Write the full scenario structure to the plan file. Cover for every scenario:
- Fails / partially succeeds / times out / external system down?
- Same request while processing? Prior step incomplete?
- Events out of order? Duplicate events?

Every `Scenario Outline` Examples table must include boundaries for the input type:
- **Numeric**: zero (`0`), negative one (`-1`), maximum
- **Collection**: empty (`[]`)
- **String**: empty (`""`), max-length
- **Nullable**: `null` / absent
- **Boolean**: `true`, `false`

Call `ExitPlanMode` to request approval.

## Step 3 — Write spec.md

After approval:

```
features/{verb}-{noun}/spec.md   ← feature spec
domain/{concept}/spec.md         ← domain spec
```

Domain specs: no DB, HTTP, queue, or file system references.

Set plan file phase:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" spec
```

## Step 4 — Run critic-spec (max 2 iterations)

Iteration protocol: @reference/critic-loop.md

```
Skill("critic-spec", "Review spec at [path]. Relevant docs: [paths].")
```

On `[DOCS CONTRADICTION]`: update `docs/*.md` first, then fix the spec to match.

## Phase rollback

If re-entering `writing-spec` from a later phase (e.g., a bug or review revealed the spec was wrong):
1. Preserve all existing `## Critic Verdicts` — do not delete them
2. Append a phase transition entry to `## Phase Transitions`:
   ```
   - {previous-phase} → spec (reason: {one sentence})
   ```
3. Set plan phase: `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" spec`
4. Proceed normally from Step 2

## Rules

- One `Feature:` block per file
- One `Scenario:` per distinct flow; same flow + different values → `Scenario Outline`
- No technology names, framework names, or implementation details
