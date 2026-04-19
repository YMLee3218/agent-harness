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

**Non-interactive handling** (`CLAUDE_NONINTERACTIVE=1`): replace every `AskUserQuestion` per `@reference/non-interactive-mode.md §AskUserQuestion replacement`. `[BLOCKED] {description}` goes to `## Open Questions` when decision is required; `[AUTO-DECIDED] {decision}` when skill may proceed.

# Implementation Workflow

## Step 1 — Read plan file + plan implementation order

Phase entry protocol: @reference/critics.md §Skill phase entry — expected phases: `red`, `implement` (recovery), `review` (recovery).

@reference/non-interactive-mode.md §EnterPlanMode / ExitPlanMode

Read `plans/{slug}.md` (resume context after `/compact`). Confirm Phase is `red` (normal entry), `implement` (recovery — task list already set), or `review` (recovery — pr-review loop).

- Phase is `review` and all tasks are `completed` → skip task planning; go directly to §Session Recovery (post-task pr-review branch).
- Phase is `review` and any tasks are NOT all `completed` → skip task planning; go directly to §Session Recovery (incomplete-tasks branch).
- Phase is `implement` and the Task Ledger is non-empty → skip task planning; go directly to §Session Recovery.
- Phase is `implement` and the Task Ledger is empty → go directly to §Session Recovery (trivial profile fresh start).
- Phase is `red` → proceed with task planning below.
- Otherwise: append `[BLOCKED] implementing entered from unexpected phase {phase} — cannot proceed` to `## Open Questions` and stop.

**Phase `red` — plan task list:**

- `Read` the failing tests and `spec.md`
- `Glob` and `Read` existing domain/feature structure to determine dependencies

Use `AskUserQuestion` for architectural choices before committing:
- "Should this use an existing infrastructure adapter or a new one?"

Non-interactive: reuse any existing adapter whose interface already matches the requirement; if none, create a minimal new adapter. Log `[AUTO-DECIDED] implementing/Step1: {decision}` to `## Open Questions`.

Write task list to plan file:

```
Task N: {verb} {object}
  Files: {exact paths}
  Layer: domain|infrastructure|small-feature|large-feature
  Depends on: Task M (omit if none)
  Parallel: yes/no
```

Layer order: domain tasks first, then features, then infrastructure. Mark tasks that can run in parallel within the same layer tier (no cross-task dependency within the tier).

In **interactive mode**: call `ExitPlanMode` to present the task list and request approval before proceeding.

Non-interactive: @reference/non-interactive-mode.md §ExitPlanMode replacement — skip `ExitPlanMode`; proceed directly to Step 2.

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

Advance to `implement` phase so that coder subagents (running in isolated git worktrees)
see a phase that permits `src/` writes. This must be committed before spawning coders —
worktrees inherit the committed plan file state:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" advance-phase "plans/{slug}.md" implement \
  "task list registered — advancing to implement" \
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
           Read-only paths (test files): [test file path(s)]    ← omit for trivial profile
           Failing test: [test code]                            ← omit for trivial profile
           Test command: [command from project CLAUDE.md]
           Spec: [spec path]                                    ← omit for trivial profile
           CLAUDE_PLAN_FILE: [absolute path to plans/{slug}.md]
           [Trivial profile only: no failing test — make the minimal edit described in Task above; test command must still pass]"
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
     [BLOCKED-CODER] task-N aborted without commit — {reason from coder output}
     ```
   - **Interactive**: use `AskUserQuestion` — "Coder task-N aborted: {reason}. How should we proceed?"
   - **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): stop the current tier; do not attempt remaining tasks in this tier.

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
3. Resolve conflicts manually (or re-run the coder with explicit conflict context), then re-attempt the merge.
   **In non-interactive mode** (`CLAUDE_NONINTERACTIVE=1`): do not attempt resolution. Append `[BLOCKED-CODER] task-N merge conflict — resolve conflict in {worktree-branch} then re-run implementing` to `## Open Questions` and stop the current tier.
4. On success, update the task to `completed` with the merge SHA.

Then mark the corresponding `TaskCreate` task `completed`. Move to the next tier.

## Step 3.5 — Post-tier smoke test

After all tasks in a tier are merged, run the unit test command from project CLAUDE.md.

If tests pass: continue to Step 4.

If tests fail:
- **Interactive**: use `AskUserQuestion` — "Post-tier merge caused test failures: [{list}]. Which task introduced the regression? I will re-spawn a fix-coder targeting the failing tests."
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): append `[BLOCKED] post-tier merge test failure — {failing test list}` to `## Open Questions` in the plan file, then stop.

## Step 4 — Run critic-code at milestones (convergence loop per milestone)

Full protocol: @reference/critics.md §Loop convergence

Track changed files during this milestone. Run after: a complete small feature, a domain concept's full rule set, or a significant chunk of a large feature.

**Before the first critic-code run of each milestone** (once per milestone, not on retry runs within the same milestone), reset the convergence state: @reference/critics.md §New milestone — critic=`critic-code`.

```
Skill("critic-code", "Review these files: [explicit list]. Spec at: [path]. Relevant docs: [paths].")
```

After each run, follow @reference/critics.md §Running the critic and @reference/critics.md §Skill branching logic, substituting `critic-code` for `{agent}`.

On `[CONVERGED] {phase}/critic-code`: proceed to next milestone or Step 4.5.

On `[DOCS CONTRADICTION]` (during implement phase): @reference/critics.md §DOCS CONTRADICTION cascade
(Skip the **During `review` phase** section — this is the implement phase.)

## Step 4.5 — Fix pre-existing errors

