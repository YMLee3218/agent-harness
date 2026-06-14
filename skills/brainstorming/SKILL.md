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
- Phase `done`: proceed normally (new feature after previous feature is complete). If `CLAUDE_PLAN_FILE` is set to the completed (done) plan, ignore it — treat `CLAUDE_PLAN_FILE` as unset and derive a fresh slug from the new feature name. Do not reuse the done plan file for the new feature.
- No plan file (CLAUDE_PLAN_FILE unset or file does not exist): proceed normally — Step 1 initialises it.
- Any other phase: `[BLOCKED:env] brainstorming: unexpected-phase — entered from {phase}; finish the current feature first, or unset CLAUDE_PLAN_FILE to start a fresh plan for the new feature`.

**Pre-entry git check** — run before any other work:

```bash
git status --porcelain
```

If dirty working tree (non-empty output): `[BLOCKED:env] brainstorming: dirty-working-tree — commit changes first`

If `CLAUDE_PLAN_FILE` is unset, derive a slug from the feature name (kebab-case, max 30 chars) and use `$PROJECT_DIR/plans/{slug}.md` as the plan path throughout. If the plan file (from `CLAUDE_PLAN_FILE` or derived) does not yet exist, run `bash "$PROJECT_DIR/.claude/scripts/plan-file.sh" init "$PROJECT_DIR/plans/{slug}.md"` before any other `plan-file.sh` command.

Read `plans/{slug}.md` if it exists (resume context after `/compact`).

- `Glob` `src/features/` to find reusable existing features
- `Glob` `docs/` and `Read` any `docs/*.md` that exist — these are the SOT for domain knowledge
- `Read` `features/*/spec.md` for any features that may be reused (signatures and behaviour, not implementation)

If `docs/` is empty or absent: `[BLOCKED:spec] brainstorming: no-docs — create at least one docs/{concept}.md before re-running`

