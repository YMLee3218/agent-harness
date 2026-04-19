---
name: running-dev-cycle
description: >
  Run full dev cycle: brainstorming → writing-spec → writing-tests → implementing in order.
  Invoke only via `/running-dev-cycle` slash command.
  Feature-slice mode by default; use --batch flag to write all specs before any tests.
disable-model-invocation: true
argument-hint: "[--profile feature|greenfield] [--batch]"
---

# Development Cycle

User-invocable only via `/running-dev-cycle`.

Run each skill in order. Do not skip or reorder steps. Wait for each step to fully complete — including critic PASS — before invoking the next.

> **Multi-feature parallel work**: if multiple features will run concurrently on the same repository, start each in its own git worktree (`git worktree add .worktrees/feature-x feature/x`) or set `CLAUDE_PLAN_FILE` to the feature's plan path. Running two features on the same branch without disambiguation causes `find-active` to fall back to the newest plan, which may be wrong.

## Autonomous preflight

Requirements reference: `scripts/preflight.sh` (tool and file list in header comment).

The `SessionStart` hook (`scripts/preflight.sh`) has already verified prerequisites before this skill runs. Inspect `## Open Questions` for any `[BLOCKED] preflight:` markers before continuing — their presence means a required tool or file is missing and the run must be aborted.

---

## Step 0 — Phase-aware resume

On every invocation, locate the active plan file before running any skill:

```bash
plan_file=$(bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" find-active)
find_active_rc=$?
```

Exit codes: 0=found 2=none 3=ambiguous 4=malformed 1=error.

| Exit code | Action |
|-----------|--------|
| 0 | Read phase; route per table below |
| 2 | No active plan — fall through to Step 1 |
| 3 | Stop: `[BLOCKED] Multiple active plan files found — set CLAUDE_PLAN_FILE=plans/{slug}.md then re-run` |
| 4 | Stop: `[BLOCKED] Plan file phase is unreadable — check ## Phase section in plan file` |
| 1 | Unexpected error — warn and fall through to Step 1 |

Otherwise, if a plan file is found (`find_active_rc=0`), read its current phase:

If `[BLOCKED] final: critic-feature` is present in `## Open Questions`: stop per @reference/critics.md §Brainstorm exception (report marker verbatim, do not auto-retry).

If any `[BLOCKED]` or `[BLOCKED-CEILING]` marker is present: stop and report the marker to the user — do not auto-retry.

Route accordingly:

| Phase in plan file | Action |
|--------------------|--------|
| _(no plan file / exit 2)_ | Fall through to Step 1 (brainstorming) as normal |
| `brainstorm` | Fall through to Step 1; brainstorming will resume from the existing plan |
| `spec` | Skip to **Step 2a** (writing-spec for the next un-specced feature) |
| `red` | **Slice mode** (feature profile): Skip to **Step 2c** (implementing). Tests already written. **Batch mode** (greenfield / --batch): Resume from **Step 3** — read `## Test Manifest` in the plan file to find the first feature that does NOT yet have a `RED` or `GREEN (pre-existing)` entry; invoke `writing-tests` for that feature and continue through the remainder of the feature list. If every feature already has a Test Manifest entry, skip directly to **Step 4** (Implementation). |
| `implement` | Coder task execution: normal mid-run state (set by `implementing` after task list registration). Re-invoke the `implementing` skill — it handles both sub-cases via Task Ledger state. |
| `review` | PR review loop was interrupted mid-fix. Re-invoke the `implementing` skill to resume the pr-review fix loop for the current feature. |
| `green` | PR review converged; implementation done. Skip directly to **Integration Tests** (all profiles). |
| `integration` | Skip to **Integration Tests** step (re-run after previous failure) |
| `done` | Excluded by `find-active` (exit 2) — falls through to Step 1 as if no plan exists. To restart, delete the plan file or create a new feature branch. |

