---
name: initializing-project
description: >
  Initialize VSA+DDD project structure and generate a project-level CLAUDE.md.
  Trigger: "set up the project", "initialise", "create the project structure", new project start, no src/ exists.
  Scaffolds src/features, src/domain, src/infrastructure, tests/integration, docs/requirements, plans/.
disable-model-invocation: true
---

**Non-interactive handling**: emit `[BLOCKED] {reason}` per the inline conditions below; do not ask questions.

# Project Initialisation

## Step 1 — Extract domain concepts

- `Read` all files in `docs/` if present
- `Glob` for any existing source structure

If docs/ is absent:
- Interactive: `AskUserQuestion` for core business concepts, actions, tech stack, and commands.
- Non-interactive: `[BLOCKED] docs/ is absent — create at least one docs/{concept}.md and populate .claude/local.md before re-running`

If docs/ is present but `.claude/local.md` is absent or missing commands:
- Interactive: `AskUserQuestion` — "What are the tech stack, test command, and lint command?"
- Non-interactive: `[BLOCKED] .claude/local.md is missing or incomplete — fill in language, test command, and lint command`

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
features/               ← BDD spec files per feature (features/{verb}-{noun}/spec.md)
domain/                 ← BDD spec files per domain concept (domain/{concept}/spec.md)
infrastructure/         ← BDD spec files per infrastructure component (infrastructure/{concept}/spec.md)
```

List proposed `domain/{concept}/spec.md` drafts and initial domain concept names.

- **Interactive**: call `ExitPlanMode` to request approval.
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): skip `ExitPlanMode` and proceed to Step 3.

## Step 3 — Scaffold directories and generate CLAUDE.md

After approval, create the directory structure:

```bash
mkdir -p src/features src/domain src/infrastructure tests/integration docs/requirements plans features domain infrastructure
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

Edit `CLAUDE.md` at project root — do **not** replace the file; patch specific sections
so the harness instructions already in the file are preserved.

**1. Prepend project context at the very top** (before `@local.md`):

```markdown
# {Project Name}

## Project Context
{One-sentence description}

## Tech Stack
- Runtime: {language + version}
- Framework: {if applicable}
- Database: {if applicable}
- Test runner: {tool}

```

**2. Replace the two placeholder lines** under the existing `# Commands` section:

Old lines (remove both):
```
- Test: _(run `/initializing-project` to fill this in)_
- Integration test: _(run `/initializing-project` to fill this in)_
```

New lines (insert in their place):
```
- Dev: `{dev command}`
- Test: `{test command}`
- Integration test: `{integration-test command}`
- Lint: `{lint command}`
```

**3. Insert after the `# Commands` section** (before `# Operations`):

```markdown
# Domain Knowledge

@docs/{concept1}.md
@docs/{concept2}.md

# Architecture Decisions

- {decision if any; otherwise leave this section empty}

```

Write per-layer CLAUDE.md files so Claude Code injects focused layer rules when
editing files in each layer's directory. The template at `rules/src-layer.md.template`
is rendered for each layer (includes `paths:` frontmatter for Claude Code path scoping):

```bash
tmpl="$CLAUDE_PROJECT_DIR/.claude/rules/src-layer.md.template"
[ -f "$tmpl" ] || { echo "[init] ERROR: rules template not found: $tmpl" >&2; exit 1; }
for layer in domain features infrastructure; do
  case "$layer" in
    domain)         label="Domain" ;;
    features)       label="Features" ;;
    infrastructure) label="Infrastructure" ;;
  esac
  sed -e "s/{{LAYER}}/$layer/g" -e "s/{{LAYER_LABEL}}/$label/g" "$tmpl" > "src/$layer/CLAUDE.md"
done
```

For each domain concept directory:
```bash
cp src/domain/CLAUDE.md src/domain/{concept}/CLAUDE.md
```

Generate the language-specific critic-code pattern conf (read language from `.claude/local.md`):
```bash
_lang="$(grep -i 'language:' "$CLAUDE_PROJECT_DIR/.claude/local.md" | head -1 | awk -F: '{gsub(/^[[:space:]-]*/,"",$2); print $2}' | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
if [ -n "$_lang" ]; then
  mkdir -p "$CLAUDE_PROJECT_DIR/.claude/scripts/critic-code/patterns"
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/critic-code/patterns.template" "$_lang" \
    > "$CLAUDE_PROJECT_DIR/.claude/scripts/critic-code/patterns/${_lang}.conf" \
    || { echo "[init] ERROR: failed to generate patterns conf for language '${_lang}'" >&2; exit 1; }
fi
```

## Step 4 — Create initial plan file + commit scaffold

Create the initial plan file `plans/{project-slug}.md` **before** committing so it is included in the scaffold commit (brainstorming's dirty-tree check runs after this commit and must see a clean tree):

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" init "plans/{project-slug}.md"
# Then edit plans/{project-slug}.md to fill in the ## Vision section
```

Non-interactive (`CLAUDE_NONINTERACTIVE=1`): skip `ExitPlanMode`.

Then stage and commit all scaffold files so the working tree is clean before brainstorming runs its dirty-tree check.

If the project is not yet a git repository (`git rev-parse --git-dir` fails):
- **Interactive**: use `AskUserQuestion` — "No git repository found. Run `git init && git add .gitignore` first, then re-run initializing-project."
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): append `[BLOCKED] not a git repository — run git init before initializing-project` to `## Open Questions` in the plan file, then stop.

Stage and commit if there is anything to stage:
```bash
git add CLAUDE.md
git add src/ docs/ plans/ features/ domain/
if git diff --cached --quiet; then
  echo "[SKIP] nothing to commit — scaffold already present"
else
  git commit -m "chore(init): scaffold VSA+DDD project structure"
fi
```
