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

If any `[BLOCKED]`, `[BLOCKED-CEILING]`, or `[BLOCKED-AMBIGUOUS]` marker is present: stop and report the marker to the user — do not auto-retry.

Route accordingly:

| Phase in plan file | Action |
|--------------------|--------|
| _(no plan file / exit 2)_ | Fall through to Step 1 (brainstorming) as normal |
| `brainstorm` (and `[CONVERGED] brainstorm/critic-feature` present) | Skip to **Step 2a** — brainstorming already converged; phase transition is pending |
| `brainstorm` (no `[CONVERGED]` marker) | Fall through to Step 1 — brainstorming resumes; after returning, critic-feature loop runs |
| `spec` (spec.md does not exist) | Read `mode` from plan file frontmatter. **Feature mode** (`mode: feature`): invoke full Step 2a (writing-spec + critic-spec loop + commit). **Batch mode** (`mode: greenfield` or `--batch`): continue writing specs for remaining un-specced features in batch order before any tests. |
| `spec` (no `[CONVERGED] spec/critic-spec`, spec.md exists) | Skip writing-spec; go directly to critic-spec loop in Step 2a |
| `spec` (spec.md exists, `[CONVERGED] spec/critic-spec` present) | **Feature mode**: skip to **Step 2b** (writing-tests; spec already reviewed and committed). **Batch mode**: proceed to **Step 3** (tests for all features). |
| `red` (no `[CONVERGED] red/critic-test`, Test Manifest non-empty) | Skip writing-tests; go directly to critic-test loop in Step 2b |
| `red` | **Slice mode** (feature profile): If `[CONVERGED] red/critic-test` is present in `## Open Questions` → skip to **Step 2c** (implementing). Otherwise (Test Manifest empty) → invoke `writing-tests` (it handles `red` phase re-entry). **Batch mode** (greenfield / --batch): Resume from **Step 3** — read `## Test Manifest` in the plan file to find the first feature that does NOT yet have a `RED` or `GREEN (pre-existing)` entry; invoke `writing-tests` for that feature and continue through the remainder of the feature list. If every feature already has a Test Manifest entry, skip directly to **Step 4** (Implementation). |
| `implement` (tasks pending) | Re-invoke the `implementing` skill. |
| `implement` (all tasks complete) | Skip to Step 2c post-implementation (critic-code → pr-review). |
| `review` | PR review interrupted mid-fix — resume pr-review from Step 2c. Apply `@reference/pr-review-loop.md`. |
| `green` | Read feature list from `docs/requirements/{name}.md`; apply **§Skip done features** check (§Feature-slice mode). If any feature undone → resume at **Step 2a** for first undone feature. If all features done → skip directly to **Integration Tests**. |
| `integration` | Skip to **Integration Tests** step (re-run after previous failure) |
| `done` | Excluded by `find-active` (exit 2) — falls through to Step 1 as if no plan exists. To restart, delete the plan file or create a new feature branch. |

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

Do not proceed until:
- `docs/requirements/{name}.md` is created
- Feature branch `feature/{name}` is created
- Plan file `plans/{slug}.md` exists with Phase `brainstorm`

After brainstorming returns, insert `mode: {profile}` (`feature` or `greenfield`) into the YAML frontmatter of `plans/{slug}.md`. Then reset and run critic-feature:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-feature
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-feature --phase brainstorm --plan "plans/{slug}.md" --prompt "Review docs/requirements/{name}.md. Original requirement: [paste requirement]."
```
exit 0 → proceed to Step 2. exit 1 → `[BLOCKED]` written to plan — stop and report. exit 2 → `[BLOCKED-CEILING]` — manual review required.

---

## Feature-slice mode (`feature` profile, default)

Read `docs/requirements/{name}.md` to get the full feature list (Small Features + Large Features sections).

**Skip done features.** Done = spec.md exists + critic-spec, critic-test, and critic-code each have `PASS` in `## Critic Verdicts` + all Task Ledger tasks `completed`. Start from the first undone feature.

**For each remaining feature in the list, in dependency order:**

### Step 2a — Spec

Invoke the `writing-spec` skill for the feature.
Wait until: spec.md is written and plan file phase is `spec`.

