# Language

@~/harness-builder/CLAUDE.md

@local.md

# Layer rules

@reference/layers.md

# Commands

<!-- TEMPLATE: initializing-project overwrites this section -->
<!-- Fill in after running /initializing-project -->
- Test: _(run `/initializing-project` to fill this in)_
- Integration test: _(run `/initializing-project` to fill this in)_

# Phase gate configuration

Override env vars and detailed docs: `reference/phase-gate-config.md`

# Plan files

Feature work state: `plans/{feature-slug}.md` (phase tracked in `## Phase` section and frontmatter).

Phase sequence and per-phase write rules: `@reference/phase-gate-config.md §Phase enforcement rules`

Plan file commands (transition, commit-phase, find-active ordering 등): `scripts/plan-file.sh`. Marker side-effects: `reference/markers.md §Operation → markers reverse lookup`.

Parallel features: use separate git worktrees or pin `CLAUDE_PLAN_FILE`.

Critic/review loop convergence markers and all other plan-file markers: `@reference/markers.md` (single source of truth — includes Write/Read/Clear/gc lifecycle and operation→marker reverse lookup). Full convergence policy: `reference/critics.md §Loop convergence`. Skills stop and write `[BLOCKED]` to `## Open Questions` when a critic loop cannot converge or a required condition is not met.

# Context continuity

The plan file (`plans/{slug}.md`) is your external memory. It survives `/compact` and session restarts. The `SessionStart` hook re-injects the plan summary at the start of each session.

Do not stop work early due to context concerns. When the context fills, `/compact` runs automatically — trust the hooks and resume from the plan file state.

In autonomous mode, the `Stop` hook verifies that the unit test suite passes before the session ends (green and integration phases; done is excluded — session already closed). If tests are failing at stop time, the hook blocks the stop and you must fix the failures.

# Automated runs

```bash
CLAUDE_PLAN_FILE=plans/{slug}.md \
  claude --permission-mode auto -p "/running-dev-cycle [--profile feature|greenfield]"
```

Phase-gate and hook execution order: `@reference/phase-gate-config.md §Hook execution order with --permission-mode auto`.

Pre-flight checklist: `scripts/preflight.sh` (tool and file requirements listed in that script's header; missing items write `[BLOCKED] preflight:` and halt the run).

# Local overrides

Project vocabulary + framework notes: create `.claude/local.md` (imported via `@local.md` above). See `examples/local.md` for the template. `.claude/local.md` is gitignored (machine-local). Shared domain rules belong in `reference/`.

User-local settings delta (additional MCP servers, personal permissions, env vars): `.claude/settings.local.json`. Arrays merge with `.claude/settings.json` per Claude Code rules — do not duplicate entries already in `settings.json`.