Check for pending errors after all tasks complete and critic-code passes:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" list-errors "plans/{slug}.md" --status pending
```

If no rows are printed, proceed to Step 5 (no action needed).

For each pending error:

**nearby scope** — group errors by file; spawn a fix-coder subagent per file group:

```
Agent(
  subagent_type: "coder",
  isolation: "worktree",
  prompt: "Fix pre-existing errors (do NOT change feature code or tests).
           Errors to fix: [{err-id} {file}:{line} — {description}] ...
           Test command: [command from project CLAUDE.md]
           Commit format: fix(pre-existing): {description}
           CLAUDE_PLAN_FILE: [absolute path to plans/{slug}.md]"
)
```

On success: merge the worktree branch, then mark each fixed error:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-error "plans/{slug}.md" "{err-id}" "fixed"
```

If tests break after the fix — do NOT commit; mark deferred instead:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-error "plans/{slug}.md" "{err-id}" "deferred"
```

**distant scope** — do not attempt to fix; mark deferred and record in Open Questions:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-error "plans/{slug}.md" "{err-id}" "deferred"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-note "plans/{slug}.md" \
  "[DEFERRED-ERROR] {err-id} {file}:{line} — {description} (distant scope, fix separately)"
```

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

**Fix chains on FAIL** — on first FAIL from `implement`, transition to `review` (bash below) before fixing; remain in `review` for all subsequent FAILs.

```bash
# On first FAIL (from implement phase):
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" review \
  "first pr-review FAIL"
```

On FAIL, categorise and fix:

**Categorisation** — interactive: `AskUserQuestion`; non-interactive: infer from evidence. If ambiguous, append `[BLOCKED-AMBIGUOUS] pr-review: {question}` and stop.

### Code-only

Issues: naming, duplication, complexity, style, silent failures.

→ Fix code → run tests → apply §Fix-chain finisher (steps 1 and 3; step 2 not needed — already in `review`)

### Spec gap

Issue: unhandled scenario revealed by review.

→ Add scenario to `spec.md` → re-run `Skill("critic-spec")`
→ Apply @reference/critics.md §Phase Rollback Procedure: target-phase=`red`, critic=`critic-test`
→ Write failing test → re-run `Skill("critic-test")`
→ Advance to `implement`:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" advance-phase "plans/{slug}.md" implement \
  "spec gap test written — implementing fix" \
  "chore(phase): advance to implement — spec gap fix"
```
→ Implement → apply §Fix-chain finisher (all 3 steps)

### Docs conflict

Issue: implementation contradicts domain rules.

→ @reference/critics.md §DOCS CONTRADICTION cascade (apply all steps including the **During `review` phase** section)

Set plan file phase to `green` when `[CONVERGED] {phase}/pr-review` is confirmed. Do not set `green` earlier — the `implement` and `review` phases keep the session in the implementation+fix loop; `green` signals that all pr-review checks have passed:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" green \
  "pr-review converged — all checks passed"
```

> Do **not** set `done` here — `find-active` drops `done` plans, blocking subsequent features in a multi-feature slice. `done` is set by `running-integration-tests` or `running-dev-cycle`.

## Fix-chain finisher (pr-review FAIL)

Common ending for Code-only and Spec-gap fix chains in §Step 5.

1. **(If code changed)** Reset critic-code milestone and re-run:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-code
   ```
   → `Skill("critic-code")` (follow §Skill branching logic until `[CONVERGED]`)

2. **(If not already in `review` phase)** Restore to `review`:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" review \
     "{fix description} — resuming pr-review"
   ```

3. Re-run `Skill("pr-review-toolkit:review-pr")` → call `append-review-verdict`

## Session Recovery

On entry, determine the appropriate abstract action by reconciling the Task Ledger with the current phase.

**Ledger reconciliation**: Run `TaskList`. For any `in_progress` task that has a `commit-sha` recorded in the Task Ledger, mark it `completed` before branching.

**Phase + ledger → abstract action**:

| Phase | Ledger state | Abstract action |
|---|---|---|
| expected / empty | — | `fresh-start` |
| expected / incomplete | has pending | `resume-from-execution` |
| expected / all-complete | — | `skip-to-post-execution` |
| later-expected / all-complete | — | `skip-to-post-implementation` |
| later-phase / incomplete | unexpected | `rollback-then-resume` |
| any | has `blocked` task | `unblock-and-rerun` |

**ExitPlanMode pattern**:
- Interactive: call `ExitPlanMode` with a brief explanation of the recovery action.
- Non-interactive (`CLAUDE_NONINTERACTIVE=1`): skip `ExitPlanMode` and proceed to the next step. Full spec: @reference/non-interactive-mode.md §ExitPlanMode replacement.

**Blocked task unblock recipe**: resolve the external blocker, then run:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-task "plans/{slug}.md" "task-N" "pending"
```
Then re-invoke the skill from scratch.

Abstract action → concrete execution point for this skill:

| Abstract action | Implementing execution point |
|---|---|
| `fresh-start` (trivial profile) | Define single task → Step 2 → Step 3 |
| `resume-from-execution` | Step 3 |
| `skip-to-post-execution` | Step 4 (critic-code milestone) |
| `skip-to-post-implementation` | Step 5 (pr-review) |
| `rollback-then-resume` (review→implement) | `transition implement` then Step 3 |
| `unblock-and-rerun` | `update-task ... pending` then re-invoke `implementing` |

For `fresh-start` (trivial profile): define one task and proceed to Step 2 then Step 3:
```
Task 1: apply trivial change
  Files: {target file path}
  Layer: {domain|infrastructure|small-feature — infer from the path}
  Depends on: none
  Parallel: no
```
