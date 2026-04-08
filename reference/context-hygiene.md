# Context Hygiene

Harness-specific application of the Anthropic Context Engineering guide (2025-2026).

## The four pillars (harness mapping)

| Pillar | How the harness applies it |
|--------|---------------------------|
| **Write** — put information in context deliberately | Skills inject only what is needed: plan file excerpt, relevant spec, target file list. No full-repo dumps. |
| **Select** — choose the right information | `plan-file.sh context` (SessionStart hook) injects active plan phase + last 3 verdicts + open questions — not the full plan. |
| **Compress** — summarise before context fills | Before `/compact`, flush critical decisions to `## Open Questions` or `## Phase Transitions` in the plan file (see below). |
| **Isolate** — fork context for independent tasks | `critic-*` skills run as subagents (forked context). Coder subagents spawned by `implementing` each receive only their task prompt. |

## Pre-compact flush

The plan file is external memory that survives `/compact` and session restarts. Before compacting:

1. Append any unresolved architectural decisions to `## Open Questions`.
2. Append phase transition rationale to `## Phase Transitions`.
3. Record pending task state in `## Task Ledger` (via `plan-file.sh update-task`).

After `/compact` the SessionStart hook re-injects the plan summary automatically.

## Subagent spawn heuristic

Spawn a subagent (via `Agent(...)`) when:
- Exploring 10+ files in isolation, **or**
- Running 3+ independent tasks that do not share mutable state.

Do not spawn subagents for single-file lookups or sequential dependent steps.

## Long refactors

Break long refactors into phase-scoped sub-plans:
- Parent plan = index (one row per sub-feature, status column).
- Child plan = FSM with its own brainstorm → done lifecycle.
- Parent phase advances only when all child plans reach `done`.

## Context rot patterns to avoid

| Pattern | Mitigation |
|---------|-----------|
| Stale tool results re-read in every turn | Read files once; pass content to subagents directly |
| Full plan file injected every turn | SessionStart hook injects a compressed summary only |
| Critic output leaking into next critic's context | Each critic runs as a forked subagent; transcripts are isolated |
| Implementation details from prior phases polluting green phase | Coder subagents receive only task prompt + failing test + spec path |
