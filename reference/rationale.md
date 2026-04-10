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

### StopFailure payload field: `.error` / `.error_type`
The `StopFailure` hook payload uses `.error` for the failure reason in currently observed payloads. Valid values include `rate_limit`, `server_error`. `plan-file.sh record-stopfail` reads `.error_type // .error` (defensive fallback) and writes `error_type=<value>` to the `[STOPFAIL]` marker. Both field names are accepted; `.error_type` takes precedence if present.

### PreCompact payload field: `.trigger` / `.compaction_trigger`
The `PreCompact` hook payload uses `.trigger` for the compact reason in currently observed payloads. Valid values: `manual` | `auto`. `plan-file.sh flush-before-compact` reads `.compaction_trigger // .trigger` (defensive fallback) and writes `trigger=<value>` to the `[PRE-COMPACT]` marker. Both field names are accepted; `.compaction_trigger` takes precedence if present.

### SessionEnd payload field: `.reason` / `.session_end_reason`
The `SessionEnd` hook payload uses `.reason` for the exit reason in currently observed payloads. `plan-file.sh flush-on-end` reads `.session_end_reason // .reason` (defensive fallback) and writes `reason=<value>` to the `[SESSION-END]` marker. Both field names are accepted; `.session_end_reason` takes precedence if present.

### NotebookEdit tool_input field: `.notebook_path`
`NotebookEdit` sends the target notebook path as `.tool_input.notebook_path`, not `.tool_input.file_path` (which is the field used by Write/Edit). `phase-gate.sh` uses `.tool_input.file_path // .tool_input.notebook_path // empty` to handle both tools with a single extractor.

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

### Worktree isolation for coder subagents

`agents/coder.md` sets `isolation: worktree` so each parallel coder runs in its own git worktree. This prevents file-level conflicts when two coders write to different paths within the same feature tier simultaneously.

**Cross-worktree plan file writes**: coder agents do not write to the plan file directly (only the `implementing` orchestrator does). The `_awk_inplace` mkdir lock is safe across worktrees because `mkdir` is atomic on the underlying POSIX filesystem regardless of which worktree path is used. When `CLAUDE_PLAN_FILE` is set to an absolute path before spawning coders, all subagents reference the same physical file even from different working directories.

**Merging**: after each worktree-isolated coder returns, the `implementing` skill merges the coder's branch with `git merge --no-ff`. The merge commit SHA is recorded in the Task Ledger.

**Source**: Building Effective Agents — orchestrator-workers with context isolation; Multi-Agent Research — parallel subagents with worktree isolation for file safety.

### MCP tool write bypass (known limitation)

MCP server tools (e.g. a hypothetical `mcp__write_file`) are not matched by the `Write|Edit` PreToolUse hook. They bypass the phase gate entirely.

**Current risk**: the enabled plugins (`context7-plugin`, `pr-review-toolkit`, `code-simplifier`) expose only read-only tools. No currently-enabled MCP plugin can write source or test files, so the practical risk is negligible.

**Mitigation if a write-capable MCP plugin is added**: extend the `PreToolUse` matcher in `settings.json` to include the MCP tool name (e.g. `Write|Edit|mcp__plugin_name__write_file`). Each new write-capable MCP tool must be explicitly added — there is no wildcard MCP matcher.

### Settings schema fixes (C1, C2) and security hardening (H1, M1–M3, M5, L1, L2)

**C1 — `sandbox.enabled` (was `sandbox.enable`)**
`additionalProperties` is allowed in the settings JSON Schema, so the typo produced no validation error — the sandbox was silently disabled. Corrected to `"enabled": true`.

**C2 — `statusLine` object format**
The `statusLine` key requires `{"type":"command","command":"..."}` — a plain string is a schema mismatch and the status line did not render. Updated to the object form.

**H1 — force push deny expansion**
Original deny list only blocked `git push --force *` and `git push -f *`. Three uncovered patterns added:
- flag after remote/branch: `git push * --force`, `git push * -f` (and with trailing args)
- refspec force: `git push * +*`
- bare `-f` with no trailing args: `git push -f` (`*` matches 1+ chars, so the bare form was unblocked)

**M1 — sandbox filesystem denyRead**
Added `sandbox.filesystem.denyRead` mirroring the existing permission-level deny list for secret paths (`~/.ssh/**`, `~/.aws/**`, etc.). Defense-in-depth: permission rules apply to Claude's tool calls; sandbox filesystem rules apply at OS level.

**M2 — critic agent `disallowedTools`**
All four critic agents (critic-feature, critic-spec, critic-test, critic-code) gained `disallowedTools: Write, Edit, NotebookEdit`. Critics must never mutate state; this makes the constraint enforcement explicit at the agent layer rather than relying solely on minimal `tools:` declarations.

**M3 — `worktree.symlinkDirectories`**
Added `worktree.symlinkDirectories: [node_modules, .venv, .cache]`. Without this, worktree creation for coder subagents copies large dependency trees on every invocation. Symlinking these directories is safe because they contain no source files.

**M5 — `async: true` removed from PostToolUse lint hook**
The lint hook ran asynchronously, allowing Claude to proceed to reading a just-written file before formatting completed. Removing `async` makes lint synchronous: the file is stable before Claude continues.

**L1 — `user-invocable: false` on critic skills**
Critic skills are internal pipeline stages invoked by the orchestrator. Without `user-invocable: false` a user could bypass the FSM by calling `/critic-code` directly mid-spec. Now suppressed from the user-facing skill list.

**L2 — `attribution.commit`**
Commit co-authorship was previously injected ad-hoc by the `implementing` skill prompt. Setting `attribution.commit` in `settings.json` appends a `Co-Authored-By` trailer to every commit, guaranteeing consistent attribution regardless of which path produces a commit.

### TaskCreated/TaskCompleted/PermissionDenied hooks (P3)
Three hooks added to auto-sync plan state:
- `TaskCreated` → `record-task-created`: registers native TaskCreate calls in the Task Ledger (layer="-"; implementing skill provides the correct layer).
- `TaskCompleted` → `record-task-completed`: marks the matching Task Ledger row `completed`.
- `PermissionDenied` → `record-permission-denied`: appends a `[PERMISSION-DENIED]` note to Open Questions for next-session review.
Payload fields verified against `code.claude.com/docs/en/hooks` (2026-04): `task_id`, `task_subject` for task hooks; `tool_name`, `reason` for PermissionDenied.
