# Language

@reference/language.md
@reference/anti-hallucination.md
@reference/effort.md

@local.md

# Layer rules

@reference/layers.md

# Commands

<!-- TEMPLATE: initializing-project overwrites this section -->
<!-- Fill in after running /initializing-project -->
- Test: _(run `/initializing-project` to fill this in)_
- Integration test: _(run `/initializing-project` to fill this in)_

# Effort Policy

Predictions are not status. When a backgrounded subprocess reports a block or failure, read its actual output before any user-facing message and surface what the output says. Never describe a run as "should succeed" or "transient" based on the exit message alone.

# Operations

Never append `&` to Bash commands. For long-running scripts, use the `run_in_background=true` Bash tool parameter instead — `&` orphans the process.
Plan files: `plans/{slug}.md` (live in the feature worktree while active; merged into main on done); commands: `scripts/plan-file.sh`; markers: `@reference/markers.md`.
Phase enforcement and env vars: `@reference/phase-gate-config.md`.
Pre-flight: `scripts/preflight.sh` (missing items write `[BLOCKED:env] preflight:` and halt the run).
Dev cycle: invoke `run-dev-cycle.sh` via `/running-dev-cycle` and `run-integration.sh` via `/running-integration-tests` — both SKILL.md wrappers use `run_in_background=true` (scripts may run for hours). After launching, end the turn immediately — the completion notification drives the next turn. Read `## Open Questions` for markers and proceed per exit code. Do not call `run-critic-loop.sh` directly in the normal dev cycle — it is invoked internally by these scripts. Exception: recovery cascades (e.g. `@reference/phase-ops.md §DOCS CONTRADICTION cascade`) use direct `--nested` invocations.

## Workflow model

**New feature**: from main checkout, run `/brainstorming` (creates `feature/{slug}` worktree + plan inside it) → run `/running-dev-cycle` (calls `EnterWorktree` to enter the worktree, then builds).
**Resume**: `cd` to the feature worktree, then run `/running-dev-cycle` (cwd=worktree → `EnterWorktree` skipped; hooks, cycle, and plan all align).
**Merge/approve**: after `done`, from the **main checkout**, human approves → `feature/{slug}` is merged into `main` with `--no-ff` + worktree removed. If more feature worktrees remain: `[RESTART]` with path to next; otherwise `[DONE]`.
**Autonomous run** (from inside the feature worktree): `CLAUDE_NONINTERACTIVE=1 CLAUDE_PROJECT_DIR="$(git worktree list --porcelain | head -1 | awk '{print $2}')" CLAUDE_PLAN_FILE="$(pwd)/plans/{slug}.md" claude --permission-mode auto -p "/running-dev-cycle"`.

## Harness invariants

- `plans/*.state/` is runtime-only — **never version-controlled**. `.gitignore` must contain `plans/**/*.state/`. If `git ls-files plans/` shows `.state/` entries, run `git rm -r --cached 'plans/*.state/*' && echo 'plans/**/*.state/' >> .gitignore && git commit`.

# Local overrides

Project vocabulary + framework notes: create `.claude/local.md` (imported via `@local.md` above). See `examples/local.md` for the template. Shared domain rules belong in `reference/`.

User-local settings delta (additional MCP servers, personal permissions, env vars): `.claude/settings.local.json`. Arrays merge with `.claude/settings.json` per Claude Code rules — do not duplicate entries already in `settings.json`.
