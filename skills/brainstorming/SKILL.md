---
name: brainstorming
description: >
  Decomposes requirements into VSA features and DDD domain concepts before any spec or code is written. Trigger whenever the user mentions a new feature, requirement, or anything to build — even casual phrasing like "I want to add X", "we need Y", "let's build Z". Also trigger for modification requests: "change X", "update Y", "fix the behaviour of Z". Always run this before writing-spec.
---

# Brainstorming Workflow

Determine first: is this a **new feature** or a **modification**?

---

## New Feature Flow

### Step 1 — Clarify

Use `EnterPlanMode`, then `Glob` `features/` to find reusable existing features.

Use `AskUserQuestion` to resolve ambiguity — at most three questions per turn:
- "What does success look like?"
- "What external systems or events are involved?"
- "What are the failure cases?"

Stay in plan mode. Do not proceed to Step 2 until behaviour, conditions, and outcomes are clear.

### Step 2 — Decompose

Classify each candidate:

```
Small feature = calls one or a few domains; single responsibility
Large feature = composes small features into a higher-level flow
```

Name format: Features: `{verb}-{noun}` kebab-case. Domain concepts: `{noun}` singular kebab-case.

List each candidate with its layer assignment.

Write the decomposition to the plan file. Call `ExitPlanMode` to request approval.

### Step 3 — Write Output and Create Branch

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

Before creating the feature branch, check for these conditions and use `AskUserQuestion` if any apply:
- **Not a git repo**: `git rev-parse --git-dir` fails → ask the user whether to initialise one first.
- **Dirty working tree**: `git status --porcelain` returns changes → ask whether to stash or commit before branching.
- **Branch already exists**: `git show-ref --verify refs/heads/feature/{name}` succeeds → ask whether to reuse or choose a different name.

Then create the feature branch:

```bash
git checkout -b feature/{name}
```

### Step 4 — Run critic-feature

```
Task(
  subagent_type: "critic-feature",
  prompt: "Review docs/requirements/{name}.md.
           Original requirement: [paste requirement]."
)
```

If Critic returns FAIL:
1. Output the full verdict to the user
2. Write a fix plan (reclassifications, renamed features, missing features to add)
3. Use `AskUserQuestion` to confirm the fix plan before editing
4. Apply fixes with `Edit`
5. Re-run `critic-feature` via `Task` with the same requirements doc and original requirement

---

## Modification Flow

### Step 1 — Identify Impact

Use `EnterPlanMode`, then:
- `Read` relevant `docs/requirements/*.md`
- `Read` relevant `docs/*.md` — domain knowledge (SOT)
- `Glob` to list `features/` and `domain/` directories

Do not read implementation code — read `docs/` only.

Check whether the modification conflicts with existing `docs/*.md`:
- If the requirement changes domain rules documented in `docs/*.md`, those docs must be updated first (SOT).
- List which `docs/*.md` files need updating and what changes are required.

Use `AskUserQuestion` if the scope of change is unclear.

Write impact list to plan file. Include any required `docs/*.md` updates. Call `ExitPlanMode` to request approval.

### Step 2 — Update Docs (if needed)

If Step 1 identified `docs/*.md` conflicts, update the affected `docs/*.md` files first (SOT).

### Step 3 — Write Output and Run critic-feature

Create `docs/requirements/{name}.md` with the impact list.

Apply the same git pre-check (not a git repo / dirty tree / branch exists) from New Feature Flow Step 3 before running:

```bash
git checkout -b feature/{name}
```

Then run:

```
Task(
  subagent_type: "critic-feature",
  prompt: "Review docs/requirements/{name}.md.
           Original requirement: [paste requirement]."
)
```

If Critic returns FAIL, apply the same fix loop as New Feature Flow Step 4.

---

## Hard Stop

Do not move to `writing-spec` until:
- Every feature has a verb-noun name
- Every feature is classified as small or large
- Layer assignment is stated for each
- User has approved via `ExitPlanMode`
- `critic-feature` returns PASS