Do not re-run a phase that the plan file records as already completed. This ensures
autonomous restarts after interruption (crash, compaction, network error) resume at
the correct point rather than repeating finished work.

---

## Profile selection

Choose the profile that matches the scope of the change.

| Profile | Flag | Phases active | Critics active | When to use |
|---------|------|--------------|----------------|-------------|
| **feature** | `--profile feature` *(default)* | full cycle | all four critics | New feature or behaviour change |
| **greenfield** | `--profile greenfield` | full cycle + batch mode | all four critics | New project or major domain rewrite where all specs must align before any tests |

Set `mode: {profile}` in the plan file frontmatter to track the active profile.

---

## Step 1 — Brainstorming

Invoke the `brainstorming` skill.

Do not proceed to Step 2 until:
- `docs/requirements/{name}.md` is created
- Feature branch `feature/{name}` is created
- critic-feature returns PASS (or user has approved manual override)
- Plan file `plans/{slug}.md` exists with Phase `brainstorm`

After brainstorming returns, record the active profile in the plan file frontmatter so that resumed sessions can determine the profile without the original command-line argument. Use `Edit` to insert `mode: {profile}` into the YAML frontmatter block of `plans/{slug}.md` (between the `---` delimiters). Where `{profile}` is the resolved profile name (`feature` or `greenfield`).

---

## Feature-slice mode (`feature` profile, default)

Read `docs/requirements/{name}.md` to get the full feature list (Small Features + Large Features sections).

**Before iterating, determine which features are already done.** A feature is considered complete when ALL of the following hold:
- `features/{verb}-{noun}/spec.md` exists (spec was written), AND
- `## Critic Verdicts` in the plan file contains a `PASS` line from `critic-spec` recorded after that spec was written, AND
- All tasks for that feature in `## Task Ledger` are `completed`.

Skip features that satisfy all three conditions. Start from the first feature that does NOT satisfy them.

**For each remaining feature in the list, in dependency order:**

### Step 2a — Spec

Invoke the `writing-spec` skill for the feature. Wait for critic-spec PASS.

### Step 2b — Tests

Invoke the `writing-tests` skill for the feature. Wait for critic-test PASS and Plan file Phase `red`.

### Step 2c — Implementation

Invoke the `implementing` skill for the feature. Wait until the feature's tasks are `completed`.

Then move to the next feature. Repeat until all features are done.

---

## Batch mode (`greenfield` profile, or explicit `--batch`)

### Step 2 — Spec (all features)

Read `docs/requirements/{name}.md` to get the full feature list.

For each feature:
1. Invoke the `writing-spec` skill for that feature
2. Wait for critic-spec PASS before moving to the next feature

Do not proceed to Step 3 until all features have a PASS-verified spec.md.

### Step 3 — Tests (all features)

Read `docs/requirements/{name}.md` to get the full feature list.

For each feature, in the same order as Step 2:
1. Invoke the `writing-tests` skill for that feature
2. Wait for the skill to complete (tests written and failing, critic-test PASS, Plan file Phase `red`)

Do not proceed to Step 4 until every feature has completed Step 3.

### Step 4 — Implementation

Invoke the `implementing` skill.

---

## Integration Tests

After all features have completed `implementing` (i.e., all feature-slice iterations or the single batch implementation are done):

1. Read project CLAUDE.md for the integration test command.
2. If a command is defined: invoke `running-integration-tests` skill.
   `running-integration-tests` sets the plan phase to `integration` then `done`.
3. If no integration test command is defined in project CLAUDE.md:
   log `[SKIP] integration tests — no command found in CLAUDE.md`, then set phase `done`:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" done \
     "no integration test command — skipped"
   ```

---

## Completion criteria

Cycle is complete when:
- All tasks are `completed`
- Plan file Phase is `done`
- No unresolved critic or pr-review-toolkit issues
- Integration tests passed (or skipped with logged reason)
