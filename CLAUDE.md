@local.md

# Layer rules

Full VSA + DDD layer definitions and dependency rules: @reference/layers.md

Summary:
- `src/features/` — business flow orchestration (may call domain + infrastructure)
- `src/domain/` — pure business rules (no external dependencies)
- `src/infrastructure/` — technical execution layer (DB, HTTP, file I/O)

Dependency direction: `features → domain`, `features → infrastructure`, `infrastructure → domain (interfaces only)`.
`domain` and `infrastructure` never import from `features`. `domain` never imports from `infrastructure`.

# Commands

<!-- TEMPLATE: initializing-project overwrites this section -->
<!-- Fill in after running /initializing-project -->
- Test: _(run `/initializing-project` to fill this in)_
- Integration test: _(run `/initializing-project` to fill this in)_

# Phase gate configuration

Override env vars and detailed docs: `reference/phase-gate-config.md`

Key vars: `PHASE_GATE_SRC_GLOB`, `PHASE_GATE_TEST_GLOB`, `PHASE_GATE_STRICT` (default `1` = fail-closed), `CLAUDE_PLAN_FILE` (pin active plan in CI or parallel-feature setups).

# Plan files

Feature work state: `plans/{feature-slug}.md` + `plans/{feature-slug}.state.json` (machine-readable phase).

Phase: `brainstorm → spec → red → green → integration → done`

Transition: `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" {phase}`

`find-active` order: `CLAUDE_PLAN_FILE` env → branch-slug match → newest non-done plan.

Parallel features: use separate git worktrees or pin `CLAUDE_PLAN_FILE`.

# Verification policy

Do not rely on training-data knowledge for factual claims. Verify external facts (APIs, models, CLI flags, versions) before asserting existence or non-existence. Full policy: `reference/verification-policy.md`

# Library documentation

Look up library/framework APIs: `/context7-plugin:docs {library-name}`. See `reference/docs-policy.md`.

# Automated runs

```bash
claude --permission-mode auto -p "/running-dev-cycle"
```

Phase-gate hooks fire before the auto-classifier — a FAIL (exit 2) aborts the tool call. Set `CLAUDE_PLAN_FILE` before launching to avoid spurious blocks.

# Local overrides

Bundle ships clean. Use `local-` prefix for project-specific additions (never touched by subtree updates).

Naming: `skills/local-<name>/SKILL.md`, `agents/local-<name>.md`, `reference/local-<topic>.md`

Project vocabulary + framework notes: create `.claude/local.md` (imported via `@local.md` above).

Settings overrides: `.claude/settings.local.json` (arrays merged, not overwritten).

