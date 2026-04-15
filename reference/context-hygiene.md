# Context Hygiene

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

## Context budget management

Claude Code tracks token usage from API responses and triggers `/compact` automatically before the ceiling is reached. The PreCompact and PostCompact hooks flush and restore plan state across the compaction boundary.

**Proactive flush triggers** — flush to the plan file before the system compacts, not after:

| Signal | Action |
|--------|--------|
| About to spawn 3+ coder subagents | Flush all open architectural decisions to `## Open Questions` first |
| Completed a full layer tier (all domain tasks done) | Write a `## Phase Transitions` checkpoint entry |
| Critic just returned a verdict | Append to `## Critic Verdicts` immediately (don't defer) |
| An `in_progress` task is about to be handed off to a subagent | Ensure the Task Ledger entry is written before spawning |

**Session length heuristic for autonomous runs**: if the implementing skill has more than 8 pending tasks, consider splitting the feature into two sequential plan files (parent/child plan pattern described in Long Refactors above) rather than running all tasks in one session. Long sessions with many sequential tool calls accumulate context faster than parallel runs with isolated subagents.

**Do not**: read implementation files "just in case" between tasks; rely on in-context recall of file contents across more than 2–3 turns (re-read from disk instead); pass full file contents to coder subagents when a path + line range is sufficient.
