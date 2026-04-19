---
name: implementing
description: >
  Implement phase (drive coder subagents to make failing tests pass, then refactor in-place).
  Trigger: "implement", "make the tests pass", "implement phase", "Green phase", "go", "proceed", after critic-test returns PASS.
  Do NOT trigger when no spec or tests exist — route to brainstorming instead.
  Plans implementation order (domain first), then executes with isolated subagents per task.
  Also drives `review` phase during pr-review fix loop (implement → review → green).
effort: high
paths:
  - src/**
  - tests/**
---

# Implementation Workflow

Layer rules: @reference/layers.md
Context hygiene: @reference/context-hygiene.md

## Step 1 — Read plan file + plan implementation order

Use `EnterPlanMode`, then:

Read `plans/{slug}.md` (resume context after `/compact`). Confirm Phase is `red`, `implement`, or `review` (see §Session Recovery for `implement` and `review` entry paths).

If phase is `review` and all tasks are `completed` — skip task planning entirely; go directly to §Session Recovery.
If phase is `implement` **and the Task Ledger is non-empty** — skip task planning entirely; go directly to §Session Recovery.
If phase is `implement` **and the Task Ledger is empty** — this is a fresh `trivial`-profile entry (no spec/tests; phase was pre-advanced by `running-dev-cycle`). Skip the architectural-choice question; no task list to present.
- **Interactive**: call `ExitPlanMode` immediately (trivial change — no task list to review).
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): skip `ExitPlanMode` — run `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" record-auto-approved "plans/{slug}.md" TASKLIST implementing "trivial profile auto-approved"`.
Define a single task covering the target file before proceeding to Step 2:
```
Task 1: apply trivial change
  Files: {target file path}
  Layer: {domain|infrastructure|small-feature — infer from the path}
  Depends on: none
  Parallel: no
```
Proceed directly to Step 2 to register this one task, then Step 3.

- `Read` the failing tests and `spec.md`
- `Glob` and `Read` existing domain/feature structure to determine dependencies

Use `AskUserQuestion` for architectural choices before committing:
- "Should this use an existing infrastructure adapter or a new one?"

In **non-interactive mode** (`CLAUDE_NONINTERACTIVE=1`): skip the question; reuse any existing adapter whose interface already matches the requirement. If none exists, create a minimal new adapter. Append `[AUTO-DECIDED] implementing/Step1: {decision — e.g. "reused existing HttpAdapter"}` to `## Open Questions` in the plan file.

Write task list to plan file:

```
Task N: {verb} {object}
  Files: {exact paths}
  Layer: domain|infrastructure|small-feature|large-feature
  Depends on: Task M (omit if none)
  Parallel: yes/no
```

Layer order: domain tasks first, then features, then infrastructure. Mark tasks that can run in parallel within the same layer tier (no cross-task dependency within the tier).

Call `ExitPlanMode` to present the task list and request approval before proceeding.

In **non-interactive mode** (`CLAUDE_NONINTERACTIVE=1`): skip `ExitPlanMode`; proceed directly to Step 2. Run:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" record-auto-approved "plans/{slug}.md" TASKLIST implementing "{N tasks, layers: domain/feature/infra summary}"
```

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
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" implement
git add "plans/{slug}.md" "plans/{slug}.state.json" 2>/dev/null || git add "plans/{slug}.md"
git diff --cached --quiet || git commit -m "chore(phase): advance to implement — task list registered"
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
           Phase: implement  ← do NOT modify any test file
           Read-only paths (test files): [test file path(s)]
           Failing test: [test code]
           Test command: [command from project CLAUDE.md]
           Spec: [spec path]
           CLAUDE_PLAN_FILE: [absolute path to plans/{slug}.md]
           Verification policy: @reference/verification-policy.md — verify external APIs via context7 before first use."
)
```

Do not pass the full plan or other tasks' state to subagents.

Each coder runs in an isolated git worktree and commits its changes to a temporary branch. After each subagent returns, **check for abort before merging**:

1. Check for abort: look for `<!-- coder-status: abort -->` in the last line of the coder's output. If absent, fall back to scanning for abort signals: "layer violation", "forbidden import", "hard stop", "STOP", "I stopped", "aborting".
2. Check whether the coder actually committed: `git rev-list --count {base-sha}..{worktree-branch}` — if the output is `0`, no commit was made.
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

If no abort signals are detected, merge and record as normal:
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

Full protocol: @reference/critic-loop.md

Track changed files during this milestone. Run after: a complete small feature, a domain concept's full rule set, or a significant chunk of a large feature.

**Before starting each new milestone's critic-code run**, reset the convergence state so the 2-PASS streak restarts from scratch. `reset-milestone` clears the stale `[CONVERGED]` marker from `## Open Questions` AND appends a `[MILESTONE-BOUNDARY]` sentinel to `## Critic Verdicts` so prior-milestone PASSes do not contribute to the new streak:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-code
```

```
Skill("critic-code", "Review these files: [explicit list]. Spec at: [path]. Relevant docs: [paths].")
```

After each run, `plan-file.sh record-verdict` fires automatically (SubagentStop hook). Read `## Open Questions` for `critic-code` markers in priority order:

| Marker | Action |
|--------|--------|
| `[BLOCKED-CEILING] {phase}/critic-code` | Stop — manual review required. **Phase-match required**: `{phase}` must equal the current plan file phase. A stale marker from a prior phase (e.g., after rollback) does not apply. |
| `[BLOCKED-CATEGORY] critic-code` | Stop — fix root cause first |
| `[BLOCKED-AMBIGUOUS] critic-code: …` | Stop — human decision needed |
| `[BLOCKED-PARSE] critic-code` | Stop — check critic output format before retrying |
| `[CONVERGED] {phase}/critic-code` | Proceed to next milestone or Step 4.5. **Phase-match required**: same rule as BLOCKED-CEILING. |
| `[CONFIRMED-FIRST] {phase}/critic-code` | Re-run automatically (user already confirmed in a previous session). **Phase-match required**: same rule as BLOCKED-CEILING. |
| `[AUTO-APPROVED-FIRST] {phase}/critic-code` | Re-run automatically (FIRST-TURN auto-approved in a prior non-interactive session). **Phase-match required**: same rule as BLOCKED-CEILING. |
| `[FIRST-TURN] {phase}/critic-code` | Ask user (interactive) — after confirming, run `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" record-confirmed-first "plans/{slug}.md" critic-code` then re-run; or run `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" record-auto-approved "plans/{slug}.md" FIRST critic-code` (non-interactive), then re-run. **Phase-match required**: same rule as BLOCKED-CEILING. |
| PARSE_ERROR (no `[BLOCKED-PARSE]` yet) | Re-run automatically (second consecutive PARSE_ERROR triggers `[BLOCKED-PARSE]`) |
| PASS, no `[CONVERGED]` yet | Re-run automatically |
| FAIL | Apply fix, then re-run |

Evaluation order: BLOCKED-CEILING → BLOCKED-CATEGORY → BLOCKED-AMBIGUOUS → BLOCKED-PARSE → CONVERGED → CONFIRMED-FIRST → AUTO-APPROVED-FIRST → FIRST-TURN → PARSE_ERROR → PASS → FAIL
_(Steps 1–8 check `## Open Questions`; steps 9–11 check the last entry in `## Critic Verdicts`)_

On `[DOCS CONTRADICTION]`: update `docs/*.md` first, then cascade: re-run Skill("critic-spec") if spec changed → re-run Skill("critic-test") if tests changed → run test command → re-run Skill("critic-code").

When any cascade causes a phase rollback:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-phase-transition "plans/{slug}.md" \
  "- {current-phase} → {rollback-phase} (reason: {one sentence})"
```

## Step 4.5 — Fix pre-existing errors

After all tasks complete and critic-code passes, check for errors reported by coders:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" list-errors "plans/{slug}.md" --status pending
```

If no rows are printed, proceed to Step 5.

For each pending error:

**nearby scope** — group errors by file, then spawn a fix-coder subagent per file group:

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

If tests break after the fix: do NOT commit. Mark the error deferred instead:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-error "plans/{slug}.md" "{err-id}" "deferred"
```

**distant scope** — do not attempt to fix. Mark deferred and record in Open Questions:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-error "plans/{slug}.md" "{err-id}" "deferred"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-note "plans/{slug}.md" \
  "[DEFERRED-ERROR] {err-id} {file}:{line} — {description} (distant scope, fix separately)"
```

## Step 5 — Run pr-review-toolkit

After all tasks complete, ensure a PR exists:

```bash
gh pr view 2>/dev/null || gh pr create --draft --title "feat: {feature name}" --body "Closes #{issue}"
```

Then run the review loop (convergence policy: @reference/critic-loop.md §Loop convergence):

```
Skill("pr-review-toolkit:review-pr")
```

After each run, record the verdict (PASS or FAIL based on whether the review reported issues):

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-review-verdict \
  "plans/{slug}.md" "pr-review" PASS|FAIL
```

Read `## Open Questions` for `pr-review` markers, in priority order:

<!-- Note: this marker table is intentionally shorter than the critic marker table —
     [BLOCKED-CATEGORY] and [BLOCKED-PARSE] are absent by design (pr-review asymmetry).
     See reference/critic-loop.md §pr-review asymmetry for the rationale. -->

| Marker | Action |
|--------|--------|
| `[BLOCKED-CEILING] {phase}/pr-review` | Stop — manual review required. **Phase-match required**: `{phase}` must equal the current plan file phase. |
| `[BLOCKED-AMBIGUOUS] pr-review: …` | Stop — human decision needed |
| `[CONVERGED] {phase}/pr-review` | Set phase green and finish. **Phase-match required**: same rule as BLOCKED-CEILING. |
| `[CONFIRMED-FIRST] {phase}/pr-review` | Re-run automatically (user already confirmed in a previous session). **Phase-match required**: same rule as BLOCKED-CEILING. |
| `[AUTO-APPROVED-FIRST] {phase}/pr-review` | Re-run automatically (FIRST-TURN auto-approved in a prior non-interactive session). **Phase-match required**: same rule as BLOCKED-CEILING. |
| `[FIRST-TURN] {phase}/pr-review` | Ask user for confirmation (interactive) — after confirming, run `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" record-confirmed-first "plans/{slug}.md" pr-review` then re-run; or run `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" record-auto-approved "plans/{slug}.md" FIRST pr-review` (non-interactive), then re-run. **Phase-match required**: same rule as BLOCKED-CEILING. |
| PASS, no `[CONVERGED]` yet | Re-run automatically |
| FAIL | Apply fix chain below, then re-run |

Evaluation order: BLOCKED-CEILING → BLOCKED-AMBIGUOUS → CONVERGED → CONFIRMED-FIRST → AUTO-APPROVED-FIRST → FIRST-TURN → PASS → FAIL

**Fix chains on FAIL** — phase transition timing:

- If a FAIL occurs **and the current phase is `implement`**: immediately advance to `review` before applying any fix. This is the normal post-implementation path: tests pass (coder phase complete), now fixing review issues in source only.
- If a FAIL occurs **and the current phase is already `review`**: remain in `review`; do not re-transition.
- All subsequent FAILs are handled within `review` phase.
- `green` is set only when `[CONVERGED] {phase}/pr-review` is confirmed (see below) — never on a single PASS.

```bash
# On first FAIL (from implement phase):
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" review
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-phase-transition "plans/{slug}.md" \
  "- implement → review (reason: first pr-review FAIL)"
```

Categorise each issue (interactive: `AskUserQuestion`; non-interactive: infer from evidence):

In **non-interactive mode** (`CLAUDE_NONINTERACTIVE=1`): if category is unambiguous, apply the fix chain automatically and log `[AUTO-CATEGORIZED] pr-review: {issue summary} → {category}`. If ambiguous, append `[BLOCKED-AMBIGUOUS] pr-review: {question}` and stop.

**Code-only** (naming, duplication, complexity, style, silent failures):
→ Fix code → run tests → re-run Skill("critic-code") → re-run Skill("pr-review-toolkit:review-pr") → call `append-review-verdict`

**Spec gap** (unhandled scenario revealed by review):
→ Add scenario to `spec.md` → re-run Skill("critic-spec")
→ Roll phase back to `red` to allow writing test files:
  ```bash
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" red
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-phase-transition "plans/{slug}.md" \
    "- review → red (reason: spec gap — writing failing test for unhandled scenario)"
  ```
→ Write failing test → re-run Skill("critic-test")
→ Advance to `implement` phase to allow src/ writes, and commit so coder worktrees inherit the phase:
  ```bash
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" implement
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-phase-transition "plans/{slug}.md" \
    "- red → implement (reason: spec gap test written — implementing fix)"
  git add "plans/{slug}.md" "plans/{slug}.state.json" 2>/dev/null || git add "plans/{slug}.md"
  git diff --cached --quiet || git commit -m "chore(phase): advance to implement — spec gap fix"
  ```
→ Implement → re-run Skill("critic-code")
→ Restore phase to `review` before re-running pr-review:
  ```bash
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" review
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-phase-transition "plans/{slug}.md" \
    "- implement → review (reason: spec gap fixed — resuming pr-review)"
  ```
→ re-run Skill("pr-review-toolkit:review-pr") → call `append-review-verdict`

**Docs conflict** (implementation contradicts domain rules):
→ Update `docs/*.md` (SOT) → fix spec → re-run Skill("critic-spec")
→ Roll phase back to `red` to allow editing test files (test files are frozen in `review`):
  ```bash
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" red
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-phase-transition "plans/{slug}.md" \
    "- review → red (reason: docs conflict — updating test files to match corrected spec)"
  ```
→ Fix tests → re-run Skill("critic-test")
→ Advance to `implement` phase to allow src/ writes, and commit so coder worktrees inherit the phase:
  ```bash
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" implement
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-phase-transition "plans/{slug}.md" \
    "- red → implement (reason: docs conflict test updated — implementing fix)"
  git add "plans/{slug}.md" "plans/{slug}.state.json" 2>/dev/null || git add "plans/{slug}.md"
  git diff --cached --quiet || git commit -m "chore(phase): advance to implement — docs conflict fix"
  ```
→ Fix code → re-run Skill("critic-code")
→ Restore phase to `review` before re-running pr-review:
  ```bash
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" review
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-phase-transition "plans/{slug}.md" \
    "- implement → review (reason: docs conflict fixed — resuming pr-review)"
  ```
→ re-run Skill("pr-review-toolkit:review-pr") → call `append-review-verdict`

Set plan file phase to `green` when `[CONVERGED] {phase}/pr-review` is confirmed. Do not set `green` earlier — the `implement` and `review` phases keep the session in the implementation+fix loop; `green` signals that all pr-review checks have passed:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" green
```

> `implementing` completes the implement phase (and review phase if pr-review fails). The `done` phase is set later by
> `running-integration-tests` (after integration tests pass) or by `running-dev-cycle`
> when integration tests are skipped. Do **not** set `done` here — doing so would
> cause `find-active` to drop the plan file from its search, blocking subsequent
> features in a multi-feature slice from writing to `tests/`.

## Session Recovery

Use `TaskList` to find the first `pending` or `in_progress` task and resume there. For `in_progress` tasks, check the Task Ledger in `plans/{slug}.md` — if a commit-sha is recorded the task was committed; mark it `completed` and continue. Read `plans/{slug}.md` to determine the current phase.

If the phase is `implement` and the Task Ledger is **empty** (`trivial` profile — no tasks were registered before interruption):
- This is a fresh start, not a mid-run recovery.
- **Interactive**: call `ExitPlanMode` (trivial change — no task list to review; proceeding to Step 2).
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): skip `ExitPlanMode` — run `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" record-auto-approved "plans/{slug}.md" TASKLIST implementing "trivial profile auto-approved"`.
- Do NOT re-plan architectural questions — trivial changes have no task list overhead.
- Proceed to **Step 2** (task registration) then **Step 3** directly.

If the phase is `implement` and tasks are incomplete:
- **Interactive**: call `ExitPlanMode` (no task list to re-approve — informing user: resuming implement phase from Task Ledger), then resume from **Step 3**.
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): skip `ExitPlanMode`; resume from **Step 3** directly.
No need to re-plan or re-ask architectural questions — the Task Ledger already has the plan.

If the phase is `implement` and all tasks are `completed` (coder subagents finished but critic-code milestone run was interrupted):
- **Interactive**: call `ExitPlanMode` (informing user: resuming critic-code milestone run), then skip to **Step 4**.
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): skip `ExitPlanMode`; proceed directly to **Step 4**.

If a `blocked` task exists (e.g., from a `[BLOCKED-CODER]` merge conflict): after the conflict is resolved externally, run `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" update-task "plans/{slug}.md" "task-N" "pending"` to unblock it, then re-run `implementing`.

If phase is `review` and all tasks are `completed` (prior session interrupted during pr-review fix loop):
- **Interactive**: call `ExitPlanMode` (no task list to approve — informing user: resuming pr-review fix loop), then skip to **Step 5**.
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): skip `ExitPlanMode`; proceed directly to **Step 5**.

## Hard Stop

Never commit a failing test. Never commit implementation without a passing test.
