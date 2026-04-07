---
name: writing-spec
description: >
  Writes BDD spec.md files using Given/When/Then scenarios for features and domain concepts. Trigger after brainstorming is approved and the user says "write the spec", "define scenarios", "document the behaviour", or signals readiness to spec a feature. Also trigger for "spec", "scenario", "Given/When/Then", or "how should X behave". Reference only docs/*.md and brainstorming output — never read src/.
---

# BDD Spec Writing

## Step 1 — Read Sources (plan mode only)

Use `EnterPlanMode`, then read only:
1. `docs/requirements/*.md` — brainstorming output
2. `docs/*.md` — domain knowledge

Do not `Read` or `Glob` anything in `src/`.

If this is a modification, verify `docs/*.md` reflects the updated domain knowledge. If docs appear stale or contradictory, use `AskUserQuestion` to confirm with the user:
- "docs/{file}.md still says X, but the requirement implies Y. Should docs be updated first?"

If the user confirms docs need updating, stop. Do not proceed to Step 2. The user must update `docs/*.md` first and re-invoke this skill.

Use `AskUserQuestion` if spec type or scope is ambiguous:
- "Is this a feature spec or a domain spec?"
- "Which domain concepts does this feature interact with?"

## Step 2 — Draft Scenarios

Write the full scenario structure to the plan file:

```gherkin
Feature: {feature name}

  Scenario: {happy path}
    Given {initial condition}
    When  {action}
    Then  {expected outcome}

  Scenario: {failure case}
    Given {initial condition}
    When  {action}
    Then  {expected outcome}

  Scenario Outline: {parameterised case}
    Given {condition}
    When  {action}
    Then  {outcome}

    Examples:
      | {input1} | {input2} | {result} |
      | value    | value    | value    |
```

Cover for every scenario:
- Fails / partially succeeds / times out / external system down?
- Same request while processing? Prior step incomplete?
- Events out of order? Duplicate events?

Every `Scenario Outline` Examples table covers boundaries **applicable to the input type** (numeric: zero, negative one, maximum; collection: empty; nullable: null).

Call `ExitPlanMode` to request approval of the scenario structure.

## Step 3 — Write spec.md

After approval, write to the correct path:

```
features/{verb}-{noun}/spec.md   ← feature spec
domain/{concept}/spec.md         ← domain spec
```

Domain specs: no DB, HTTP, queue, or file system references.

## Step 4 — Run critic-spec

```
Task(
  subagent_type: "critic-spec",
  prompt: "Review spec at [path]. Relevant docs: [paths]."
)
```

If Critic returns FAIL:
1. Output the full verdict to the user
2. If the verdict contains `[DOCS CONTRADICTION]`:
   - Use `AskUserQuestion`: "Should docs be updated to match the spec, or should the spec be fixed to match docs?"
   - If docs update: update `docs/*.md` first, then fix spec if needed
   - If spec fix: write fix plan for spec changes
3. Otherwise:
   - Write a fix plan (which scenarios to add or which structural issues to resolve)
4. Use `AskUserQuestion` to confirm the fix plan before editing
5. Apply fixes with `Edit`
6. Re-run `critic-spec` via `Task` with the same spec path and docs paths

## Rules

- One `Feature:` block per file
- One `Scenario:` per distinct flow; same flow + different values → `Scenario Outline`
- No technology names, framework names, or implementation details
