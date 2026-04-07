---
name: writing-spec
description: >
  Writes BDD spec.md files using Given/When/Then scenarios for features and domain concepts.
  Trigger after brainstorming is approved and the user says "write the spec", "define scenarios",
  "document the behaviour", or signals readiness to spec a feature. Reference only docs/*.md and
  brainstorming output — never read src/.
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

Update plan file Phase to `spec`.

## Step 4 — Run critic-spec (max 2 iterations)

```
Skill("critic-spec", "Review spec at [path]. Relevant docs: [paths].")
```

**Iteration counter starts at 1.**

If Critic returns FAIL:
1. Output the full verdict
2. If `[DOCS CONTRADICTION]`: use `AskUserQuestion` — "Should docs be updated to match the spec, or spec fixed to match docs?"
   - Docs update: update `docs/*.md` first, then fix spec
   - Spec fix: write fix plan for spec changes
3. Otherwise: write fix plan (which scenarios to add or structural issues to resolve)
4. Use `AskUserQuestion` to confirm fix plan
5. Apply fixes with `Edit`
6. If iteration < 2: increment counter, re-run Skill("critic-spec"). Else: use `AskUserQuestion` — "critic-spec has failed twice. Paste the latest verdict for manual review, or describe how to proceed."

Append verdict to plan file `## Critic Verdicts`.

## Rules

- One `Feature:` block per file
- One `Scenario:` per distinct flow; same flow + different values → `Scenario Outline`
- No technology names, framework names, or implementation details
