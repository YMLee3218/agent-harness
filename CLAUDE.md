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

Phase: `brainstorm → spec → red → (review) → green → integration → done`

`review` = pr-review FAIL recovery phase. Source modifications allowed; tests remain frozen. Transition to `green` only after [CONVERGED] pr-review marker. Never go `red` → `green` directly.

Transition: `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" {phase}`

`find-active` order: `CLAUDE_PLAN_FILE` env → branch-slug match → newest non-done plan.

Parallel features: use separate git worktrees or pin `CLAUDE_PLAN_FILE`.

Critic/review loop convergence markers in `## Open Questions`: `[FIRST-TURN]`, `[CONFIRMED-FIRST]`, `[AUTO-APPROVED-FIRST]`, `[CONVERGED]`, `[BLOCKED-CEILING]`, `[BLOCKED-AMBIGUOUS]`, `[BLOCKED-CATEGORY]`, `[BLOCKED-PARSE]`. Full policy: `reference/critic-loop.md` §Loop convergence.

# Context continuity

The plan file (`plans/{slug}.md`) is your external memory. It survives `/compact` and session restarts. The `PreCompact` hook saves state before every compaction; the `SessionStart` hook re-injects the plan summary at the start of each session.

Do not stop work early due to context concerns. When the context fills, `/compact` runs automatically — trust the hooks and resume from the plan file state.

In autonomous mode (`CLAUDE_NONINTERACTIVE=1`), the `Stop` hook verifies that the unit test suite passes before the session ends (green, integration, done phases). If tests are failing at stop time, the hook blocks the stop and you must fix the failures.

# Verification policy

Do not rely on training-data knowledge for factual claims. Verify external facts (APIs, models, CLI flags, versions) before asserting existence or non-existence. Full policy: `reference/verification-policy.md`

# Library documentation

Look up library/framework APIs: `/context7-plugin:docs {library-name}`. See `reference/docs-policy.md`.

# Automated runs

```bash
CLAUDE_NONINTERACTIVE=1 CLAUDE_PLAN_FILE=plans/{slug}.md \
  claude --permission-mode auto -p "/running-dev-cycle [--profile feature|greenfield|patch|trivial]"
```

`CLAUDE_NONINTERACTIVE=1` — suppresses **all** `AskUserQuestion` calls across every skill, replacing them with plan-file writes so the pipeline stops cleanly instead of hanging. Implies `CLAUDE_CRITIC_NONINTERACTIVE=1`. Full behaviour: `reference/critic-loop.md` §Non-interactive mode.

`CLAUDE_STOP_CHECK_TIMEOUT` — override the Stop-hook test timeout (default: 600s). Set higher for large test suites (e.g. `CLAUDE_STOP_CHECK_TIMEOUT=1200`).

Phase-gate hooks fire before the auto-classifier — a FAIL (exit 2) aborts the tool call. Set `CLAUDE_PLAN_FILE` before launching to avoid spurious blocks.

## Pre-flight checklist (autonomous runs)

Complete every item before launching. Missing items cause `[BLOCKED]` entries in `## Open Questions` and the run halts.

1. **`local.md`** — copy `examples/local.md` to `.claude/local.md` and fill in: language, runtime, test command, lint command, integration-test command.
2. **`docs/{concept}.md`** — at least one domain concept file must exist. If absent, brainstorming blocks immediately.
3. **`docs/requirements/{name}.md`** — write the requirement before launching (for `feature` / `greenfield` profiles). Brainstorming reads this file and skips interactive clarification when it exists.
4. **Clean working tree** — `git status --porcelain` must return empty, or brainstorming will block.
5. **`CLAUDE_PLAN_FILE`** — set to an absolute path. For greenfield: set to a path that does not yet exist; brainstorming will create it. For resume: set to the existing plan file.
6. **Profile** — pass `--profile greenfield` for new projects, `--profile feature` (default) for incremental work.
7. **Required plugins** — `context7-plugin`, `pr-review-toolkit`, and `code-simplifier` must be installed in your Claude Code environment before launching. Install via `claude plugin install <name>`. These plugins are already enabled in `.claude/settings.json`; no additional settings entry is needed. Without these plugins installed, `implementing` fails at the pr-review step.
8. **`gh` CLI auth** — run `gh auth status` and confirm you are authenticated. The `implementing` skill runs `gh pr create` at the end of each feature. Without auth, the PR step fails and `pr-review-toolkit` cannot run.
9. **`jq`** — run `jq --version` and confirm it is installed. Both `scripts/phase-gate.sh` and `scripts/pretooluse-bash.sh` require `jq` to parse hook payloads. With `PHASE_GATE_STRICT=1` (the default), every Write, Edit, and Bash tool call is blocked if `jq` is absent.

### Minimal autonomous run (feature profile)

```bash
# 1. Write docs/requirements/add-widget.md manually
# 2. Ensure .claude/local.md is populated
# 3. Launch
CLAUDE_NONINTERACTIVE=1 CLAUDE_PLAN_FILE="$(pwd)/plans/add-widget.md" \
  claude --permission-mode auto -p "/running-dev-cycle --profile feature"
```

### Greenfield autonomous run

```bash
CLAUDE_NONINTERACTIVE=1 CLAUDE_PLAN_FILE="$(pwd)/plans/myapp.md" \
  claude --permission-mode auto -p "/running-dev-cycle --profile greenfield"
```

After the run, inspect `## Open Questions` in the plan file for any `[BLOCKED]` entries that require manual follow-up.

# Local overrides

Project vocabulary + framework notes: create `.claude/local.md` (imported via `@local.md` above). See `examples/local.md` for the template.

User-local settings delta (additional MCP servers, personal permissions, env vars): `.claude/settings.local.json`. Arrays merge with `.claude/settings.json` per Claude Code rules — do not duplicate entries already in `settings.json`.

