---
name: running-dev-cycle
description: >
  Run full dev cycle: brainstorming → writing-spec → writing-tests → implementing in order.
  Invoke only via `/running-dev-cycle` slash command.
  Feature-slice mode by default; use --batch flag to write all specs before any tests.
disable-model-invocation: true
---

# Development Cycle

User-invocable only via `/running-dev-cycle`.

Run each skill in order. Do not skip or reorder steps. Wait for each step to fully complete — including critic PASS and user approval — before invoking the next.

> **Multi-feature parallel work**: if multiple features will run concurrently on the same repository, start each in its own git worktree (`git worktree add .worktrees/feature-x feature/x`) or set `CLAUDE_PLAN_FILE` to the feature's plan path. Running two features on the same branch without disambiguation causes `find-active` to fall back to the newest plan, which may be wrong.

## Profile selection

Choose the profile that matches the scope of the change. Profiles control which phases and critics run.

| Profile | Flag | Phases active | Critics active | When to use |
|---------|------|--------------|----------------|-------------|
| **trivial** | `--profile trivial` or `--trivial` | implementing only | critic-code, pr-review-toolkit | Single-file typo/comment fix that cannot affect behaviour |
| **patch** | `--profile patch` | spec + implementing | critic-spec, critic-code, pr-review-toolkit | Bug fix or small change with a clear, bounded scope |
| **feature** | `--profile feature` *(default)* | full cycle | all four critics | New feature or behaviour change |
| **greenfield** | `--profile greenfield` | full cycle + batch mode | all four critics | New project or major domain rewrite where all specs must align before any tests |

> Use the simplest profile that is safe for the change. When in doubt, use `feature`. Never use `trivial` or `patch` for changes that add, remove, or alter conditional logic.

**Batch mode** — writes all specs first, then all tests, then implements everything. Enabled automatically by `--profile greenfield`, or explicitly via `--batch` on any profile. Use only when the user explicitly requests it.

Set `mode: {profile}` in the plan file frontmatter to track the active profile.

---

## Step 1 — Brainstorming (`feature` and `greenfield` profiles only)

Invoke the `brainstorming` skill.

Do not proceed to Step 2 until:
- `docs/requirements/{name}.md` is created
- Feature branch `feature/{name}` is created
- critic-feature returns PASS (or user has approved manual override)
- Plan file `plans/{slug}.md` exists with Phase `brainstorm`

*Skip Step 1 for `trivial` and `patch` profiles. Create the plan file manually with Phase `brainstorm` and proceed.*

---

## Feature-slice mode (`feature` profile, default)

Read `docs/requirements/{name}.md` to get the full feature list (Small Features + Large Features sections).

**For each feature in the list, in dependency order:**

### Step 2a — Spec (`feature` and `patch` profiles)

Invoke the `writing-spec` skill for the feature. Wait for critic-spec PASS.

*Skip for `trivial` profile.*

### Step 2b — Tests (`feature` profile only)

Invoke the `writing-tests` skill for the feature. Wait for critic-test PASS and Plan file Phase `red`.

*Skip for `trivial` and `patch` profiles. Set Phase to `green` directly and proceed to implementing.*

### Step 2c — Implementation (all profiles)

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

Invoke the `writing-tests` skill.

Do not proceed to Step 4 until:
- All failing tests are written (one per Scenario across all specs)
- critic-test returns PASS
- Plan file Phase is `red`

### Step 4 — Implementation

Invoke the `implementing` skill.

---

## Completion criteria

Cycle is complete when:
- All tasks are `completed`
- Plan file Phase is `done`
- No unresolved critic or pr-review-toolkit issues
