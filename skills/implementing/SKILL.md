---
name: implementing
description: >
  Implements code to make failing tests pass (Green), then refactors (Refactor). Trigger after
  critic-test returns PASS and the user says "implement", "make the tests pass", "Green phase",
  "go", or "proceed". Run plan mode first to propose implementation order, then execute with
  isolated subagents per task.
paths:
  - "src/features/**"
  - "src/domain/**"
  - "src/infrastructure/**"
---

# Implementation Workflow

Layer rules: @reference/layers.md

## Step 1 — Read plan file + plan implementation order

Read `plans/{slug}.md` (resume context after `/compact`). Confirm Phase is `red`.

Use `EnterPlanMode`, then:
- `Read` the failing tests and `spec.md`
- `Glob` and `Read` existing domain/feature structure to determine dependencies

Use `AskUserQuestion` for architectural choices before committing:
- "Should this use an existing infrastructure adapter or a new one?"

Write task list to plan file:

```
Task N: {verb} {object}
  Files: {exact paths}
  Depends on: Task M (omit if none)
  Parallel: yes/no
```

Layer order: domain tasks first, then features, then infrastructure. Mark tasks that can run in parallel.

Call `ExitPlanMode` to request approval.

## Step 2 — Track tasks

After approval, create one task per implementation unit:

```
TaskCreate: "Implement {task 1 — domain: ...}"
TaskCreate: "Implement {task 2 — feature: ...}"
...
```

Update plan file Phase to `green`.

## Step 3 — Execute per task (isolated subagents)

Use `TaskList` to find the first `pending` task. Mark it `in_progress`, then:

```
Agent(
  subagent_type: "general-purpose",
  prompt: "Implement [goal]. Files: [paths].
           Failing test: [test code].
           Test command: [command from project CLAUDE.md].
           Green phase: write minimum code to pass the test. Nothing more.
           Then Refactor: remove duplication, improve naming. Tests must stay green.
           Run tests after every refactor change.
           Commit once after Refactor is complete.
           Commit format: {type}({scope}): {description}"
)
```

Do not pass the full plan or other tasks' state to subagents.

Mark task `completed` after subagent returns. Use `TaskList` to move to next task.

After all tasks complete, update plan file Phase to `refactor`.

## Step 4 — Run critic-code at milestones (max 2 iterations per milestone)

Track changed files during this milestone. Run after: a complete small feature, a domain concept's full rule set, or a significant chunk of a large feature.

```
Skill("critic-code", "Review these files: [explicit list]. Spec at: [path]. Relevant docs: [paths].")
```

**Iteration counter starts at 1.**

If Critic returns FAIL:
1. Output the full verdict
2. If `[DOCS CONTRADICTION]`: use `AskUserQuestion` — "Should docs be updated, or code fixed to match docs?"
   - Docs update: update `docs/*.md` first
   - Write fix plan: spec → tests → code
3. Otherwise: write fix plan: spec changes (if any) → test changes → code changes
4. Use `AskUserQuestion` to confirm fix plan
5. Apply fixes with `Edit`
6. If spec was modified: re-run Skill("critic-spec") with updated spec + docs paths
7. Re-run Skill("critic-test") with updated test paths, spec path, test command
8. Run the test command — all tests must pass
9. If iteration < 2: increment counter, re-run Skill("critic-code"). Else: use `AskUserQuestion` — "critic-code has failed twice. Paste the latest verdict for manual review."

Append verdict to plan file `## Critic Verdicts`.

## Step 5 — Run pr-review-toolkit

After all tasks complete, ensure a PR exists:

```bash
gh pr view 2>/dev/null || gh pr create --draft --title "feat: {feature name}" --body "Closes #{issue}"
```

Then invoke:

```
Skill("pr-review-toolkit:review-pr")
```

If no issues: done.

If issues reported, categorise each with `AskUserQuestion`:

**Code-only** (naming, duplication, complexity, style, silent failures):
→ Fix code → run tests → re-run Skill("critic-code") → re-run Skill("pr-review-toolkit:review-pr")

**Spec gap** (unhandled scenario revealed by review):
→ Add scenario to `spec.md` → re-run Skill("critic-spec") → write failing test → re-run Skill("critic-test") → implement → re-run Skill("critic-code") → re-run Skill("pr-review-toolkit:review-pr")

**Docs conflict** (implementation contradicts domain rules):
→ Update `docs/*.md` (SOT) → fix spec → re-run Skill("critic-spec") → fix tests → re-run Skill("critic-test") → fix code → re-run Skill("critic-code") → re-run Skill("pr-review-toolkit:review-pr")

Update plan file Phase to `done` when all issues are resolved.

## Session Recovery

Use `TaskList` to find the first `pending` or `in_progress` task and resume there. Read `plans/{slug}.md` to determine the current phase.

## Hard Stop

Never commit a failing test. Never commit implementation without a passing test.
