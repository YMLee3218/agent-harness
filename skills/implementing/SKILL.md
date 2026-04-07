---
name: implementing
description: >
  Implements code to make failing tests pass (Green), then refactors (Refactor). Trigger after critic-test returns PASS and the user says "implement", "make the tests pass", "Green phase", "go", or "proceed". Also trigger on "start implementing" or "execute". Run in plan mode first to propose implementation order, then execute with isolated subagents per task.
---

# Implementation Workflow

## Step 1 — Plan Implementation Order

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

Layer order: domain tasks first, then features, then infrastructure.
Mark tasks that can run in parallel (no shared file state).

Call `ExitPlanMode` to request approval.

## Step 2 — Track with TaskCreate

After approval:

```
TaskCreate([
  { content: "Implement {task 1}", status: "pending" },
  { content: "Implement {task 2}", status: "pending" },
  ...
])
```

## Step 3 — Execute per Task (isolated subagents)

For each task in dependency order, mark todo `in_progress`, then:

```
Task(
  subagent_type: "general-purpose",
  prompt: "Implement [goal]. Files: [paths].
           Failing test: [test code].
           Test command: [command from project CLAUDE.md].
           Green phase: write minimum code to pass the test. Nothing more.
           Then Refactor: remove duplication, improve naming. Tests must stay green.
           Run tests after every refactor change — must stay passing.
           Commit once after Refactor is complete. Do not commit after Green separately.
           If the refactor is substantial and independently reviewable, a second commit is acceptable.
           Commit format: {type}({scope}): {description}"
)
```

Do not pass the full plan or other tasks' state to subagents.

Mark todo `completed` after subagent returns. Move to next task.

## Step 4 — Run critic-code at Milestones

Track which files were changed during this milestone. Run after: a complete small feature, a domain concept's full rule set, or a significant chunk of a large feature.

```
Task(
  subagent_type: "critic-code",
  prompt: "Review these files: [explicit list of changed files].
           Spec at: [path]. Relevant docs: [paths to docs/*.md]."
)
```

If Critic returns FAIL:
1. Output the full verdict to the user
2. If the verdict contains `[DOCS CONTRADICTION]`:
   - Use `AskUserQuestion`: "Should docs be updated to match the implementation, or should the code be fixed to match docs?"
   - If docs update: update `docs/*.md` first
   - Write fix plan in order: spec → tests → code
3. Otherwise:
   - Write a fix plan in order: spec changes (if any) → test changes → code changes
4. Use `AskUserQuestion` to confirm the fix plan before editing
5. Apply fixes with `Edit`
6. Re-run `critic-spec` via `Task` with the same spec path and docs paths
7. Re-run `critic-test` via `Task` with the same test paths, spec path, and test command
8. Run the test command from project CLAUDE.md — all tests must pass
9. Re-run `critic-code` via `Task` with the same changed files, spec path, and docs paths

If any step 6–9 returns FAIL or tests fail, restart from step 1 of this FAIL handling (output the verdict and repeat).

## Step 5 — Run pr-review-toolkit

After all tasks complete:

```
/pr-review-toolkit:review-pr
```

If no issues are reported, this step is done.

If issues are reported, present the full list to the user, then categorise each with `AskUserQuestion`:

**Code-only** (naming, duplication, complexity, style, silent failures)
  → Fix the code directly
  → Run tests — all must pass
  → Re-run `critic-code` via `Task` with the same changed files, spec path, and docs paths
  → Re-run `/pr-review-toolkit:review-pr`

**Spec gap** (review reveals an unhandled scenario — e.g. missing error handling, missing test coverage for an edge case)
  → Add the scenario to the relevant `spec.md`
  → Re-run `critic-spec` via `Task` with the updated spec path and docs paths
  → Write a failing test for it — confirm it fails
  → Re-run `critic-test` via `Task` with the updated test paths, spec path, and test command
  → Implement the fix — confirm all tests pass
  → Re-run `critic-code` via `Task` with the changed files, spec path, and docs paths, then re-run `/pr-review-toolkit:review-pr`

**Docs conflict** (review reveals the implementation contradicts domain rules)
  → Update `docs/*.md` first (SOT)
  → Fix spec → re-run `critic-spec` via `Task` with the updated spec path and docs paths
  → Fix tests → re-run `critic-test` via `Task` with the updated test paths, spec path, and test command
  → Fix code — confirm all tests pass
  → Re-run `critic-code` via `Task` with the changed files, spec path, and docs paths, then re-run `/pr-review-toolkit:review-pr`

If any critic re-run returns FAIL or tests fail at any point, fix the issue and restart that path from the beginning.

## Session Recovery

Use `TaskList` to find the first `pending` or `in_progress` task and resume there.

## Hard Stop

Never commit a failing test. Never commit implementation without a passing test.