After docs/ is present, write or update `docs/{concept}.md` (same template as initializing-project Step 3). This must happen before writing-spec runs — critics use docs/*.md as the contradiction SOT.

If `docs/requirements/{name}.md` already exists: treat the file as the complete and approved requirement.

If `docs/requirements/{name}.md` does **not** exist: proceed — Step 3 will create it from the user's feature request.

### Step 2 — Decompose

Classify each candidate as Small or Large feature per @reference/layers.md §Feature size classification. Name format per @reference/layers.md §Naming conventions.

Do NOT assign code or concepts to `domain/` or `infrastructure/` — those are architectural decisions made by writing-spec. Naming infrastructure dependencies in the compose graph (`calls infrastructure: {infra-component}`) is required for large features and does not constitute a layer assignment.

If proposing domain rules or constraints not found in `docs/*.md`: mark the assumption `[UNVERIFIED CLAIM]` in the plan file and include it provisionally; critic-spec will independently flag unverified claims in the spec.

**Entry-point / internal classification (required for each candidate)**

Declare each candidate as `entry-point` or `internal`:
- `entry-point`: at least one external invocation source named in `docs/requirements/*.md` or plan text (scheduler, HTTP request, user trigger, message queue). Quote the source verbatim (e.g. "invoked via /schedule per docs/requirements/X.md:42"). Cannot classify as entry-point if no external source is named.
- `internal`: at least one other candidate invokes it (visible in the compose graph).
- Neither: `[BLOCKED:spec] brainstorming: classification-indeterminate — {name} has no named external source and no compose-graph caller`.

**Operating Envelope (required for each candidate before Step 3)**

For each candidate feature, declare all 6 axes in the plan file:

Legal axes and values: `@reference/operating-envelope.md §Axis table`

| Axis | Value |
|------|-------|
| Actors | {1 user \| N users \| tenants \| concurrent instances} |
| Frequency | {one-shot \| periodic 1/min \| per-request \| bursty} |
| Concurrency | {none \| reader-writer \| multi-writer \| exclusive-writer} |
| Persistence | {ephemeral \| best-effort \| durable \| zero-loss} |
| Failure model | {crash-stop \| crash-recover \| partial-failure} |
| External I/O | {none \| file \| network \| distributed} (compound: comma-separated when feature touches multiple surfaces, e.g. `network, file`) |

For `internal` features: leave **Frequency** and **Concurrency** blank — mark as `(propagated)`. Fill computed values in the Propagation sub-step below. Declare all other axes normally.

**Enum verbatim rule**: use each axis value **exactly as written** in `operating-envelope.md §Axis table` — no paraphrasing, no sub-variants (e.g. `full multi-writer` is not `multi-writer`; `reader/writer` is not `reader-writer`; `disk` is not `file`). If a synonym maps to an existing enum value, write the enum value, not the synonym.

If an axis cannot be determined: write `[BLOCKED:spec] brainstorming: ambiguous — axis {name} cannot be determined` and add it to `## Open Questions`. Do not proceed to Step 3 until all axes are declared or the block is resolved.

If no enum value covers the feature's meaning (genuine semantic gap, not a wording variant): do **not** invent a new value. Instead write to `## Open Questions`:
```
[BLOCKED:harness] brainstorming: reference-extension — axis {name} has no value covering {meaning}; proposed addition: '{value}' ({rationale}). Feature: {slug}.
```
This is distinct from the `ambiguous` block above (which means the feature semantics are unclear, not that the enum is missing a category). Clearance is the same as all `[BLOCKED:harness]` markers: human-must, via `plan-file.sh unblock`.

**Propagation sub-step (run after all candidates are classified and compose graph is closed)**

For each `internal` feature, compute:
- `Frequency = max(callers' Frequency)` using the partial order `one-shot < periodic 1/min < per-request < bursty`.
- `Concurrency = max(callers' Concurrency)` using `none < exclusive-writer < reader-writer < multi-writer`.

If the caller chain contains no entry-point ancestor: `[BLOCKED:spec] brainstorming: compose-graph-open — internal feature {name} has no entry-point ancestor`.

Fill computed values into the envelope table with annotation `{value} (propagated from: {caller list})`.

List each candidate as small or large with its envelope. Write decomposition to plan file. Proceed to Step 3.

### Step 3 — Write output + create branch

If `docs/requirements/{name}.md` does not already exist, create it:

```markdown
# {Requirement Name}

## Business Goal
{One sentence}

## Small Features
- `{verb}-{noun}`: {description}

## Large Features
- `{verb}-{noun}` (entry-point|internal):
  - composes: {feature-a}, {feature-b}
  - calls infrastructure: {infra-component}

## Reused Existing Features
- {list or "none"}

## Out of Scope
- {explicitly excluded items}
```

Pre-branch checks:

| Condition | Action |
|-----------|--------|
| Not a git repo (`git rev-parse --git-dir` fails) | Append `[BLOCKED:env] brainstorming: not-a-git-repo — run git init before brainstorming` to `## Open Questions` and stop |
| Branch already exists (`git show-ref --verify refs/heads/feature/{name}` succeeds) | Log `[INFO] branch feature/{name} already exists — reusing` to `## Open Questions` and run `git checkout feature/{name}` |

Then (if not already on the branch): `git checkout -b feature/{name}`

Set plan file phase (skip if already in `brainstorm` — do not re-transition to the same phase; see `@reference/phase-ops.md §Skill phase entry`). In autonomous mode, the plan is typically already in `brainstorm` from a prior interactive run, so this call is a no-op guard. In interactive use, Ring B requires `CLAUDE_PLAN_CAPABILITY=harness`; if the call fails with a capability error, run from a human terminal:
```bash
_boot=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || _boot="${CLAUDE_PROJECT_DIR:-$(pwd)}"
source "$_boot/.claude/scripts/lib/run-context.sh" && _resolve_project_dir
export CLAUDE_PLAN_CAPABILITY=harness
bash "$PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$PROJECT_DIR/plans/{slug}.md" brainstorm \
  "decomposition approved — starting brainstorm phase"
```

---

## Modification Flow

### Step 1 — Identify impact

- `Read` relevant `docs/requirements/*.md` and `docs/*.md`
- `Glob` `src/features/` and `src/domain/`
- `Read` `features/*/spec.md`, `domain/*/spec.md`, and `infrastructure/*/spec.md` for any specs of components affected by the modification

Do not read `src/` implementation. If the modification conflicts with `docs/*.md`, list required doc updates. Write impact list to plan file. Proceed to Step 2.

### Step 2 — Update docs (if needed)

Update affected `docs/*.md` (SOT) before proceeding.

### Step 3 — Write output

If `docs/requirements/{name}.md` does not already exist, create it. Apply the same git pre-check as New Feature Flow Step 3.

Set phase to `brainstorm` (skip if already in `brainstorm` — do not re-transition to the same phase). Ring B requires `CLAUDE_PLAN_CAPABILITY=harness`; if the call fails, run from a human terminal:
```bash
_boot=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || _boot="${CLAUDE_PROJECT_DIR:-$(pwd)}"
source "$_boot/.claude/scripts/lib/run-context.sh" && _resolve_project_dir
export CLAUDE_PLAN_CAPABILITY=harness
bash "$PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$PROJECT_DIR/plans/{slug}.md" brainstorm \
  "re-brainstorming"
```

---

## Hard Stop

Do not move to `writing-spec` until:
- Feature names comply with `@reference/layers.md §Naming conventions`
- Every feature is classified as small or large (no layer assignment — writing-spec's responsibility)
- Plan file `plans/{slug}.md` exists with Phase `brainstorm`
- Operating Envelope declared for all candidate features in the plan file (all 6 axes have concrete values — no `{placeholder}` curly-brace syntax remaining)
- Compose graph is closed (every `internal` feature has at least one caller) and all internal features' Frequency/Concurrency axes are filled with propagated values (no `(propagated)` placeholder remains)
