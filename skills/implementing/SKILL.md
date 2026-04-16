---
name: implementing
description: >
  Implement Green phase (make failing tests pass, then refactor in-place within Green).
  Trigger: "implement", "make the tests pass", "Green phase", "go", "proceed", after critic-test returns PASS.
  Do NOT trigger when no spec or tests exist — route to brainstorming instead.
  Plans implementation order (domain first), then executes with isolated subagents per task.
  Also drives `review` phase during pr-review fix loop (red → review → green).
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

Use `AskUserQuestion` to present the task list and request approval before proceeding.

In **non-interactive mode** (`CLAUDE_NONINTERACTIVE=1`): skip approval; proceed directly to Step 2. Run:
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

<!-- Do NOT set-phase green here. Phase stays `red` during task execution so that an
     interrupted session resumes via the `red` routing (which re-invokes implementing),
     not the `green` routing (which skips directly to integration tests). -->

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
           CLAUDE_PLAN_FILE: [absolute path to plans/{slug}.md]
           Verification policy: @reference/verification-policy.md — verify external APIs via context7 before first use."
)
```

Do not pass the full plan or other tasks' state to subagents.

Each coder runs in an isolated git worktree and commits its changes to a temporary branch. After each subagent returns, **check for abort before merging**:

1. Check for abort: look for `<!-- coder-status: abort -->` in the last line of the coder's output. If absent, fall back to scanning for abort signals: "layer violation", "forbidden import", "hard stop", "STOP", "I stopped", "aborting".
2. Check whether the coder actually committed: `git diff --name-only {base-sha}..{worktree-branch}` — if the output is empty, no commit was made.
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

```
Skill("critic-code", "Review these files: [explicit list]. Spec at: [path]. Relevant docs: [paths].")
```

After each run, `plan-file.sh record-verdict` fires automatically (SubagentStop hook). Read `## Open Questions` for `critic-code` markers in priority order:

| Marker | Action |
|--------|--------|
| `[BLOCKED-CEILING] critic-code` | Stop — manual review required |
| `[BLOCKED-CATEGORY] critic-code` | Stop — fix root cause first |
| `[BLOCKED-AMBIGUOUS] critic-code: …` | Stop — human decision needed |
| `[BLOCKED-PARSE] critic-code` | Stop — check critic output format before retrying |
| `[CONVERGED] critic-code` | Proceed to next milestone or Step 4.5 |
| `[CONFIRMED-FIRST] critic-code` | Re-run automatically (user already confirmed in a previous session) |
| `[AUTO-APPROVED-FIRST] critic-code` | Re-run automatically (FIRST-TURN auto-approved in a prior non-interactive session) |
| `[FIRST-TURN] critic-code` | Ask user (interactive) — after confirming, run `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-note "plans/{slug}.md" "[CONFIRMED-FIRST] critic-code"` then re-run; or run `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" record-auto-approved "plans/{slug}.md" FIRST critic-code` (non-interactive), then re-run |
| PARSE_ERROR (no `[BLOCKED-PARSE]` yet) | Re-run automatically (second consecutive PARSE_ERROR triggers `[BLOCKED-PARSE]`) |
| PASS, no `[CONVERGED]` yet | Re-run automatically |
| FAIL | Apply fix, then re-run |

Evaluation order: BLOCKED-CEILING → BLOCKED-CATEGORY → BLOCKED-AMBIGUOUS → BLOCKED-PARSE → CONVERGED → CONFIRMED-FIRST → AUTO-APPROVED-FIRST → FIRST-TURN → PARSE_ERROR → PASS → FAIL
_(Steps 1–8 check `## Open Questions`; steps 9–11 check the last entry in `## Critic Verdicts`)_

On `[DOCS CONTRADICTION]` (after applying fix): update `docs/*.md` first, then cascade: re-run Skill("critic-spec") if spec changed → re-run Skill("critic-test") if tests changed → run test command → re-run Skill("critic-code").

