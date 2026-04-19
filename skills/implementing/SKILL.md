---
name: implementing
description: >
  Implement phase (drive coder subagents to make failing tests pass, then refactor in-place).
  Trigger: "implement", "make the tests pass", "implement phase", "go", "proceed", after critic-test returns PASS.
  Do NOT trigger when no spec or tests exist — route to brainstorming instead.
  Plans implementation order (domain first), then executes with isolated subagents per task.
  Also drives `review` phase during pr-review fix loop (implement → review → green).
effort: high
paths:
  - src/**
  - tests/**
---

# Implementation Workflow

## Step 1 — Read plan file + plan implementation order

Phase entry protocol: @reference/critics.md §Skill phase entry — expected phases: `red`, `implement` (recovery), `review` (recovery).

Read `plans/{slug}.md` (resume context after `/compact`). Confirm Phase is `red` (normal entry), `implement` (recovery — task list already set), or `review` (recovery — pr-review loop).

- Phase is `review` and all tasks are `completed` → skip task planning; go directly to §Session Recovery (post-task pr-review branch).
- Phase is `review` and any tasks are NOT all `completed` → skip task planning; go directly to §Session Recovery (incomplete-tasks branch).
- Phase is `implement` and the Task Ledger is non-empty → skip task planning; go directly to §Session Recovery.
- Phase is `implement` and the Task Ledger is empty → go directly to §Session Recovery (fresh start).
- Phase is `red` → proceed with task planning below.
- Otherwise: append `[BLOCKED] implementing entered from unexpected phase {phase} — cannot proceed` to `## Open Questions` and stop.

**Phase `red` — plan task list:**

- `Read` the failing tests and `spec.md`
- `Glob` and `Read` existing domain/feature structure to determine dependencies

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

Proceed directly to Step 2.

## Step 2 — Track tasks

Create one task per implementation unit:

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

Advance to `implement` phase so that coder subagents (running in isolated git worktrees)
see a phase that permits `src/` writes. This must be committed before spawning coders —
worktrees inherit the committed plan file state:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" implement \
  "task list registered — advancing to implement"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" commit-phase "plans/{slug}.md" \
  "chore(phase): advance to implement — task list registered"
```

## Step 3 — Execute per task (isolated subagents)

Use `TaskList` to identify pending tasks grouped by layer tier. Within a tier, tasks marked `Parallel: yes` with no mutual dependencies **MUST be spawned in parallel** — issue all their `Agent(...)` calls in a single assistant turn.

Before spawning any subagent, mark each task `in_progress` in the Task Ledger:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-task "plans/{slug}.md" "task-1" "in_progress"
```

Record the current HEAD SHA before spawning so the abort check can detect whether the coder committed anything:
```bash
base_sha=$(git rev-parse HEAD)
```

Resolve the plan file to an absolute path before spawning coders — each coder runs in its own git worktree and needs a stable path to the shared plan file:
```bash
export CLAUDE_PLAN_FILE="$(pwd)/plans/{slug}.md"
```
Pass `CLAUDE_PLAN_FILE` to each coder via the prompt so it can call `plan-file.sh` if needed.

Determine each task's layer by checking its target path per `@reference/layers.md §Layers`.

Do not pass the full plan or other tasks' state to subagents.

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

Capture the `worktreeBranch` field from each `Agent` result; substitute it for `{worktree-branch}` in the abort-check and merge commands below.

Each coder runs in an isolated git worktree and commits its changes to a temporary branch. After each subagent returns, **check for abort before merging**:

1. Check for abort: look for `<!-- coder-status: abort -->` in the last line of the coder's output. If absent, fall back to scanning for abort signals: "layer violation", "forbidden import", "hard stop", "STOP", "I stopped", "aborting".
2. Verify the worktree branch exists, then check whether the coder committed:
   ```bash
   git rev-parse --verify {worktree-branch} >/dev/null 2>&1 \
     || abort_reason="worktree branch not found — Agent spawn may have failed"
   git rev-list --count "$base_sha"..{worktree-branch}  # 0 = no commit made
   ```
   If the branch does not exist (spawn failed), treat it as an abort with reason "worktree branch not found — Agent spawn may have failed".
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

**Atomic tier rule**: process abort/merge-conflict checks for ALL tasks in the tier before merging any. If any task in the tier aborted or had a merge conflict, do NOT merge any task in the tier — including those that completed successfully. A partial-tier merge leaves `src/` in an inconsistent state where some tasks' assumptions do not hold.

Before merging any task in the tier, run the tier safety check with the IDs of all tasks in the current tier:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" tier-safe \
  "plans/{slug}.md" task-1 task-2 task-3 || {
  echo "[BLOCKED] tier merge aborted — at least one task is blocked" >&2
  exit 2
}
```

If no tasks aborted and no conflicts, merge each successful task in sequence and record as normal:
```bash
git merge --no-ff {worktree-branch} -m "merge(task-N): {description}"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-task "plans/{slug}.md" "task-1" "completed" "$(git rev-parse HEAD)"
```

If `git merge` fails with conflicts:
1. Mark the task blocked: `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-task "plans/{slug}.md" "task-N" "blocked"`
2. Abort the merge: `git merge --abort`
3. Append `[BLOCKED] coder:task-N merge conflict — resolve conflict in {worktree-branch} then re-run implementing` to `## Open Questions` and stop the current tier.
4. On success after manual resolution, update the task to `completed` with the merge SHA.

Then mark the corresponding `TaskCreate` task `completed`. Move to the next tier.

## Step 3.5 — Post-tier smoke test

After all tasks in a tier are merged, run the unit test command from project CLAUDE.md.

If tests pass: continue to Step 4.

If tests fail: append `[BLOCKED] post-tier merge test failure — {failing test list}` to `## Open Questions` in the plan file, then stop.

## Step 4 — Run critic-code at milestones (convergence loop per milestone)

Full protocol: @reference/critics.md §Loop convergence

Track changed files during this milestone. Run after: a complete small feature, a domain concept's full rule set, or a significant chunk of a large feature.

**Before the first critic-code run of each milestone** (once per milestone, not on retry runs within the same milestone), reset the convergence state: @reference/critics.md §New milestone — critic=`critic-code`.

```
Skill("critic-code", "Review these files: [explicit list]. Spec at: [path]. Relevant docs: [paths].")
```

After each run, follow @reference/critics.md §Running the critic and @reference/critics.md §Skill branching logic, substituting `critic-code` for `{agent}`.

On `[CONVERGED] {phase}/critic-code`: proceed to next milestone or Step 5.

On `[DOCS CONTRADICTION]` (during implement phase): @reference/critics.md §DOCS CONTRADICTION cascade
(Skip the **During `review` phase** section — this is the implement phase.)

## Step 5 — Run pr-review-toolkit

After all tasks complete, reset the pr-review convergence state. This clears all stale pr-review markers (both `implement`-scoped and `review`-scoped) left by prior features in slice mode and adds a milestone boundary, so this feature requires a fresh 2-PASS streak:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-pr-review "plans/{slug}.md"
```

Ensure a PR exists:

```bash
gh pr view 2>/dev/null || gh pr create --draft --title "feat: {feature name}" --body "Closes #{issue}"
```

Then run the review loop (convergence policy: @reference/critics.md §Loop convergence):

```
Skill("pr-review-toolkit:review-pr")
```

After each run, **before** recording the verdict, run §Ultrathink verdict audit (`@reference/critics.md §Ultrathink verdict audit`).

> `pr-review-toolkit:review-pr` satisfies the subagent mandate (`@reference/critics.md §Review execution rule`) because the plugin internally orchestrates `pr-review-toolkit:code-reviewer`, `…:pr-test-analyzer`, `…:silent-failure-hunter`, `…:comment-analyzer`, and `…:type-design-analyzer` subagents.

Apply `@reference/critics.md §Applying the audit outcome` with `{agent}` = `pr-review`.

Record the verdict (PASS or FAIL — use the audit-adjusted verdict if REJECT-PASS):

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-review-verdict \
  "plans/{slug}.md" "pr-review" PASS|FAIL
```

Read `## Open Questions` for `pr-review` markers and branch per `@reference/critics.md §pr-review asymmetry`.

On FAIL: apply `@reference/critics.md §pr-review fix loop`.

Set plan file phase to `green` when `[CONVERGED] {phase}/pr-review` is confirmed:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" green \
  "pr-review converged — all checks passed"
```

> Do **not** set `done` here — `find-active` drops `done` plans. `done` is set by `running-integration-tests` or `running-dev-cycle`.

## Session Recovery

Run `TaskList`. Mark any `in_progress` task that has a `commit-sha` as `completed`. Then branch:

| Phase / Ledger state | Entry point |
|---|---|
| `red`, empty ledger | Step 1 (task planning) |
| `implement` or `red`, has pending tasks | Step 3 |
| `implement` or `red`, all tasks complete | Step 4 (critic-code) |
| `review` or `green`, all complete | Step 5 (pr-review) |
| `review` or `green`, incomplete | `transition implement` → Step 3 |
| any, has `blocked` task | `update-task … pending` → re-invoke |

Proceed directly to the next step (no plan mode needed).

Unblock recipe: `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-task "plans/{slug}.md" "task-N" "pending"` then re-invoke.

For `fresh-start` (empty Task Ledger on `implement` entry): define one task and proceed to Step 2 then Step 3:
```
Task 1: apply change
  Files: {target file path}
  Layer: {domain|infrastructure|small-feature — infer from the path}
  Depends on: none
  Parallel: no
```
