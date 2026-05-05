---
name: brainstorming
description: >
  Brainstorm/decompose new features into user-facing Small/Large features. Domain concepts and infrastructure components are not identified here — that is writing-spec's responsibility.
  Trigger: "build X", "add Y", "need Z", "feature", or any new-functionality phrasing.
  Decomposes requirements before any spec or code is written.
  Always run before writing-spec. For brand-new repos, run initializing-project first.
  Do NOT trigger automatically — only on explicit user request or when called by running-dev-cycle.
context: fork
agent: brainstormer
---

# Brainstorming Workflow

Determine first: **new feature** or **modification**?

---

## New Feature Flow

### Step 1 — Read plan file + clarify

Phase entry protocol: @reference/phase-ops.md §Skill phase entry — expected phases: `brainstorm` (re-entry), `done` (new feature after previous feature complete).

Phase entry:
- Phase `brainstorm`: proceed normally (re-entry after `/compact` or session interruption).
- Phase `done`: proceed normally (new feature after previous feature is complete).
- No plan file (CLAUDE_PLAN_FILE unset or file does not exist): proceed normally — Step 1 initialises it.
- Any other phase: `[BLOCKED] brainstorming entered from unexpected phase {phase} — finish the current feature first, or unset CLAUDE_PLAN_FILE to start a fresh plan for the new feature`.

**Pre-entry git check** — run before any other work:

```bash
git status --porcelain
```

If dirty working tree (non-empty output): `[BLOCKED] dirty working tree — commit or stash changes first`

If `CLAUDE_PLAN_FILE` is unset, derive a slug from the feature name (kebab-case, max 30 chars) and use `plans/{slug}.md` as the plan path throughout. If the plan file (from `CLAUDE_PLAN_FILE` or derived) does not yet exist, run `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" init "<plan-path>"` before any other `plan-file.sh` command.

Read `plans/{slug}.md` if it exists (resume context after `/compact`).

- `Glob` `src/features/` to find reusable existing features
- `Glob` `docs/` and `Read` any `docs/*.md` that exist — these are the SOT for domain knowledge
- `Read` `features/*/spec.md` for any features that may be reused (signatures and behaviour, not implementation)

If `docs/` is empty or absent: `[BLOCKED] docs/ is empty — create at least one docs/{concept}.md before re-running`

After docs/ is present, write or update `docs/{concept}.md` (same template as initializing-project Step 3). This must happen before writing-spec runs — critics use docs/*.md as the contradiction SOT.

If `docs/requirements/{name}.md` already exists: treat the file as the complete and approved requirement.

If `docs/requirements/{name}.md` does **not** exist: proceed — Step 3 will create it from the user's feature request.

### Step 2 — Decompose

Classify each candidate as Small or Large feature per @reference/layers.md §Feature size classification. Name format per @reference/layers.md §Naming conventions.

Do NOT identify domain concepts, infrastructure components, or assign anything to `domain/` or `infrastructure/` — those are architectural decisions made by writing-spec.

If proposing domain rules or constraints not found in `docs/*.md`: mark the assumption `[UNVERIFIED CLAIM]` in the plan file and include it provisionally; critic-spec will independently flag unverified claims in the spec.

List each candidate as small or large. Write decomposition to plan file. Proceed to Step 3.

### Step 3 — Write output + create branch

If `docs/requirements/{name}.md` does not already exist, create it:

```markdown
# {Requirement Name}

## Business Goal
{One sentence}

## Small Features
- `{verb}-{noun}`: {description}

## Large Features
- `{verb}-{noun}`: {which small features it composes}

## Reused Existing Features
- {list or "none"}

## Out of Scope
- {explicitly excluded items}
```

Pre-branch checks:

| Condition | Action |
|-----------|--------|
| Not a git repo (`git rev-parse --git-dir` fails) | Append `[BLOCKED] not a git repository` to `## Open Questions` and stop |
| Branch already exists (`git show-ref --verify refs/heads/feature/{name}` succeeds) | Log `[INFO] branch feature/{name} already exists — reusing` to `## Open Questions` and run `git checkout feature/{name}` |

Then (if not already on the branch): `git checkout -b feature/{name}`

Set plan file phase (skip if already in `brainstorm` — do not re-transition to the same phase; see `@reference/phase-ops.md §Skill phase entry`):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" brainstorm \
  "decomposition approved — starting brainstorm phase"
```

---

## Modification Flow

### Step 1 — Identify impact

- `Read` relevant `docs/requirements/*.md` and `docs/*.md`
- `Glob` `src/features/` and `src/domain/`
- `Read` `features/*/spec.md` for any features affected by the modification

Do not read `src/` implementation. If the modification conflicts with `docs/*.md`, list required doc updates. Write impact list to plan file. Proceed to Step 2.

### Step 2 — Update docs (if needed)

Update affected `docs/*.md` (SOT) before proceeding.

### Step 3 — Write output

If `docs/requirements/{name}.md` does not already exist, create it. Apply the same git pre-check as New Feature Flow Step 3.

Set phase to `brainstorm` (skip if already in `brainstorm` — do not re-transition to the same phase):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" brainstorm \
  "re-brainstorming"
```

---

## Hard Stop

Do not move to `writing-spec` until:
- Feature names comply with `@reference/layers.md §Naming conventions`
- Every feature is classified as small or large (no layer assignment — writing-spec's responsibility)
- Plan file `plans/{slug}.md` exists with Phase `brainstorm`