When any cascade causes a phase rollback, append to `## Phase Transitions` in the plan file:
```
- {current-phase} → {rollback-phase} (reason: {one sentence})
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
| `[BLOCKED-CEILING] pr-review` | Stop — manual review required |
| `[BLOCKED-AMBIGUOUS] pr-review: …` | Stop — human decision needed |
| `[CONVERGED] pr-review` | Set phase green and finish |
| `[CONFIRMED-FIRST] pr-review` | Re-run automatically (user already confirmed in a previous session) |
| `[AUTO-APPROVED-FIRST] pr-review` | Re-run automatically (FIRST-TURN auto-approved in a prior non-interactive session) |
| `[FIRST-TURN] pr-review` | Ask user for confirmation (interactive) — after confirming, run `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-note "plans/{slug}.md" "[CONFIRMED-FIRST] pr-review"` then re-run; or run `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" record-auto-approved "plans/{slug}.md" FIRST pr-review` (non-interactive), then re-run |
| PASS, no `[CONVERGED]` yet | Re-run automatically |
| FAIL | Apply fix chain below, then re-run |

Evaluation order: BLOCKED-CEILING → BLOCKED-AMBIGUOUS → CONVERGED → CONFIRMED-FIRST → AUTO-APPROVED-FIRST → FIRST-TURN → PASS → FAIL

**Fix chains on FAIL** — phase transition timing:

- If a FAIL occurs **and the current phase is `red`**: immediately advance to `review` before applying any fix. This allows phase-gate to permit source modifications during the fix loop.
- If a FAIL occurs **and the current phase is already `review`**: remain in `review`; do not re-transition.
- All subsequent FAILs are handled within `review` phase.
- `green` is set **only** when `[CONVERGED] pr-review` is confirmed (see below) — never on a single PASS.

```bash
# On first FAIL (from red phase only):
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" review
```

Categorise each issue (interactive: `AskUserQuestion`; non-interactive: infer from evidence):

In **non-interactive mode** (`CLAUDE_NONINTERACTIVE=1`): if category is unambiguous, apply the fix chain automatically and log `[AUTO-CATEGORIZED] pr-review: {issue summary} → {category}`. If ambiguous, append `[BLOCKED-AMBIGUOUS] pr-review: {question}` and stop.

**Code-only** (naming, duplication, complexity, style, silent failures):
→ Fix code → run tests → re-run Skill("critic-code") → re-run Skill("pr-review-toolkit:review-pr") → call `append-review-verdict`

**Spec gap** (unhandled scenario revealed by review):
→ Add scenario to `spec.md` → re-run Skill("critic-spec") → write failing test → re-run Skill("critic-test") → implement → re-run Skill("critic-code") → re-run Skill("pr-review-toolkit:review-pr") → call `append-review-verdict`

**Docs conflict** (implementation contradicts domain rules):
→ Update `docs/*.md` (SOT) → fix spec → re-run Skill("critic-spec") → fix tests → re-run Skill("critic-test") → fix code → re-run Skill("critic-code") → re-run Skill("pr-review-toolkit:review-pr") → call `append-review-verdict`

Set plan file phase only when `[CONVERGED] pr-review` is confirmed (this is the ONLY place `green` is set —
keeping phase `red` through task execution ensures interrupted sessions resume correctly):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" green
```

> `implementing` completes the Green phase. The `done` phase is set later by
> `running-integration-tests` (after integration tests pass) or by `running-dev-cycle`
> when integration tests are skipped. Do **not** set `done` here — doing so would
> cause `find-active` to drop the plan file from its search, blocking subsequent
> features in a multi-feature slice from writing to `tests/`.

## Session Recovery

Use `TaskList` to find the first `pending` or `in_progress` task and resume there. For `in_progress` tasks, check the Task Ledger in `plans/{slug}.md` — if a commit-sha is recorded the task was committed; mark it `completed` and continue. Read `plans/{slug}.md` to determine the current phase.

## Hard Stop

Never commit a failing test. Never commit implementation without a passing test.