Reset the critic-spec milestone (clears stale `[CONVERGED] spec/critic-spec` from a prior feature's run):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-spec
```

`bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-spec --phase spec --plan "plans/{slug}.md" --prompt "Review spec at [path]. Relevant docs: [paths]."` — exit 0 → proceed; exit 1 → `[BLOCKED]` written to plan — stop and report; exit 2 → `[BLOCKED-CEILING]` — manual review required.

After `[CONVERGED] spec/critic-spec` is confirmed, commit the spec file:
```bash
git add features/{verb}-{noun}/spec.md   # or domain/{concept}/spec.md
git commit -m "feat(spec): add BDD scenarios for {name}"
```

### Step 2b — Tests

Invoke the `writing-tests` skill for the feature.
Wait until: tests are written and committed, plan file phase is `red`.
Reset critic-test milestone (clears stale `[CONVERGED] red/critic-test` from a prior feature's run): `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-test`
`bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-test --phase red --plan "plans/{slug}.md" --prompt "Review tests at [paths] against spec at [path]. Test command: [command]."` — exit 0 → proceed; exit 1 → `[BLOCKED]` written to plan — stop and report; exit 2 → `[BLOCKED-CEILING]` — manual review required.

Do not proceed to Step 2c until `[CONVERGED] red/critic-test` is present.

### Step 2c — Implementation

Invoke the `implementing` skill for the feature. Wait until the feature's tasks are `completed`.

Then run critic-code:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-code
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-code --phase implement --plan "plans/{slug}.md" --prompt "Review changed files. Spec: features/{name}/spec.md. Docs: [paths]."
```
exit 0 → proceed to pr-review. exit 1 → `[BLOCKED]` written to plan — stop and report. exit 2 → `[BLOCKED-CEILING]` — manual review required.

After `[CONVERGED] implement/critic-code`, run pr-review: `plan-file.sh reset-pr-review` → `gh pr view 2>/dev/null || gh pr create --draft --title "feat: {name}"` → `Skill("pr-review-toolkit:review-pr")` → `append-review-verdict` → `@reference/ultrathink.md §Ultrathink verdict audit` → branch per `@reference/critics.md §pr-review asymmetry` → on FAIL: `@reference/pr-review-loop.md` → transition `green` on `[CONVERGED]`.

Then move to the next feature. Repeat until all features are done.

---

## Batch mode (`greenfield` profile, or explicit `--batch`)

### Step 2 — Spec (all features)

Read `docs/requirements/{name}.md` to get the full feature list.

For each feature:
1. Invoke the `writing-spec` skill for that feature
2. Wait until spec.md is written and plan file phase is `spec`
3. Reset the critic-spec milestone: `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-spec`
4. `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-spec --phase spec --plan "plans/{slug}.md" --prompt "Review spec at [path]. Relevant docs: [paths]."` — exit 0 → proceed; exit 1 → `[BLOCKED]` written to plan — stop and report; exit 2 → `[BLOCKED-CEILING]` — manual review required.
5. After `[CONVERGED] spec/critic-spec` is confirmed, commit: `git add features/{verb}-{noun}/spec.md && git commit -m "feat(spec): add BDD scenarios for {name}"`

Do not proceed to Step 3 until all features have a committed, PASS-verified spec.md.

### Step 3 — Tests (all features)

Read `docs/requirements/{name}.md` to get the full feature list.

For each feature, in the same order as Step 2:
1. Invoke the `writing-tests` skill for that feature
2. Wait until tests are written and committed, plan file phase is `red`; reset critic-test milestone: `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-test`
3. `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-test --phase red --plan "plans/{slug}.md" --prompt "Review tests at [paths] against spec at [path]. Test command: [command]."` — exit 0 → proceed; exit 1 → `[BLOCKED]` written to plan — stop and report; exit 2 → `[BLOCKED-CEILING]` — manual review required.
4. Do not move to the next feature until `[CONVERGED] red/critic-test` is present

Do not proceed to Step 4 until every feature has completed Step 3.

### Step 4 — Implementation

Invoke the `implementing` skill. After tasks complete, run critic-code and pr-review per **Step 2c** post-implementation procedure above.

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


