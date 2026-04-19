---
name: brainstorming
description: >
  Brainstorm/decompose new features into VSA Small/Large features and DDD domain concepts.
  Trigger: "build X", "add Y", "need Z", "만들자", "추가", "feature", or any new-functionality phrasing.
  Decomposes requirements before any spec or code is written.
  Always run before writing-spec. For brand-new repos, run initializing-project first.
effort: medium
paths:
  - docs/**
  - plans/**
---

# Brainstorming Workflow

## Step 0 — Detect uninitialized project (autonomous pre-check)

Check for `CLAUDE.md` at the project root — do NOT use `Glob("src/**")` (empty after init, triggers spurious re-initialization).

```bash
test -f "$CLAUDE_PROJECT_DIR/CLAUDE.md" && echo "initialized" || echo "not-initialized"
```

If the project is NOT initialized (file absent):
- Auto-invoke `initializing-project` immediately: `Skill("initializing-project")`
- Do NOT ask the user whether to initialize — detect and act.
- After `initializing-project` returns, continue into Step 1 below.

---

Determine first: **new feature** or **modification**?

---

## New Feature Flow

### Step 1 — Read plan file + clarify

**Pre-entry git check** — run before any other work:

```bash
git status --porcelain
```

If dirty working tree (non-empty output): `[BLOCKED] dirty working tree — commit or stash changes first`

If `CLAUDE_PLAN_FILE` is set and the file does not yet exist, create the skeleton plan file now (before any `plan-file.sh` command that requires it):

```bash
if [ -n "$CLAUDE_PLAN_FILE" ] && [ ! -f "$CLAUDE_PLAN_FILE" ]; then
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" init "$CLAUDE_PLAN_FILE"
fi
```

Read `plans/{slug}.md` if it exists (resume context after `/compact`).

- `Glob` `src/features/` to find reusable existing features
- `Glob` `docs/` and `Read` any `docs/*.md` that exist — these are the SOT for domain knowledge
- `Read` `features/*/spec.md` for any features that may be reused (signatures and behaviour, not implementation)

If `docs/` is empty or absent: `[BLOCKED] docs/ is empty — create at least one docs/{concept}.md before re-running`

After docs/ is present, write or update `docs/{concept}.md` (same template as initializing-project Step 3). This must happen before writing-spec runs — critics use docs/*.md as the contradiction SOT.

If `docs/requirements/{name}.md` already exists: treat the file as the complete and approved requirement.

If `docs/requirements/{name}.md` does **not** exist: `[BLOCKED] docs/requirements/{name}.md not found — write the requirement file before re-running`

### Step 2 — Decompose

Classify each candidate per @reference/layers.md (Small / Large feature). Name format per @reference/layers.md §Naming conventions.

If proposing domain rules or constraints not found in `docs/*.md`: mark the assumption `[UNVERIFIED CLAIM]` in the plan file and include it provisionally; critic-spec will independently flag unverified claims in the spec.

List each candidate with layer assignment. Write decomposition to plan file. Proceed to Step 3.

### Step 3 — Write output + create branch

After decomposition, create `docs/requirements/{name}.md`:

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

Set plan file phase:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" brainstorm \
  "decomposition approved — starting brainstorm phase"
```

### Step 4 — Run critic-feature (max 2 iterations)

```
Skill("critic-feature", "Review docs/requirements/{name}.md. Original requirement: [paste requirement].")
```

Max-2 iteration guard and `[BLOCKED] final:` behavior per `@reference/critics.md §Brainstorm exception`. On REJECT-PASS, skip `clear-converged`.

The verdict is auto-recorded in `## Critic Verdicts` by the SubagentStop hook when critic-feature stops.

---

## Modification Flow

### Step 1 — Identify impact

- `Read` relevant `docs/requirements/*.md` and `docs/*.md`
- `Glob` `src/features/` and `src/domain/`
- `Read` `features/*/spec.md` for any features affected by the modification

Do not read `src/` implementation. If the modification conflicts with `docs/*.md`, list required doc updates. Write impact list to plan file. Proceed to Step 2.

### Step 2 — Update docs (if needed)

Update affected `docs/*.md` (SOT) before proceeding.

### Step 3 — Write output + run critic-feature

Create `docs/requirements/{name}.md`. Apply the same git pre-check as New Feature Flow Step 3. Run critic-feature with the same max-2 iteration guard.

---

## Hard Stop

Do not move to `writing-spec` until:
- Every feature has a `{verb}-{noun}` name
- Every feature is classified as small or large with layer assignment
- critic-feature returns PASS (or user has approved manual override after 2 iterations)
