# Critics

> Single source for: verdict format, critic blocking rules, convergence policy, branching priority, review execution rules, running critics, blocked-state procedures. Phase ops: `@reference/phase-ops.md`. Ultrathink audit: `@reference/ultrathink.md`.

Severity rules: @reference/severity.md
Layer rules: @reference/layers.md
Language and verdict-marker language: @reference/language.md

Use only the explicit file list from the prompt. Do not derive paths from git history.

If invoked outside the `{name}` skill context (no parent skill orchestrating this run), refuse: output "ERROR: {name} must be invoked via the /{name} skill, not directly." and stop. (`{name}` = this agent's `name` field from its frontmatter.)

## §Verdict format

Severity levels, PASS/FAIL threshold, category priority, and finding labels: `@reference/severity.md` (single source of truth — do not duplicate here).

Every critic **must** end its output with a `### Verdict` section containing the HTML markers shown below. Output that does not contain these markers is recorded as `PARSE_ERROR` in the plan file. (The parser accepts the last occurrence of the markers anywhere in the transcript — trailing text after the markers does not cause a PARSE_ERROR, but critics should still place markers at the end for clarity.)

**PASS**
```
### Verdict
PASS
<!-- verdict: PASS -->
<!-- category: NONE -->
```
(`<!-- category: NONE -->` is conventional on PASS — include it as shown. A non-NONE category on PASS is a `PARSE_ERROR`; omitting the category marker entirely on PASS is also accepted by the parser.)

**FAIL**
```
### Verdict
FAIL — {comma-separated list of blocking finding labels}
<!-- verdict: FAIL -->
<!-- category: {highest-priority category} -->
```

A **FAIL** verdict must include a `<!-- category: X -->` marker. A FAIL that has a verdict marker but no category marker is recorded as PARSE_ERROR; on the second consecutive occurrence `[BLOCKED:code] {agent}: parse` is set. Verdict calibration: false PASS → production defect (cost 10×); false FAIL → one extra iteration (cost 1×). When evidence is ambiguous, FAIL.

The `<!-- category: X -->` value on a FAIL MUST be copied verbatim from the `→ category:` annotation on the check/angle that fired. Descriptive synonyms (e.g. `COMPLETENESS`, `CONSISTENCY`, `CORRECTNESS`) are not enum members and produce `PARSE_ERROR`. On `PASS`, X MUST be `NONE`. If a finding genuinely has no matching enum value (not a synonym), do not invent a category — emit closest-fit in the verdict and append `[BLOCKED:harness] {critic-name}: reference-extension — ...` to `## Open Questions`. Full procedure: `@reference/severity.md §Enum-extension escape`.

**Structural validity guards** (enforced by `plan-file.sh record-verdict` — see `@reference/severity.md` for enum values):
- **Invalid category**: `<!-- category: X -->` where X is not in the severity.md enum → `PARSE_ERROR` (auto-retry; second consecutive → `[BLOCKED:code] {agent}: parse`).
- **Non-NONE category on PASS**: `<!-- category: X -->` where X is not `NONE` on a `<!-- verdict: PASS -->` → `PARSE_ERROR` (same escalation).
- **FAIL without blocking finding**: `<!-- verdict: FAIL -->` but no blocking-label finding (`[CRITICAL]`, `[MISSING]`, `[MANIFEST-GAP]`, `[FAIL]`, `[DOCS CONTRADICTION]`, or `[UNVERIFIED CLAIM]`) in the output → `PARSE_ERROR` (same escalation). Every FAIL must include at least one blocking finding.

Full iteration protocol: §Loop convergence.

## Consecutive same-category escalation

`plan-file.sh record-verdict` tracks the last FAIL category per critic (agent-scoped, milestone-scoped — the streak resets on `reset-milestone` and is computed within the current phase+milestone boundary). If the same critic emits **two consecutive FAILs with the same category** (PARSE_ERROR verdicts between them are transparent — they do not reset the streak; `reset-milestone` writes a `[MILESTONE-BOUNDARY @ts]` sentinel that **does** reset the streak — streaks are therefore isolated per milestone), the script writes a **non-halting advisory**:

```
[RECURRING] {agent}: {CATEGORY} flagged 2× consecutively — next fix must resolve the root cause behind every {CATEGORY} finding, not only the latest
```

to `## Open Questions` (self-superseding — at most one `[RECURRING]` per agent). The loop continues normally; no `[BLOCKED:code]` is written and `blocked.jsonl` is not updated. Hard stops from §Skill branching logic still apply; RECURRING adds no new stop conditions. `gc-events` removes stale `[RECURRING]` lines; `reset-milestone` clears them at milestone boundaries.

## Review execution rule (isolation mandate)

All phase-gate critic reviews must run in isolated processes. Generating a verdict inline in the orchestrator context is forbidden.

Normative implementations:
- **`critic-spec/test/code/cross`**: shell (`run-critic-loop.sh`) calls `codex exec --dangerously-bypass-approvals-and-sandbox -` directly (worker.sb provides Tier 1 confinement; `--dangerously-bypass-approvals-and-sandbox` prevents nested Seatbelt). Codex is the isolated reviewer; Claude invoked at most once on FAIL (decision agent) and once on convergence-triggering PASS (REJECT-PASS check). Verdict via `plan-file.sh record-verdict-direct` — no SubagentStop hook.
- **`critic-feature`**: `context: fork` + `agent: critic-feature` B-session, SubagentStop hook. Pure Claude.
- **`critic-quality`**: shell (`run-critic-loop.sh`) calls `codex exec` per-angle in parallel (angles/ directory fan-out); `aggregate_angle_verdicts` produces single merged `$_review_log`; rest of Codex path applies. Codex invoked once per angle per iteration; Claude invoked at most once on FAIL (decision agent) and once on convergence-triggering PASS (REJECT-PASS check).

**Prohibited**: generating a verdict directly in the orchestrator context without subprocess isolation.

## Loop convergence

Convergence-based protocol used by every phase-gate critic (critic-feature, critic-spec, critic-test, critic-code, critic-cross) and the pr-review step. Convergence state is stored exclusively in `plans/{slug}.state/convergence/{phase}__{agent}.json` — updated on every verdict by `_record_loop_state`; `converged=true` requires 2 consecutive PASSes (see `@reference/markers.md §Sidecar control state`). A PARSE_ERROR between two PASSes resets the streak: `PASS → PARSE_ERROR → PASS` = streak 1. Query via `plan-file.sh is-converged <plan> <phase> <agent>` (exit 0 = converged). No plan.md marker mirrors this state.

`plan-file.sh record-verdict` appends to `## Critic Verdicts` and updates sidecar convergence state for all normal verdict outcomes (PASS, FAIL, PARSE_ERROR); in exceptional cases it writes a `[BLOCKED]` marker to `## Open Questions` — second consecutive PARSE_ERROR → `[BLOCKED:code] {agent}: parse` (skips the Critic Verdicts append for this case — only sidecar + Open Questions); ceiling exceeded → `[BLOCKED:ceiling]` (appends to both `## Critic Verdicts` and `## Open Questions`). Exception: if the subagent produced no output or known infrastructure error signatures are detected, record-verdict classifies the run as `[BLOCKED:env] {agent}: critic-skill-not-run` — it writes only to `## Open Questions` and `blocked.jsonl`; no Critic Verdicts entry is written and convergence state is not updated (the run is not counted against the ceiling). The skill reads `## Open Questions` for any BLOCKED markers and queries sidecar after each run, then branches per §Skill branching logic.

Ceiling N defaults to **100** (runs 1–100 are allowed; the 101st run triggers `[BLOCKED:ceiling]`; PARSE_ERROR verdicts count toward this ceiling — the transparency at §Consecutive same-category escalation applies only to streak resetting, not to ceiling counting; `REJECT-PASS` entries written by `clear-converged` do **not** count). Override with env var `CLAUDE_CRITIC_LOOP_CEILING`.

### Skill branching logic (after each run)

```
After critic/review run → script records verdict + emits markers
Skill reads ## Open Questions and queries sidecar, checks in priority order:

  1. [BLOCKED:ceiling] {agent}: ...   → stop (manual review; use reset-milestone)
  2. [BLOCKED:spec] {agent}: ambiguous → stop (human decision required)
  3. [BLOCKED:docs] {agent}: ...      → stop (human decision required; apply DOCS CONTRADICTION cascade)
  4. [BLOCKED:{any kind}] ...         → stop (read reason; fix root cause; run unblock; retry)
  5. is-converged exits 0             → proceed to next step
  6. (no terminal marker, PARSE_ERROR in last ## Critic Verdicts entry)
                                → re-run automatically (one retry allowed;
                                  second consecutive PARSE_ERROR triggers [BLOCKED:code] {agent}: parse)
  7. (no terminal marker, PASS) → re-run automatically
  8. (no terminal marker, FAIL) → if `[RECURRING] {agent}:` in `## Open Questions`, ALL findings
       of that category must be addressed at root-cause level, not only the latest.
       **critic-spec/test/code/cross**: one Claude decision-agent call audits all findings → single Codex fix for entire FIX-PLAN.
       **critic-feature**: LLM determines fix direction for ALL GENUINE findings:
       - clear → `codex exec --dangerously-bypass-approvals-and-sandbox - < "$_fix_prompt" > "$_fix_log" 2>&1; tail -200 "$_fix_log"; rm -f "$_fix_prompt" "$_fix_log"` → re-run
       - ambiguous → `[BLOCKED:spec] {agent}: ambiguous — {question}` + stop
       - [DOCS CONTRADICTION] → treat docs/*.md as ground truth; fix code+spec. If docs may be stale → `[BLOCKED:docs]` + cascade + stop (`@reference/phase-ops.md §DOCS CONTRADICTION cascade`).
     ENVELOPE_MISMATCH / ENVELOPE_OVERREACH are ordinary FAIL categories — no
     envelope-specific branch. They resolve through the three branches above:
       - an axis derivable from the spec body, or a scenario overreaching a
         correct envelope (shrink the scenario, per @reference/effort.md) →
         clear → fix, then the critic re-run validates;
       - an axis the spec body does not determine, or a scenario that may be a
         real requirement whose resolution (widen the envelope vs drop the
         scenario) the loop cannot decide → ambiguous → [BLOCKED:spec];
       - an ENVELOPE_MISMATCH FAIL whose finding text says the envelope
         contradicts docs/*.md (the category is ENVELOPE_MISMATCH, not a
         literal [DOCS CONTRADICTION]) — it is a ground-truth decision; apply
         the [DOCS CONTRADICTION] branch by the finding text → [BLOCKED:docs].
```

---

## Running the critic

**Shell-driven (critic-spec/test/code/cross/quality)**: `run-critic-loop.sh` calls `codex exec` directly, records via `record-verdict-direct`, audits on FAIL (decision agent), and REJECT-PASS checks on convergence-triggering PASS. For `critic-quality`, angles/ fan-out runs one `codex exec` per angle in parallel; `aggregate_angle_verdicts` merges into single `$_review_log` before verdict recording. Do not call `record-verdict-direct` manually.
**B-session (critic-feature)**: `Skill("critic-feature", "{prompt}")` is synchronous — `SubagentStop` fires `record-verdict-guarded` within the **same turn**. Do not end the turn after invoking Skill; do not background the call. After Skill returns, run ultrathink audit and branch before exiting. Do not call `record-verdict-guarded` manually.

**Exit codes**: 0 = converged; 1 = blocked (`[BLOCKED:{kind}]` marker in plan, or transient retry); 2 = `[BLOCKED:ceiling]`; 3 = lock contention, **non-nested invocations only** (another run already active for this plan — wait for it to finish or remove the plan's `.critic.lock` file (e.g. `plans/{slug}.md.critic.lock`)); recovery cascades using `--nested` silently inherit any existing lock and never return exit 3; any other code is a script failure: write `[BLOCKED:env] {agent}: script-failure — exit {code}` to `## Open Questions` and stop. Running critics manually is not a fallback — it is a protocol violation.
### New milestone

Before starting a critic run for a new milestone within the same phase, call:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "$CLAUDE_PROJECT_DIR/plans/{slug}.md" {agent}
```
This clears the 1 phase-scoped convergence marker (`[BLOCKED:ceiling]`) (see `@reference/markers.md §Phase-scoped convergence markers`) for this phase+agent from `## Open Questions`, and appends a `[MILESTONE-BOUNDARY]` sentinel to `## Critic Verdicts` so prior-milestone history does not contribute to the new streak. `transition` must run before `reset-milestone` when also changing phase (`transition` calls `set-phase` internally and writes a Phase Transitions log entry; using `plan-file.sh set-phase` directly would skip the log entry), so `reset-milestone` reads the correct phase when clearing phase-scoped markers. For the full list of markers written and cleared by `reset-milestone`, `reset-pr-review`, and `reset-for-rollback`, see `reference/markers.md §Stop marker taxonomy`.

Re-brainstorming the same requirements doc: transition to `brainstorm` first (required before `reset-milestone` so the correct phase-scoped markers are cleared — see line above), then reset the prior critic-feature streak:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" brainstorm \
  "re-brainstorming"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "$CLAUDE_PROJECT_DIR/plans/{slug}.md" critic-feature
```
Then re-invoke the `brainstorming` skill.

### Full rollback reset

For integration failure or unit-test failure before integration: call `transition` first to log the rollback reason in Phase Transitions, then `reset-for-rollback` to atomically reset all critic convergence sidecars (all agents, not just critic-code), run `reset-pr-review`, clear ceiling/recurring markers for `critic-code`, reset all transient counters, and set phase. Note: `reset-for-rollback` does NOT call `reset-milestone` and does NOT write a `[MILESTONE-BOUNDARY]` entry to plan.md `## Critic Verdicts`. If a plan.md boundary marker is needed for a specific critic, call `reset-milestone {critic}` explicitly after `reset-for-rollback`.
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" {target-phase} \
  "{one sentence reason}"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-for-rollback "$CLAUDE_PROJECT_DIR/plans/{slug}.md" {target-phase}
```

When the cleanup phase differs from the destination phase (e.g., clearing `implement` markers while rolling back to `red`): use a 3-call sequence — `transition {cleanup-phase}`, `reset-for-rollback {cleanup-phase}`, then `transition {destination-phase}`. This is necessary because `reset-for-rollback` calls `set-phase` internally, which would overwrite a prior `transition {destination-phase}`. After `transition {destination-phase}`, additionally call `reset-milestone {destination-critic}` if a prior milestone's sidecar streak needs resetting (e.g., rolling back to `red` may require `reset-milestone critic-test` to isolate the new streak). When a milestone must be reset at a non-destination phase (e.g., resetting `red/critic-test` while destination is `spec`): use a phase round-trip — `transition {milestone-phase}`, `reset-milestone {milestone-critic}`, `transition {destination-phase}` — because `reset-milestone` scopes to the current plan phase (implemented by `run-integration.sh`'s spec-gap recovery path).

## §Critic one-shot iteration

**Shell-driven (critic-spec/test/code/cross)** — `run-critic-loop.sh` per iteration, no Claude overhead on PASS:
1. `build_review_prompt` → SKILL.md template → `/tmp/critic-{agent}-review.XXXX`
2. `codex exec --dangerously-bypass-approvals-and-sandbox - < prompt > plans/{slug}.state/codex-critic-{agent}-last.log`
3. grep verdict/category markers; `plan-file.sh record-verdict-direct $PLAN $AGENT $PHASE $verdict $category`
4. **FAIL**: one Claude call (`ultrathink` + Read tool) → `AUDIT:/GENUINE:/FIX-PLAN:` for all findings; `append-audit`; if BLOCKED-AMBIGUOUS: write `[BLOCKED:spec]` markers; `codex exec --dangerously-bypass-approvals-and-sandbox -` with full FIX-PLAN
5. **PASS (2nd/converged)**: one Claude call for REJECT-PASS check only; if REJECT: `clear-converged`; if ACCEPT: exit 0
6. **PASS (1st)**: no Claude call; loop continues

**critic-quality** uses the same shell-driven path with angles/ fan-out: instead of steps 1–2, `run-critic-loop.sh` detects `skills/critic-quality/angles/*.md`, runs one `codex exec` per angle file in parallel (background subshells), waits for all, then calls `aggregate_angle_verdicts` to produce a single merged `$_review_log`. Steps 3–6 proceed identically to the single-prompt path above.

**B-session (critic-feature)** — one `claude` CLI session; do **not** loop; steps 1+2 in one continuous turn:
0. **Pre-fix** (only when `prior_fail_log={path}`): apply Codex fix for each clear FAIL finding; skip ambiguous ones.
1. `Skill("critic-feature", "{prompt}")` — synchronous; `SubagentStop` fires `record-verdict-guarded`. Do not end the turn.
2. `@reference/ultrathink.md §Ultrathink verdict audit`. Read `## Open Questions` per §Skill branching logic — **exception**: never re-runs from shell (step 8/FAIL handled in-session) — **sub-exception**: ACCEPT-OVERRIDE allows one optional in-session `Skill(...)` re-run (see `@reference/ultrathink.md §Applying the audit outcome`); exit after each branch.

## Ambiguity signaling

When a FAIL leaves the fix direction unclear, do **not** guess. Append a `[BLOCKED:spec]` or `[BLOCKED:docs]` marker to `## Open Questions` and stop:

```
[BLOCKED:spec] {agent}: ambiguous — {one-sentence question for the human}
[BLOCKED:docs] {agent}: contradiction — docs may be stale, ground truth ambiguous; apply cascade
```

**Conditions that require human input** (LLM must not resolve unilaterally):

- **Multiple valid fix paths**: "Should docs be updated to match code, or code fixed to match docs?" (classic DOCS_CONTRADICTION split → use `[BLOCKED:docs]`)
- **Contradictory requirements**: spec and docs conflict, and which is ground truth is unclear (→ `[BLOCKED:docs]`)
- **Scope expansion needed**: the fix requires changes outside this feature's scope (→ `[BLOCKED:spec]`)
- **Repeated failure with unknown cause**: the same problem recurs across runs and the root cause cannot be identified (→ `[BLOCKED:spec]`)

If none of the above apply, fix and re-run without stopping. **Autonomous mode behaviour**: the session terminates (Telegram notified if configured). **Resuming**: once you have resolved the question, **run from a human terminal** (Ring C — `CLAUDE_PLAN_CAPABILITY=human` required):
```bash
export CLAUDE_PLAN_CAPABILITY=human
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" unblock "$CLAUDE_PROJECT_DIR/plans/{slug}.md"
```
Then tell the interactive Claude the decision; it will restart the autonomous run.

## Resuming from a BLOCKED marker

All `[BLOCKED:{kind}]` markers are cleared by `unblock` in a single pass — no marker text input needed. `[BLOCKED:transient]` is intentionally excluded (auto lifecycle; not a human-must marker). After fixing the root cause, **run from a human terminal** (Ring C — `CLAUDE_PLAN_CAPABILITY=human` required; see `@reference/markers.md`):
```bash
export CLAUDE_PLAN_CAPABILITY=human
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" unblock "$CLAUDE_PROJECT_DIR/plans/{slug}.md"
```
Re-run the critic. **Exception: for `[BLOCKED:ceiling]`, never use `unblock` alone** — use `reset-milestone {agent}` instead (Ring B — `CLAUDE_PLAN_CAPABILITY=harness` required, not `=human`; `unblock` alone does not increment `milestone_seq` and immediately re-triggers the ceiling block):
```bash
export CLAUDE_PLAN_CAPABILITY=harness
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "$CLAUDE_PROJECT_DIR/plans/{slug}.md" {agent}
```
