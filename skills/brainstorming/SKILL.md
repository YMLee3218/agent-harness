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

Layer rules: @reference/layers.md

## Step 0 — Detect uninitialized project (autonomous pre-check)

Before branching into new feature or modification, check whether the project has been initialized:

```
Glob("src/**")
```

If `src/` does not exist (Glob returns no results):
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

| Condition | Interactive | Non-interactive (`CLAUDE_NONINTERACTIVE=1`) |
|-----------|-------------|---------------------------------------------|
| Dirty working tree (non-empty output) | `AskUserQuestion` — "Working tree has uncommitted changes. Commit or stash before brainstorming?" | Append `[BLOCKED] dirty working tree — commit or stash changes first` to `## Open Questions` and stop |

Read `plans/{slug}.md` if it exists (resume context after `/compact`).

Use `EnterPlanMode`, then:
- `Glob` `src/features/` to find reusable existing features
- `Glob` `docs/` and `Read` any `docs/*.md` that exist — these are the SOT for domain knowledge
- `Read` `features/*/spec.md` for any features that may be reused (signatures and behaviour, not implementation)

If `docs/` is empty or absent:
- **Interactive mode**: use `AskUserQuestion` — "No docs/*.md found. What are the core domain rules and concepts for this feature? I'll create docs/{concept}.md before writing specs."
- **Non-interactive mode** (`CLAUDE_NONINTERACTIVE=1`): append `[BLOCKED] docs/ is empty — create at least one docs/{concept}.md before re-running` to `## Open Questions` in the plan file, then stop.

After collecting the answer (interactive) or when docs/ is present, write or update `docs/{concept}.md` (same template as initializing-project Step 3). This must happen before writing-spec runs — critics use docs/*.md as the contradiction SOT.

If `docs/requirements/{name}.md` already exists and `CLAUDE_NONINTERACTIVE=1`:
- Skip ambiguity questions below; treat the file as the complete and approved requirement.

Otherwise use `AskUserQuestion` to resolve requirement ambiguity — at most three questions:
- "What does success look like?"
- "What external systems or events are involved?"
- "What are the failure cases?"

### Step 2 — Decompose

Classify each candidate per @reference/layers.md (Small / Large feature). Name format: `{verb}-{noun}` kebab-case. Domain concepts: `{noun}` singular kebab-case.

If proposing domain rules or constraints not found in `docs/*.md`, do not assume them.
- **Interactive**: use `AskUserQuestion` to confirm with the user before including in the decomposition.
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): mark the assumption `[UNVERIFIED]` in the plan file and include it provisionally; critic-spec will flag it if wrong.

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

Pre-branch checks:

| Condition | Interactive | Non-interactive (`CLAUDE_NONINTERACTIVE=1`) |
|-----------|-------------|---------------------------------------------|
| Not a git repo (`git rev-parse --git-dir` fails) | `AskUserQuestion` | Append `[BLOCKED] not a git repository` to `## Open Questions` and stop |
| Branch already exists (`git show-ref --verify refs/heads/feature/{name}` succeeds) | `AskUserQuestion` | Log `[INFO] branch feature/{name} already exists — reusing` to `## Open Questions` and run `git checkout feature/{name}` |

Then (if not already on the branch): `git checkout -b feature/{name}`

Set plan file phase:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" brainstorm
```

### Step 4 — Run critic-feature (max 2 iterations)

**Brainstorm exception** — `critic-feature` uses a max-2 iteration guard rather than the convergence protocol in `@reference/critic-loop.md`. All other phase-gate critics and pr-review use the full convergence protocol.

```
Skill("critic-feature", "Review docs/requirements/{name}.md. Original requirement: [paste requirement].")
```

**Iteration counter starts at 1.**

If Critic returns FAIL:
1. Output the full verdict
2. Write a fix plan (reclassifications, renames, missing features)
3. Confirm the fix plan:
   - **Interactive**: use `AskUserQuestion`
   - **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): apply the fix plan immediately without asking
4. Apply fixes with `Edit`
5. If iteration < 2: increment counter, re-run Skill("critic-feature"). Else:
   - **Interactive**: use `AskUserQuestion` — "critic-feature has failed twice. Paste the latest verdict for manual review, or describe how to proceed."
   - **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): append `[BLOCKED-FINAL] critic-feature failed twice — manual review required` to `## Open Questions` and stop.

Append verdict to plan file `## Critic Verdicts`:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-verdict "plans/{slug}.md" "brainstorm/critic-feature: {PASS|FAIL}"
```

---

## Modification Flow

### Step 1 — Identify impact

Use `EnterPlanMode`, then:
- `Read` relevant `docs/requirements/*.md` and `docs/*.md`
- `Glob` `src/features/` and `src/domain/`
- `Read` `features/*/spec.md` for any features affected by the modification

Do not read `src/` implementation. If the modification conflicts with `docs/*.md`, list required doc updates. Write impact list to plan file. Call `ExitPlanMode`.

In **non-interactive mode** (`CLAUDE_NONINTERACTIVE=1`): `ExitPlanMode` is auto-approved; proceed without waiting for user confirmation.

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
