# Local overlay — install, update, and extension guide

This document describes how downstream projects consume the bundle and add project-specific extensions without merge conflicts.

## Distribution model

The bundle is distributed as a git subtree. The `workspace/` directory of the source repo becomes the `.claude/` directory of each downstream project.

### Initial install

```bash
# From the downstream project root:
git subtree add --prefix=.claude git@github.com:<user>/agent-bundle.git main --squash
```

This creates a single squash commit that records the bundle snapshot. All files appear under `.claude/`.

### Update to latest bundle

```bash
git subtree pull --prefix=.claude git@github.com:<user>/agent-bundle.git main --squash
```

The subtree pull performs a 3-way merge. Files with a `local-` prefix and `local.md` are not present in the bundle, so they are never touched by the pull.

### Publishing bundle changes upstream

If you fix a bug in the bundle from within a downstream project:

```bash
git subtree push --prefix=.claude git@github.com:<user>/agent-bundle.git main
```

Only edit bundle files (no `local-*`, no `local.md`) before pushing upstream.

---

## Naming convention for local additions

The bundle guarantees it will **never** create files or directories with the `local-` prefix. This is the conflict-avoidance contract.

| What to add | Location |
|-------------|----------|
| Project-specific skill | `.claude/skills/local-<name>/SKILL.md` |
| Project-specific slash command | `.claude/commands/local-<name>.md` |
| Project-specific subagent | `.claude/agents/local-<name>.md` |
| Language/framework/planning guide | `.claude/reference/local-<topic>.md` |
| Project vocabulary and context | `.claude/local.md` |
| Personal settings overrides | `.claude/settings.local.json` (auto-gitignored) |

---

## Adding a project guide (`local.md`)

`.claude/local.md` is imported at the top of `.claude/CLAUDE.md` via `@local.md`. Claude Code resolves this relative to the CLAUDE.md file and silently skips the import if the file does not exist.

Typical sections:

```markdown
# Project overview
One-paragraph description.

# Language and runtime
- Language: TypeScript 5.x / Node 22
- Package manager: pnpm
- Framework: Next.js 15

# Domain vocabulary
- **Order** — a confirmed purchase; immutable after creation
- **Cart** — a mutable pre-order basket

# Commands
- Test: pnpm test
- Lint: pnpm lint
- Integration test: pnpm test:integration

# External systems
- Linear project: MYPROJECT (bug tracking)
- Grafana: internal.grafana.io/d/api-latency (latency oncall dashboard)
```

Commit `local.md` to the project repo. It is project-specific context, not a personal override.

---

## Using templates

Copy from `.claude/examples/` and place in the appropriate directory:

```bash
# Skill
cp -r .claude/examples/skills/local-skill .claude/skills/local-myfeature
# Edit .claude/skills/local-myfeature/SKILL.md

# Slash command
cp .claude/examples/commands/local-command.md .claude/commands/local-mycommand.md
# Edit the copy

# Subagent
cp .claude/examples/agents/local-agent.md .claude/agents/local-myagent.md

# Reference guide
cp .claude/examples/reference/local-guide.md .claude/reference/local-typescript.md

# Project guide
cp .claude/examples/local.md .claude/local.md
```

---

## Settings

`settings.local.json` is merged on top of `settings.json` by Claude Code. Arrays (`permissions.allow`, `permissions.deny`, `hooks`) are concatenated and deduplicated across all config layers. Scalars use the most specific value.

`settings.local.json` is automatically gitignored by Claude Code — use it for personal/machine-specific overrides. Project-wide settings (e.g. env-var overrides for `PHASE_GATE_SRC_GLOB`) belong in `.envrc` or a shell profile sourced by all contributors.

---

## Splitting the bundle source for distribution

If `workspace/` lives inside a larger monorepo, extract it as a distributable branch:

```bash
git subtree split --prefix=workspace -b bundle-dist
git push origin bundle-dist:main  # push to the dedicated bundle remote
```

Or maintain a dedicated bundle repo from the start with `workspace/` contents at the root.
