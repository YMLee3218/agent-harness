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

| Tier | Model | Critics / roles | Rationale |
|------|-------|-----------------|-----------|
| **Tier 1 — pattern classification** | Haiku | `critic-feature`, `critic-spec` | Feature decomposition and BDD structure checks are pattern-matching tasks; Haiku is sufficient and ~4× cheaper than Sonnet |
| **Tier 2 — semantic judgment** | Sonnet | `critic-test`, `critic-code`, `coder` | Test integrity, spec compliance, and implementation generation require deeper reasoning; savings from Haiku here are outweighed by error rate |

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

### SessionStart hook output format
Scripts must emit the `hookSpecificOutput` wrapper to inject additional context:
```json
{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "..."}}
```
A flat top-level `{"additionalContext": "..."}` is silently ignored by the runtime. Plain stdout text is also accepted as a simpler alternative.
