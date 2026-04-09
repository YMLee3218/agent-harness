# Harness Rationale — Anthropic Source Mapping

This file maps every major harness decision to the Anthropic document that motivates it.
Links are listed first so a downstream reader can verify the primary source.

## Authoritative sources

1. **Building Effective Agents** — engineering blog post on workflow patterns, tool design, and the simplicity principle.
2. **Writing Tools for Agents** — tool description quality, namespacing, error messages, and eval-driven iteration.
3. **Multi-Agent Research System** — orchestrator-worker architecture, context isolation, parallelisation, checkpoint strategy.
4. **Claude Code Documentation** — skills, subagents, hooks, plan mode, TDD enforcement, model cost routing.

## Decision → source mapping

| Harness decision | Source | Rationale |
|---|---|---|
| Hook-enforced phase gate (PreToolUse write block) | Building Effective Agents — "hooks/code enforce invariants; prompts cannot" | Prompts are advisory; a phase-gate hook is the only reliable write barrier |
| Evaluator-optimizer critic loop (max 2 iter) | Building Effective Agents — evaluator-optimizer pattern | Measurable improvement loop with escape hatch on stale iteration |
| Orchestrator-workers: `implementing` → coder subagents | Building Effective Agents — orchestrator-workers pattern; Multi-Agent Research | Lead LLM delegates, each worker isolated to one task; enables parallelisation |
| External plan file FSM (`plans/{slug}.md`) | Multi-Agent Research — external state for context handoff | Survives `/compact`, session restart, and worktree switches |
| Critic tool allowlists (minimal surface; Bash restricted to read-only git/grep dispatchers) | Building Effective Agents — "minimal tool surface" | Critics must not mutate state; critic-test and critic-code use Bash only for read-only git log and language-specific grep dispatchers |
| Model routing: two-tier (see table below) | Claude Code Docs — cost-aware model routing (40-50% savings) | Pattern classification is cheap; semantic judgment requires stronger reasoning |
| Category-aware FAIL escalation (consecutive same-category → human) | Building Effective Agents — evaluator-optimizer valid only when measurable improvement exists | Same-category repeated FAIL signals the loop cannot converge; human required |
| Verdict HTML marker (`<!-- verdict: X -->`) machine-parsed by hook | Claude Code Docs — SubagentStop hook payload | Structured output allows automation without fragile regex on prose |
| `running-dev-cycle` profiles (trivial/patch/feature/greenfield) | Building Effective Agents — "use simplest path; add complexity only when needed" | Single 6-phase FSM for a comment fix is over-engineering; profiles match cost to task |
| Task ledger in plan file | Multi-Agent Research — checkpoint system for long-running tasks | Enables `--resume` and debugging without replaying full git log |
| Parallel coder subagents for independent tasks | Multi-Agent Research — parallel subagents for 90% time reduction | Tasks in the same layer with no dependencies can be spawned in one turn |
| Lang lint (LLM-facing = English) | Claude Code Docs — model performance is best in English | Prompts seen only by Claude use English; user-visible output uses the project locale |
| `context7-plugin` for library API verification | Writing Tools for Agents — verify tool descriptions against actual API docs | External library docs change; context7 fetches current docs before use |
| Skill routing eval (`eval/fixtures/` + `eval/expected/`) | Writing Tools for Agents — eval-driven tool/skill iteration | Skill description quality is measurable; fixtures make regressions detectable |

| `feat(*)` / `refactor(*)` / `fix(*)` commits pre-approved in `settings.json` | — | Green phase produces `feat(...)` commits; Refactor phase produces `refactor(...)` commits. Without pre-approval these fell to the `ask` bucket on every commit, interrupting automated pipeline runs. `--no-verify` remains in the deny list regardless of prefix. |

### Model routing tiers

Current model IDs (2026-04): Opus 4.6 (`claude-opus-4-6`), Sonnet 4.6 (`claude-sonnet-4-6`), Haiku 4.5 (`claude-haiku-4-5-20251001`). Skill frontmatter uses alias keys (`haiku`, `sonnet`, `opusplan`) rather than full IDs; the alias table is resolved by Claude Code at runtime.

| Tier | Model | Critics / roles | Rationale |
|------|-------|-----------------|-----------|
| **Tier 1 — pattern classification** | Haiku 4.5 | `critic-feature`, `critic-spec` | Feature decomposition and BDD structure checks are pattern-matching tasks; Haiku is sufficient and ~4× cheaper than Sonnet |
| **Tier 2 — semantic judgment** | Sonnet 4.6 | `critic-test`, `critic-code`, `coder` | Test integrity, spec compliance, and implementation generation require deeper reasoning; savings from Haiku here are outweighed by error rate |

### Why the `implementing` skill does not delegate to the bundled `/batch` skill

Claude Code ships a bundled `/batch` skill that distributes tasks across git worktrees in parallel — the same parallelisation mechanism `implementing` uses internally. The harness does **not** delegate to `/batch` because:

