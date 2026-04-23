---
name: implementing
description: >
  Implement phase (drive coder subagents to make failing tests pass, then refactor in-place).
  Trigger: "implement", "make the tests pass", "implement phase", "go", "proceed", after critic-test returns PASS.
  Do NOT trigger when no spec or tests exist — route to brainstorming instead.
  Plans implementation order (domain first), then executes with isolated subagents per task.
  Also drives `review` phase during pr-review fix loop (implement → review → green).
disable-model-invocation: true
effort: high
paths:
  - src/**
  - tests/**
---

# Implementation Workflow

## Step 1 — Read plan file + plan implementation order

Phase entry protocol: @reference/phase-ops.md §Skill phase entry — expected phases: `red`, `implement` (recovery), `review` (recovery). Read `plans/{slug}.md`. For non-`red` phases or non-empty Task Ledgers, consult §Session Recovery. For unexpected phases: `[BLOCKED] implementing entered from unexpected phase {phase} — cannot proceed`.

**Phase `red` — plan task list:**

- Read failing tests, `spec.md`, and existing domain/feature structure.

Reuse any existing adapter whose interface already matches the requirement; if none, create a minimal new adapter. Log `[AUTO-DECIDED] implementing/Step1: {decision}` to `## Open Questions`.

Write task list to plan file:

```
Task N: {verb} {object}
  Files: {exact paths}
  Layer: domain|infrastructure|small-feature|large-feature
  Depends on: Task M (omit if none)
  Parallel: yes/no
```

Layer order: domain tasks first, then features, then infrastructure. Mark tasks that can run in parallel within the same layer tier (no cross-task dependency within the tier).

## Step 2 — Track tasks

Create one task per implementation unit and register in the plan file Task Ledger:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" add-task "plans/{slug}.md" "task-1" "domain"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" add-task "plans/{slug}.md" "task-2" "small-feature"
# ... one call per task
```

Commit the `implement` phase transition before spawning coders (worktrees inherit committed state):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" implement \
  "task list registered — advancing to implement"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" commit-phase "plans/{slug}.md" \
  "chore(phase): advance to implement — task list registered"
```

## Step 3 — Execute per task (isolated subagents)

Read `plans/{slug}.md` and check the `## Task Ledger` section to identify pending tasks by layer tier. Within a tier, `Parallel: yes` tasks **MUST be spawned in parallel** — issue all `Agent(...)` calls in a single turn.

Before spawning, mark tasks `in_progress`, record base SHA, and resolve plan file path:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-task "plans/{slug}.md" "task-1" "in_progress"
base_sha=$(git rev-parse HEAD)
export CLAUDE_PLAN_FILE="$(pwd)/plans/{slug}.md"
```
Pass `CLAUDE_PLAN_FILE` via the coder prompt. Determine each task's layer from `@reference/layers.md §Layers`. Do not pass the full plan to subagents.

```
Agent(
  subagent_type: "coder",
  isolation: "worktree",
  prompt: "Task: [goal]
           Task ID: task-{N}
           Target layer: [LAYER]
           Files: [paths]
           Phase: implement  ← do NOT modify any test file
           Read-only paths (test files): [test file path(s)]
           Failing test: [test code]
           Test command: [command from project CLAUDE.md]
           Spec: [spec path]
           CLAUDE_PLAN_FILE: [absolute path to plans/{slug}.md]"
)
```

Capture `worktreeBranch` from each `Agent` result. After each returns, **check for abort before merging**:

1. Check for abort: look for `<!-- coder-status: abort -->` in the last line of the coder's output. If absent, fall back to scanning for abort signals: "layer violation", "forbidden import", "cannot implement without violating", "would violate", "stopping", "hard stop", "STOP", "I stopped", "aborting".
2. Verify the worktree branch exists and check whether the coder committed:
   ```bash
   git rev-parse --verify {worktree-branch} >/dev/null 2>&1 \
     || abort_reason="worktree branch not found — Agent spawn may have failed"
   git rev-list --count "$base_sha"..{worktree-branch}  # 0 = no commit made
   ```
3. If either signal is present:
   - Do NOT run `git merge`.
   - Mark the task blocked:
     ```bash
     bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-task "plans/{slug}.md" "task-N" "blocked"
     ```
   - Append to `## Open Questions`:
     ```
     [BLOCKED] coder:task-N aborted without commit — {reason from coder output}
     ```
   - Stop the current tier; do not attempt remaining tasks in this tier.

**Atomic tier rule**: check ALL tier tasks for abort/conflict before merging any. Run:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" tier-safe \
  "plans/{slug}.md" task-1 task-2 task-3 \
  || { echo "[BLOCKED] tier merge aborted — at least one task is blocked" >&2; exit 2; }
```

If no tasks aborted and no conflicts, merge each successful task in sequence and record as normal:
```bash
git merge --no-ff {worktree-branch} -m "merge(task-N): {description}"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-task "plans/{slug}.md" "task-1" "completed" "$(git rev-parse HEAD)"
```

If `git merge` fails with conflicts: mark task `blocked`, run `git merge --abort`, append `[BLOCKED] coder:task-N merge conflict — resolve conflict in {worktree-branch} then re-run implementing` to `## Open Questions`, stop the tier. After manual resolution, update task to `completed` with merge SHA.

Move to the next tier.

## Step 3.5 — Post-tier smoke test

After all tasks in a tier are merged, run the unit test command from project CLAUDE.md.

If tests pass: continue to Step 4.

If tests fail: append `[BLOCKED] post-tier merge test failure — {failing test list}` to `## Open Questions` in the plan file, then stop.

## Step 4 — Run critic-code at milestones (convergence loop per milestone)

Track changed files. Run after: a complete small feature, a domain concept's full rule set, or a significant chunk of a large feature.

**Before each milestone's first run**, reset: @reference/critics.md §New milestone — critic=`critic-code`.

Run @reference/critics.md §Invocation recipe with agent=`critic-code`, phase=`implement`, prompt="Review these files: [explicit list]. Spec at: [path]. Relevant docs: [paths]."

On `[CONVERGED]`: proceed to next milestone or Step 5. On `[DOCS CONTRADICTION]` (implement phase): `@reference/phase-ops.md §DOCS CONTRADICTION cascade` (skip **During `review` phase**).

## Step 5 — Run pr-review-toolkit

After all tasks complete, reset pr-review convergence state (clears stale markers, adds milestone boundary):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-pr-review "plans/{slug}.md"
```

Ensure a PR exists: `gh pr view 2>/dev/null || gh pr create --draft --title "feat: {feature name}" --body "Closes #{issue}"`

Run the review loop (per @reference/critics.md §pr-review asymmetry): `Skill("pr-review-toolkit:review-pr")`

Record the verdict:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-review-verdict \
  "plans/{slug}.md" "pr-review" PASS|FAIL
```

Then run `@reference/ultrathink.md §Ultrathink verdict audit` → `@reference/ultrathink.md §Applying the audit outcome` (`{agent}`=`pr-review`).

Read `## Open Questions` for `pr-review` markers and branch per `@reference/critics.md §pr-review asymmetry`.

On FAIL: apply `@reference/pr-review-loop.md`.

Set plan file phase to `green` when `[CONVERGED] {phase}/pr-review` is confirmed:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" green \
  "pr-review converged — all checks passed"
```

> Do **not** set `done` here — `find-active` drops `done` plans. `done` is set by `running-integration-tests` or `running-dev-cycle`.

## Session Recovery

Read `plans/{slug}.md` and check the `## Task Ledger` section. Mark any `in_progress` task that has a `commit-sha` as `completed`. Mark any `in_progress` task without a `commit-sha` as `pending` (interrupted coder session — no commit was made). Then branch:

| Phase / Ledger state | Entry point |
|---|---|
| `red`, empty ledger | Step 1 (task planning) |
| `implement` or `red`, has pending tasks | Step 3 |
| `implement` or `red`, all tasks complete | Step 4 (critic-code) |
| `review` or `green`, all complete | Step 5 (pr-review) |
| `review` or `green`, incomplete | `transition implement` → Step 3 |
| any, has `blocked` task | `update-task … pending` → re-invoke |
| `implement`, empty ledger (fresh-start) | define one task → Step 2 → Step 3 |

Proceed directly to the next step (no plan mode needed).

Unblock recipe: `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-task "plans/{slug}.md" "task-N" "pending"` then re-invoke.
