---
name: implementing
description: >
  Implement Green phase (make failing tests pass, then refactor in-place within Green).
  Trigger: "implement", "make the tests pass", "Green phase", "go", "proceed", after critic-test returns PASS.
  Do NOT trigger when no spec or tests exist — route to brainstorming instead.
  Plans implementation order (domain first), then executes with isolated subagents per task.
effort: high
paths:
  - src/**
  - tests/**
---

# Implementation Workflow

Layer rules: @reference/layers.md
Context hygiene: @reference/context-hygiene.md

## Step 1 — Read plan file + plan implementation order

Read `plans/{slug}.md` (resume context after `/compact`). Confirm Phase is `red`.

- `Read` the failing tests and `spec.md`
- `Glob` and `Read` existing domain/feature structure to determine dependencies

Use `AskUserQuestion` for architectural choices before committing:
- "Should this use an existing infrastructure adapter or a new one?"

Write task list to plan file:

```
Task N: {verb} {object}
  Files: {exact paths}
  Layer: domain|infrastructure|small-feature|large-feature
  Depends on: Task M (omit if none)
  Parallel: yes/no
```

Layer order: domain tasks first, then features, then infrastructure. Mark tasks that can run in parallel within the same layer tier (no cross-task dependency within the tier).

Use `AskUserQuestion` to present the task list and request approval before proceeding.

## Step 2 — Track tasks

After approval, create one task per implementation unit:

```
TaskCreate: "Implement {task 1 — domain: ...}"
TaskCreate: "Implement {task 2 — feature: ...}"
...
```

Register tasks in the plan file Task Ledger:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" add-task "plans/{slug}.md" "task-1" "domain"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" add-task "plans/{slug}.md" "task-2" "small-feature"
# ... one call per task
```

Set plan file phase:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" green
```

## Step 3 — Execute per task (isolated subagents)

Use `TaskList` to identify pending tasks grouped by layer tier. Within a tier, tasks marked `Parallel: yes` with no mutual dependencies **MUST be spawned in parallel** — issue all their `Agent(...)` calls in a single assistant turn.

Before spawning any subagent, mark each task `in_progress` in the Task Ledger:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-task "plans/{slug}.md" "task-1" "in_progress"
```

Resolve the plan file to an absolute path before spawning coders — each coder runs in its own git worktree and needs a stable path to the shared plan file:
```bash
export CLAUDE_PLAN_FILE="$(pwd)/plans/{slug}.md"
```
Pass `CLAUDE_PLAN_FILE` to each coder via the prompt so it can call `plan-file.sh` if needed.

Determine each task's layer by checking its target path:
- `src/domain/` → **Domain**
- `src/infrastructure/` → **Infrastructure**
- `src/features/` small → **Small Feature**
- `src/features/` large → **Large Feature**

```
Agent(
  subagent_type: "coder",
  isolation: "worktree",
  prompt: "Task: [goal]
           Target layer: [LAYER]
           Files: [paths]
           Phase: green  ← do NOT modify any test file
           Read-only paths (test files): [test file path(s)]
           Failing test: [test code]
           Test command: [command from project CLAUDE.md]
           Spec: [spec path]
           CLAUDE_PLAN_FILE: [absolute path to plans/{slug}.md]"
)
```

Do not pass the full plan or other tasks' state to subagents.

Each coder runs in an isolated git worktree and commits its changes to a temporary branch. After each subagent returns, merge its branch back and update the Task Ledger:
```bash
git merge --no-ff {worktree-branch} -m "merge(task-N): {description}"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-task "plans/{slug}.md" "task-1" "completed" "$(git rev-parse HEAD)"
```

If `git merge` fails with conflicts:
1. Mark the task blocked: `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-task "plans/{slug}.md" "task-N" "blocked"`
2. Abort the merge: `git merge --abort`
3. Resolve conflicts manually (or re-run the coder with explicit conflict context), then re-attempt the merge.
4. On success, update the task to `completed` with the merge SHA.

Then mark the corresponding `TaskCreate` task `completed`. Move to the next tier.

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

Use `TaskList` to find the first `pending` or `in_progress` task and resume there. For `in_progress` tasks, check the Task Ledger in `plans/{slug}.md` — if a commit-sha is recorded the task was committed; mark it `completed` and continue. Read `plans/{slug}.md` to determine the current phase.

## Hard Stop

Never commit a failing test. Never commit implementation without a passing test.