1. **Phase FSM integrity**: `/batch` has no knowledge of the brainstorm → spec → red → green → refactor → integration → done FSM. It would write source files regardless of which phase the plan file is in, bypassing the PreToolUse phase-gate.
2. **Red-anchor commit contract**: `writing-tests` commits all tests under `test(red): {slug}` before any implementation begins. `critic-test` uses this commit SHA to detect post-Red test modifications. `/batch` does not emit `test(red):` commits, breaking the integrity check.
3. **Critic-test gate**: `implementing` waits for `critic-test PASS` before spawning coder subagents. `/batch` has no awareness of the critic loop and would proceed unconditionally.

**Bundled skill name collisions**: The bundled skills `/batch`, `/simplify`, `/debug`, and `/loop` do not conflict with any harness skill names (`brainstorming`, `writing-spec`, `writing-tests`, `implementing`, `critic-*`, `running-*`, `initializing-project`). Downstream projects may use bundled skills freely alongside harness skills.

### Recommended user-side settings (personal `~/.claude/settings.json`)

- **`"model": "opusplan"`** — routes planning interactions to Opus 4.6 for deeper architectural reasoning. Use `/plan <description>` to enter plan mode immediately with a task description pre-loaded, or `/model` in-session to switch models.
- **Stop hook + PermissionRequest hook** — see harness CLAUDE.md § Prerequisites.

## Canonical hook schemas (verified against code.claude.com/docs/en/hooks)

### SubagentStop payload fields
| Field | Notes |
|-------|-------|
| `session_id` | Parent session identifier |
| `transcript_path` | Full parent session transcript (JSONL) |
| `agent_transcript_path` | Subagent-only transcript under `subagents/` — prefer this for critic verdict extraction (no cross-critic contamination) |
| `agent_type` | Agent name string (e.g. `"critic-spec"`, `"Explore"`) |
| `last_assistant_message` | Subagent's final response text |
| `cwd` | Working directory |
| `permission_mode` | Active permission mode |
| `hook_event_name` | Always `"SubagentStop"` |
| `stop_hook_active` | Boolean |
| `agent_id` | Subagent identifier |

Fields **not** in the SubagentStop payload: `subagent_type`, `tool_response`. Fallback branches for these were removed; verified absent in `scripts/plan-file.sh`.

### PostToolUseFailure (Write|Edit) → post-edit-failure.sh
Successful Write/Edit failures (permissions, bad paths) left no trace in the plan file. `PostToolUseFailure` fills the gap: the script is advisory (exit 0 always) and appends a `[TOOL-FAIL]` entry to `## Open Questions` so the next session can surface unresolved write errors. Does not use exit 2 — a failed write record must never block recovery.

### SessionEnd → flush-on-end
`PreCompact` and `StopFailure` already preserve plan state, but normal session exit (`/exit`, terminal close) had no flush point. `SessionEnd` covers the gap by appending a `[SESSION-END]` marker, ensuring every exit path leaves an audit trail. Exit 0 always; no active plan → silent skip.

### SubagentStart (critic-.*) → record-critic-start
`SubagentStop` records the verdict but not when the critic started or what phase it was evaluating. `SubagentStart` fills the gap by writing a timestamped `[START]` entry to `## Critic Runs` (separate from `## Critic Verdicts`). This enables latency analysis and ensures a dangling start without a matching verdict is detectable. Exit 0 always; non-critic agents and missing plans → silent skip.

### SessionStart hook output format
Scripts must emit the `hookSpecificOutput` wrapper to inject additional context:
```json
{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "..."}}
```
A flat top-level `{"additionalContext": "..."}` is silently ignored by the runtime. Plain stdout text is also accepted as a simpler alternative.

### SubagentStart/Stop matcher: explicit allow-list (P1)
Changed from `critic-.*` wildcard to `critic-feature|critic-spec|critic-test|critic-code`. Reason: a wildcard would trigger `record-critic-start` and `record-verdict` for any future `critic-helper` or other non-verdict subagent, causing incorrect plan file entries. Explicit list is safer; add new critics to both matchers deliberately.

### `refactor` phase removal (P2)
`refactor` was removed from `VALID_PHASES` and collapsed into `green`. Rationale (Simplicity principle): refactoring is in-place cleanup performed by `coder` subagents within the same Green cycle; elevating it to a separate FSM state added surface area without a gating critic or entry skill. `implementing/SKILL.md` now describes it as in-place refactoring within Green, and `set-phase ... refactor` is no longer called.

### Agent Teams: considered, not adopted
Agent Teams (multi-session parallel collaboration, `TeammateIdle` hook) were evaluated as a replacement for session-scoped `implementing` orchestration. The current single-session orchestrator-workers pattern is sufficient for the harness use case; Agent Teams add cross-session state management complexity without a commensurate gain. Revisit when features require persistent parallel sub-sessions.

### TaskCreated/TaskCompleted/PermissionDenied hooks (P3)
Three hooks added to auto-sync plan state:
- `TaskCreated` → `record-task-created`: registers native TaskCreate calls in the Task Ledger (layer="-"; implementing skill provides the correct layer).
- `TaskCompleted` → `record-task-completed`: marks the matching Task Ledger row `completed`.
- `PermissionDenied` → `record-permission-denied`: appends a `[PERMISSION-DENIED]` note to Open Questions for next-session review.
Payload fields verified against `code.claude.com/docs/en/hooks` (2026-04): `task_id`, `task_subject` for task hooks; `tool_name`, `reason` for PermissionDenied.
