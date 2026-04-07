---
name: implementing
description: >
  Implement Green phase (make failing tests pass) then Refactor.
  Trigger: "implement", "make the tests pass", "Green phase", "go", "proceed", after critic-test returns PASS.
  Plans implementation order (domain first), then executes with isolated subagents per task.
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

Set plan file phase:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" green
```

## Step 3 — Execute per task (isolated subagents)

Use `TaskList` to find the first `pending` task. Mark it `in_progress`, then:

Before spawning the subagent, determine the current file's layer by checking its path:
- `src/domain/` → **Domain**
- `src/infrastructure/` → **Infrastructure**
- `src/features/` small → **Small Feature**
- `src/features/` large → **Large Feature**

```
Agent(
  subagent_type: "coder",
  prompt: "Task: [goal]
           Target layer: [LAYER]
           Files: [paths]
           Phase: green  ← do NOT modify any test file
           Read-only paths (test files): [test file path(s)]
           Failing test: [test code]
           Test command: [command from project CLAUDE.md]
           Spec: [spec path]"
)
```

Do not pass the full plan or other tasks' state to subagents.

Mark task `completed` after subagent returns. Use `TaskList` to move to next task.

After all tasks complete, set plan file phase:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" refactor
```

## Step 4 — Run critic-code at milestones (max 2 iterations per milestone)

Iteration protocol: @reference/critic-loop.md

Track changed files during this milestone. Run after: a complete small feature, a domain concept's full rule set, or a significant chunk of a large feature.

```
Skill("critic-code", "Review these files: [explicit list]. Spec at: [path]. Relevant docs: [paths].")
```

On `[DOCS CONTRADICTION]`: update `docs/*.md` first, then cascade: re-run Skill("critic-spec") if spec changed → re-run Skill("critic-test") if tests changed → run test command → re-run Skill("critic-code").

When any cascade causes a phase rollback, append to `## Phase Transitions` in the plan file:
```
- {current-phase} → {rollback-phase} (reason: {one sentence})
```

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

Set plan file phase when all issues are resolved:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" done
```

## Session Recovery

Use `TaskList` to find the first `pending` or `in_progress` task and resume there. Read `plans/{slug}.md` to determine the current phase.

## Hard Stop

Never commit a failing test. Never commit implementation without a passing test.
