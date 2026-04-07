---
name: brainstorming
description: >
  Brainstorm/decompose new features into VSA Small/Large features and DDD domain concepts.
  Trigger: "build X", "add Y", "need Z", "만들자", "추가", "feature", or any new-functionality phrasing.
  Decomposes requirements before any spec or code is written.
  Always run before writing-spec. For brand-new repos, run initializing-project first.
---

# Brainstorming Workflow

Layer rules: @reference/layers.md

Determine first: **new feature** or **modification**?

---

## New Feature Flow

### Step 1 — Read plan file + clarify

Read `plans/{slug}.md` if it exists (resume context after `/compact`).

Use `EnterPlanMode`, then:
- `Glob` `src/features/` to find reusable existing features
- `Glob` `docs/` and `Read` any `docs/*.md` that exist — these are the SOT for domain knowledge
- `Read` `src/features/*/spec.md` for any features that may be reused (signatures and behaviour, not implementation)

If `docs/` is empty or absent, use `AskUserQuestion` before proceeding:
- "No docs/*.md found. What are the core domain rules and concepts for this feature? I'll create docs/{concept}.md before writing specs."

After collecting the answer, write or update `docs/{concept}.md` (same template as initializing-project Step 3). This must happen before writing-spec runs — critics use docs/*.md as the contradiction SOT.

Use `AskUserQuestion` to resolve requirement ambiguity — at most three questions:
- "What does success look like?"
- "What external systems or events are involved?"
- "What are the failure cases?"

### Step 2 — Decompose

Classify each candidate per @reference/layers.md (Small / Large feature). Name format: `{verb}-{noun}` kebab-case. Domain concepts: `{noun}` singular kebab-case.

List each candidate with layer assignment. Write decomposition to plan file. Call `ExitPlanMode` to request approval.

### Step 3 — Write output + create branch

After approval, create `docs/requirements/{name}.md`:

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

Pre-branch checks — use `AskUserQuestion` if any apply:
- Not a git repo: `git rev-parse --git-dir` fails
- Dirty working tree: `git status --porcelain` returns changes
- Branch already exists: `git show-ref --verify refs/heads/feature/{name}` succeeds

Then: `git checkout -b feature/{name}`

Set plan file phase:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" brainstorm
```

### Step 4 — Run critic-feature (max 2 iterations)

```
Skill("critic-feature", "Review docs/requirements/{name}.md. Original requirement: [paste requirement].")
```

**Iteration counter starts at 1.**

If Critic returns FAIL:
1. Output the full verdict
2. Write a fix plan (reclassifications, renames, missing features)
3. Use `AskUserQuestion` to confirm the fix plan
4. Apply fixes with `Edit`
5. If iteration < 2: increment counter, re-run Skill("critic-feature"). Else: use `AskUserQuestion` — "critic-feature has failed twice. Paste the latest verdict for manual review, or describe how to proceed."

Append verdict to plan file `## Critic Verdicts`.

---

## Modification Flow

### Step 1 — Identify impact

Use `EnterPlanMode`, then:
- `Read` relevant `docs/requirements/*.md` and `docs/*.md`
- `Glob` `src/features/` and `src/domain/`
- `Read` `src/features/*/spec.md` for any features affected by the modification

Do not read `src/` implementation. If the modification conflicts with `docs/*.md`, list required doc updates. Write impact list to plan file. Call `ExitPlanMode`.

### Step 2 — Update docs (if needed)

Update affected `docs/*.md` (SOT) before proceeding.

### Step 3 — Write output + run critic-feature

Create `docs/requirements/{name}.md`. Apply the same git pre-check as New Feature Flow Step 3. Run critic-feature with the same max-2 iteration guard.

---

## Hard Stop

Do not move to `writing-spec` until:
- Every feature has a `{verb}-{noun}` name
- Every feature is classified as small or large with layer assignment
- User has approved via `ExitPlanMode`
- critic-feature returns PASS (or user has approved manual override after 2 iterations)
