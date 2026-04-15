---
name: writing-spec
description: >
  Write BDD spec.md (Given/When/Then scenarios) for features and domain concepts.
  Trigger: "write the spec", "define scenarios", "document the behaviour", after brainstorming is approved.
  References only docs/*.md and brainstorming output — never reads src/.
effort: medium
paths:
  - src/**
  - docs/**
  - plans/**
---

# BDD Spec Writing

Scenario templates: @reference/bdd-template.md
Layer rules: @reference/layers.md

## Step 1 — Read plan file + sources

Read `plans/{slug}.md` (resume context after `/compact`). Confirm Phase is `brainstorm` or `spec`.
If Phase is neither, apply the **## Phase rollback** procedure at the bottom of this skill before proceeding.

Use `EnterPlanMode`, then read only:
1. `docs/requirements/*.md` — brainstorming output
2. `docs/*.md` — domain knowledge

Do not `Read` or `Glob` anything in `src/`.

If `docs/*.md` appears stale or contradictory to the requirement, use `AskUserQuestion`:
- "docs/{file}.md still says X, but the requirement implies Y. Should docs be updated first?"

If docs need updating, stop. Re-invoke after `docs/*.md` is updated.

In **non-interactive mode** (`CLAUDE_NONINTERACTIVE=1`): skip the question; append `[WARN] writing-spec: docs/{file}.md may contradict the requirement — continuing; critic-spec will flag [DOCS CONTRADICTION] if the spec needs updating` to `## Open Questions`. Continue writing the spec.

## Step 2 — Draft scenarios

Write the full scenario structure to the plan file. Cover for every scenario:
- Fails / partially succeeds / times out / external system down?
- Same request while processing? Prior step incomplete?
- Events out of order? Duplicate events?

Every `Scenario Outline` Examples table must include boundaries for the input type:
- **Numeric**: zero (`0`), negative one (`-1`), maximum
- **Collection**: empty (`[]`)
- **String**: empty (`""`), max-length
- **Nullable**: `null` / absent
- **Boolean**: `true`, `false`

Call `ExitPlanMode` to request approval.
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): skip `ExitPlanMode` — append `[AUTO-APPROVED-PLAN] writing-spec: scenario plan auto-approved` to `## Open Questions` and proceed directly to Step 3.

## Step 3 — Write spec.md

After approval:

```
features/{verb}-{noun}/spec.md   ← feature spec
domain/{concept}/spec.md         ← domain spec
```

Domain specs: no DB, HTTP, queue, or file system references.

Set plan file phase:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" spec
```

## Step 4 — Run critic-spec (convergence loop)

Full protocol: @reference/critic-loop.md

```
Skill("critic-spec", "Review spec at [path]. Relevant docs: [paths].")
```

After each run, `plan-file.sh record-verdict` fires automatically (SubagentStop hook). Read `## Open Questions` for `critic-spec` markers in priority order:

| Marker | Action |
|--------|--------|
| `[BLOCKED-CEILING] critic-spec` | Stop — manual review required |
| `[BLOCKED-CATEGORY] critic-spec` | Stop — fix root cause first |
| `[BLOCKED-AMBIGUOUS] critic-spec: …` | Stop — human decision needed |
| `[BLOCKED-PARSE] critic-spec` | Stop — check critic output format before retrying |
| `[CONVERGED] critic-spec` | Proceed to Step 5 |
| `[FIRST-TURN] critic-spec` | Ask user (interactive) or append `[AUTO-APPROVED-FIRST] critic-spec` (non-interactive), then re-run |
| PARSE_ERROR (no `[BLOCKED-PARSE]` yet) | Re-run automatically (second consecutive PARSE_ERROR triggers `[BLOCKED-PARSE]`) |
| PASS, no `[CONVERGED]` yet | Re-run automatically |
| FAIL | Apply fix, then re-run |

On `[DOCS CONTRADICTION]`: update `docs/*.md` first, then fix the spec to match.

## Step 5 — Commit spec file

After critic-spec PASS, commit the spec file so it is visible to coder subagents running in isolated worktrees:

```bash
git add features/{verb}-{noun}/spec.md   # feature spec
# or
git add domain/{concept}/spec.md         # domain spec
git commit -m "feat(spec): add BDD scenarios for {name}"
```

Commit all spec files written in this run in a single commit. Do not commit any src/ or tests/ files here.

## Phase rollback

If re-entering `writing-spec` from a later phase — including:
- **slice mode**: `running-dev-cycle` calls `writing-spec` for feature 2+ while the plan phase is still `green` from the previous feature's `implementing`
- **any rollback**: a bug, pr-review finding, or critic verdict requires the spec to be revised

Steps:
1. Preserve all existing `## Critic Verdicts` — do not delete them
2. Append a phase transition entry to `## Phase Transitions`:
   ```
   - {previous-phase} → spec (reason: {one sentence})
   ```
3. Set plan phase: `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" spec`
4. Proceed normally from Step 2

## Rules

- One `Feature:` block per file
- One `Scenario:` per distinct flow; same flow + different values → `Scenario Outline`
- No technology names, framework names, or implementation details
