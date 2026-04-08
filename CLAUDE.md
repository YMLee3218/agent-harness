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

# Phase gate overrides

The phase gate checks src/ and test/ paths based on built-in heuristics. Override per project if your layout differs:

```bash
# In your project's .env or shell profile — colon-separated glob patterns
export PHASE_GATE_SRC_GLOB="src/domain/*:src/features/*:src/infrastructure/*:app/*:internal/*"
export PHASE_GATE_TEST_GLOB="tests/*:*_test.*:*.test.*:*.spec.ts:*.spec.js"
```

Defaults cover Maven (`src/main/kotlin/`, `src/main/java/`), standard JS/Python (`src/{domain,features,infrastructure}/`), monorepos (`packages/*/src/`, `apps/*/src/`), Go (`internal/`, `cmd/`), Rails (`app/`), Rust (`crates/*/src/`), and generic `lib/`. Set these in `initializing-project` step for projects with non-standard layouts.

`PHASE_GATE_STRICT=1` — when set, the phase gate blocks all writes if no active plan file exists (fail-closed mode). **Default in this bundle is `1` (fail-closed).** Override to `0` in downstream projects that need fail-open behaviour.

`CLAUDE_PLAN_FILE=/path/to/plan.md` — pins the active plan file for `plan-file.sh find-active`. Highest priority override — use when multiple features run in parallel on the same branch, or in CI where branch-based lookup is unreliable.

# Prerequisites (global settings)

The following belong in **each developer's `~/.claude/settings.json`**, not in the bundle (`workspace/`).

- **Stop hook** — `afplay /System/Library/Sounds/Glass.aiff` + `~/.claude/hooks/notify-stop.sh`
- **PermissionRequest hook** — `~/.claude/hooks/claude-remote-approver.sh hook`
  - Install: copy `workspace/scripts/claude-remote-approver.sh` to `~/.claude/hooks/claude-remote-approver.sh` and `chmod +x` it.
  - The copy in `workspace/scripts/` is a placeholder; the active version must live in the user dir.
- **model** — personal model preference; `opusplan` routes planning interactions to Opus 4.6 for deeper reasoning. Use `/plan <description>` to enter plan mode immediately with a task description, or `/model` in-session to switch.
- **skipDangerousModePermissionPrompt** — per-machine setting

Example:
```json
{
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/notify-stop.sh"}]}],
    "PermissionRequest": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/claude-remote-approver.sh hook"}]}]
  },
  "model": "opusplan",
  "skipDangerousModePermissionPrompt": true
}
```

# Plan files

Feature work state is preserved in `plans/{feature-slug}.md`. Phase can be recovered after `/compact`.

Frontmatter (optional fields for multi-plan disambiguation):
```yaml
---
feature: {feature-slug}
phase: brainstorm
session_id: {optional — pin with CLAUDE_PLAN_FILE env for parallel sessions}
---
```

Structure:
```
## Vision
## Scenarios
## Test Manifest
## Phase       (brainstorm | spec | red | green | refactor | integration | done)
## Phase Transitions
## Critic Verdicts
## Critic Runs           (written by SubagentStart hook — start timestamp per critic invocation)
## Open Questions
## Task Ledger           (written by implementing — one row per coder subagent task)
## Integration Failures  (written by running-integration-tests — one entry per failed run)
```

Phase transitions are made via:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" {phase}
```

`find-active` resolution order: `CLAUDE_PLAN_FILE` env → branch-slug match → newest non-done plan (warns to stderr when falling back).

**Parallel features**: when running multiple features concurrently, use a separate git worktree per feature (`git worktree add .worktrees/feature-x feature/x`) or pin `CLAUDE_PLAN_FILE` to avoid the fallback picking the wrong plan.

# Library documentation

Look up library/framework APIs with context7: `/context7-plugin:docs {library-name}`

When a `writing-spec` or `implementing` step introduces an external library dependency, verify the API via context7 before finalising the design. See `reference/docs-policy.md`.

# Design rationale

Anthropic source-mapping for every major harness decision: `reference/rationale.md`

Pipeline phase map (phase → skill → critic → next phase): `reference/pipeline-map.md`

# Automated and sandboxed runs

For long-running or unattended pipeline steps (e.g. `/running-dev-cycle`), pass `--permission-mode auto` to skip interactive permission prompts:
```
claude --permission-mode auto -p "/running-dev-cycle"
```

For OS-level process isolation (untrusted code, security-sensitive repos), use `/sandbox` or launch with the sandbox flag. See Claude Code docs for platform availability.

**Hook execution order and `--permission-mode auto`**: `PreToolUse` hooks (`phase-gate.sh`, `pretooluse-bash.sh`) run *before* the auto-classifier evaluates a permission request. A phase-gate `FAIL` (exit 2) aborts the tool call even in auto mode — the classifier never sees it. In non-interactive pipelines a phase-gate block therefore terminates the current step rather than prompting. To avoid spurious aborts, set `CLAUDE_PLAN_FILE` and advance the plan to the correct phase before launching `claude --permission-mode auto -p "..."`.

**Important**: `scripts/pretooluse-bash.sh` is a mistake-prevention gate, **not** a security sandbox. It blocks common destructive patterns (e.g. `rm -rf`, force-push) but cannot protect against malicious or crafted inputs. For genuine sandboxing use `/sandbox` + OS-level isolation.

# Harness tests

```bash
bash workspace/scripts/tests/phase-gate.test.sh
bash workspace/scripts/tests/plan-file.test.sh
bash workspace/scripts/tests/pretooluse-bash.test.sh
# or:
make -C workspace test
```

# Local overrides

This bundle ships clean. Project-specific additions live alongside bundle files using a `local-` prefix — the bundle never creates `local-*` files, so subtree pulls are always conflict-free.

**Naming convention:**
- `.claude/skills/local-<name>/SKILL.md` — project-specific skills
- `.claude/commands/local-<name>.md` — project-specific slash commands
- `.claude/agents/local-<name>.md` — project-specific subagents
- `.claude/reference/local-<topic>.md` — language guides, framework notes, planning docs

**Project guide (`local.md`):** Create `.claude/local.md` for project vocabulary, external system references, and framework conventions. This file is imported at the top of this CLAUDE.md via `@local.md` — if the file does not exist Claude Code silently skips the import. Commit `local.md` to your project repo (do not gitignore it).

**Settings overrides:** Use `.claude/settings.local.json` (same schema as `settings.json`; auto-gitignored by Claude Code). Arrays (`permissions.allow`, `hooks`) are merged across all config layers — not overwritten.

**Templates:** Copy from `.claude/examples/` and rename, removing the `examples/` path prefix:
- `examples/skills/local-skill/SKILL.md` → `skills/local-<name>/SKILL.md`
- `examples/commands/local-command.md` → `commands/local-<name>.md`
- `examples/agents/local-agent.md` → `agents/local-<name>.md`
- `examples/reference/local-guide.md` → `reference/local-<topic>.md`
- `examples/local.md` → `local.md`

Full install/update procedure: `reference/local-overlay.md`
