---
name: initializing-project
description: >
  Initialize VSA+DDD project structure and generate a project-level CLAUDE.md.
  Trigger: "set up the project", "initialise", "create the project structure", new project start, no src/ exists.
  Scaffolds src/features, src/domain, src/infrastructure, tests/integration, docs/requirements, plans/.
---

# Project Initialisation

Layer rules: @reference/layers.md

## Step 1 — Extract domain concepts

Use `EnterPlanMode`, then:
- `Read` all files in `docs/` if present
- `Glob` for any existing source structure

If docs/ is absent:
- **Interactive**: use `AskUserQuestion` for core business concepts, actions, tech stack, and commands.
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): append `[BLOCKED] docs/ is absent — create at least one docs/{concept}.md and populate .claude/local.md before re-running` to `## Open Questions` in the plan file, then stop.

If docs/ is present but `.claude/local.md` is absent or missing commands:
- **Interactive**: use `AskUserQuestion` — "What are the tech stack, test command, and lint command?"
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): append `[BLOCKED] .claude/local.md is missing or incomplete — fill in language, test command, and lint command` to `## Open Questions` and stop.

## Step 2 — Propose structure

Write the plan to the plan file:

```
src/
├── features/
├── domain/
└── infrastructure/
tests/
└── integration/
docs/
└── requirements/       ← append-only
plans/                  ← plan files live here
features/               ← BDD spec files per feature (features/{verb-noun}/spec.md)
domain/                 ← BDD spec files per domain concept (domain/{concept}/spec.md)
```

List proposed `domain/{concept}/spec.md` drafts and initial domain concept names.

- **Interactive**: call `ExitPlanMode` to request approval.
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): skip `ExitPlanMode` — append `[AUTO-APPROVED-PLAN] initializing-project: structure auto-approved` to `## Open Questions` and proceed to Step 3.

## Step 3 — Scaffold directories and generate CLAUDE.md

After approval, create the directory structure:

```bash
mkdir -p src/features src/domain src/infrastructure tests/integration docs/requirements plans features domain
```

For each approved domain concept:
```bash
mkdir -p src/domain/{concept} domain/{concept}
```

Write draft `domain/{concept}/spec.md` (empty Feature block):
```gherkin
Feature: {concept name}

  # Scenarios to be written by writing-spec skill
```

**Write `docs/{concept}.md` for each domain concept** (this is the SOT that critics use for contradiction checks):

```markdown
# {Concept Name}

## Definition
{One-paragraph description of what this concept is and is not}

## Rules
- {Invariant or business rule}

## Vocabulary
- **{term}**: {definition}
```

If docs/ already contains relevant files, read and preserve them. If docs/ is absent and the user provided no domain documentation:
- **Interactive**: use `AskUserQuestion` — "What are the core rules and constraints for {concept}? I'll use this to create docs/{concept}.md."
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): leave the Definition / Rules / Vocabulary sections with `TODO` placeholders; append `[WARN] docs/{concept}.md has placeholder content — fill in domain rules before writing-spec runs` to `## Open Questions`.

Write `CLAUDE.md` at project root:

```markdown
# {Project Name}

## Project Context
{One-sentence description}

## Tech Stack
- Runtime: {language + version}
- Framework: {if applicable}
- Database: {if applicable}
- Test runner: {tool}

## Commands
- Dev: `{command}`
- Test: `{command}`
- Integration test: `{command}`
- Lint: `{command}`

## Domain Knowledge
@docs/{filename}.md

## Architecture Decisions
- {decision}
```

Write per-layer CLAUDE.md files so Claude Code injects focused layer rules when
editing files in each layer's directory. Strip the YAML frontmatter block from each
source template — CLAUDE.md files do not use frontmatter:

```bash
# Extract body (everything after the closing ---) from each rules template.
# Fail immediately if a rules file is missing rather than silently writing an empty CLAUDE.md.
for rules_file in \
  "$CLAUDE_PROJECT_DIR/.claude/rules/src-domain.md" \
  "$CLAUDE_PROJECT_DIR/.claude/rules/src-features.md" \
  "$CLAUDE_PROJECT_DIR/.claude/rules/src-infrastructure.md"; do
  [ -f "$rules_file" ] || { echo "[init] ERROR: rules file not found: $rules_file" >&2; exit 1; }
done

awk '/^---/{n++; if(n==2){found=1; next}} found{print}' \
  "$CLAUDE_PROJECT_DIR/.claude/rules/src-domain.md" > src/domain/CLAUDE.md
awk '/^---/{n++; if(n==2){found=1; next}} found{print}' \
  "$CLAUDE_PROJECT_DIR/.claude/rules/src-features.md" > src/features/CLAUDE.md
awk '/^---/{n++; if(n==2){found=1; next}} found{print}' \
  "$CLAUDE_PROJECT_DIR/.claude/rules/src-infrastructure.md" > src/infrastructure/CLAUDE.md
```

For each domain concept directory:
```bash
cp src/domain/CLAUDE.md src/domain/{concept}/CLAUDE.md
```

## Step 4 — Commit scaffold

Stage and commit all scaffold files so the working tree is clean before brainstorming runs its dirty-tree check.

If the project is not yet a git repository (`git rev-parse --git-dir` fails):
- **Interactive**: use `AskUserQuestion` — "No git repository found. Run `git init && git add .gitignore` first, then re-run initializing-project."
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): append `[BLOCKED] not a git repository — run git init before initializing-project` to `## Open Questions` in the plan file, then stop.

Verify there is something to stage before committing:
```bash
git status --porcelain | grep -q . || { echo "[SKIP] nothing to commit — scaffold already present"; }
```

Stage and commit (use `-A` with explicit paths to avoid glob-expansion issues in bash without `globstar`):
```bash
git add -A CLAUDE.md src docs plans features domain
git commit -m "chore(init): scaffold VSA+DDD project structure"
```

## Step 5 — Create initial plan file

Create initial plan file `plans/{project-slug}.md`:

```markdown
---
feature: {project-slug}
phase: brainstorm
schema: 1
---

## Vision
{one-sentence goal}

## Scenarios

## Test Manifest

## Phase
brainstorm

## Phase Transitions
- brainstorm → (initial)

## Critic Verdicts

## Task Ledger

## Open Questions
```
