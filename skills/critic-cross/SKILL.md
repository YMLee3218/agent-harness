---
name: critic-cross
description: >
  Cross-feature spec consistency review. Reads all feature specs simultaneously
  and reports contradictions, overlapping ownership, missing handoffs, state machine
  conflicts, domain drift, and layer boundary mismatches.
  Triggered once after all specs are written, before any implementation begins.
user-invocable: false
context: fork
agent: critic-cross
allowed-tools: [Bash]
paths: ["src/**", "tests/**", "docs/**", "plans/**", "features/**", "domain/**", "infrastructure/**"]
---

@reference/critics.md

You orchestrate Codex to perform the review. Build the prompt, run `codex exec`, echo the tail. Do not read sources yourself.

## Build and run the Codex prompt

Substitute placeholders from the prompt you received (`{all_spec_paths}`, `{docs_paths}`, `{plan_path}`).

```bash
_critic_cross_prompt=$(mktemp /tmp/critic-cross-prompt.XXXXXX.txt)
_critic_cross_log=$(mktemp /tmp/critic-cross-log.XXXXXX.txt)
cat > "$_critic_cross_prompt" <<'CODEX_PROMPT'
You are an adversarial cross-feature reviewer. Read ALL provided spec files in full.
Assume contradictions exist until proven otherwise.

Specs to review: {all_spec_paths}
Docs: {docs_paths}
Plan: {plan_path}

Evidence rule: before reporting any blocking finding ([FAIL]), read the exact file:line
and confirm the text is present. If not present, drop the finding. No uncited findings.

Read these reference files first — they govern your output:
- ${CLAUDE_PROJECT_DIR}/.claude/reference/severity.md
- ${CLAUDE_PROJECT_DIR}/.claude/reference/layers.md
- ${CLAUDE_PROJECT_DIR}/.claude/reference/bdd-templates.md
- ${CLAUDE_PROJECT_DIR}/.claude/reference/operating-envelope.md (legal axis values; filled vs placeholder definition)

## Angle 1 — Contradictory behaviors → category: `CROSS_FEATURE_CONTRADICTION`
Feature A says X happens, Feature B says X does not happen.
  → Cite both files+lines, quote both statements.

## Angle 2 — Overlapping responsibilities → category: `LAYER_VIOLATION`
Two features claim to own the same data mutation, event, or domain concept.
  → Cite both features' specs.

## Angle 3 — Missing handoffs → category: `MISSING_SCENARIO`
Feature A produces output Feature B consumes, but the interface is undefined in either spec.
  → Cite the producer scenario + gap.

## Angle 4 — State machine conflicts → category: `CROSS_FEATURE_CONTRADICTION`
Two features transition the same entity to incompatible states under similar preconditions.
  → Quote both Given/When/Then blocks.

## Angle 5 — Naming inconsistencies (domain drift) → category: `STRUCTURAL`
Same concept named differently across specs.
  → List all variant names + files.

## Angle 6 — Layer boundary cross-check → category: `LAYER_VIOLATION`
A feature spec directly references domain concepts owned by another feature without going
through the correct layer boundary (per layers.md).

## Angle 7 — Cross-feature Envelope consistency → category: `ENVELOPE_MISMATCH`

For features that interact (handoffs, shared entities, state transitions): verify their Operating Envelopes are compatible.
- Feature A declares Actors=`N users`, Feature B (which it calls) declares Actors=`tenants` → [FAIL] ENVELOPE_MISMATCH
- Feature A declares Concurrency=none, Feature B (concurrent consumer) declares multi-writer → [FAIL] ENVELOPE_MISMATCH
Quote both features' Operating Envelope sections.
For each axis, apply the rule in `${CLAUDE_PROJECT_DIR}/.claude/reference/operating-envelope.md §Envelope axis compatibility`:
- First identify caller-callee direction from spec text (handoff, composition, state-transition). If no clear direction (bidirectional handoff via shared store): apply the bidirectional variant per axis.
- Frequency, Concurrency, Persistence, Failure model: `callee.value ≥ caller.value` per the per-axis partial order. Violation → ENVELOPE_MISMATCH.
- Actors: consult the (caller, callee) lookup table; CONTEXT outcomes require examining whether the tenant/user boundary is preserved in the spec text.
- External I/O: parse as set; apply direction-aware subset (`callee.surfaces ⊆ caller.surfaces`).
- Bidirectional handoff: use the symmetric variant per axis (equality for partial-order axes and Actors; non-empty intersection for External I/O).

Before reporting any [FAIL] for cross-feature issues (Angles 1–4), verify the interaction scenario is within the declared envelope of both features. Drop findings that only occur outside either feature's envelope.

## Output format

\`\`\`
## critic-cross Review

### Angle 1 — Contradictory Behaviors
[FAIL] {feature_a}:{line} vs {feature_b}:{line}: {description}
  "{excerpt_a}" vs "{excerpt_b}"
None: "No contradictory behaviors"

### Angle 2 — Overlapping Responsibilities
[FAIL] {concept} claimed by {feature_a}:{line} and {feature_b}:{line}
None: "No overlapping responsibilities"

### Angle 3 — Missing Handoffs
[FAIL] {feature_a} produces {output} consumed by {feature_b} — interface undefined
  {file}:{line}: "{excerpt}"
None: "No missing handoffs"

### Angle 4 — State Machine Conflicts
[FAIL] {entity} transitioned to {state_a} by {feature_a} and {state_b} by {feature_b} under same precondition
None: "No state machine conflicts"

### Angle 5 — Naming Inconsistencies
[FAIL] {concept}: called "{name_a}" in {file_a}:{line} and "{name_b}" in {file_b}:{line}
None: "No naming inconsistencies"

### Angle 6 — Layer Boundary Cross-check
[FAIL] {feature}:{line} references domain concept owned by {other_feature} without boundary
None: "No layer boundary violations"

### Angle 7 — Cross-feature Envelope Consistency
[FAIL] ENVELOPE_MISMATCH: {feature_a} envelope {axis}={value_a} incompatible with {feature_b} envelope {axis}={value_b}
  {feature_a_spec}:{line}: "{envelope_a_excerpt}" vs {feature_b_spec}:{line}: "{envelope_b_excerpt}"
None: "All envelope axes compatible across interacting features"

### Citation Summary
(one line per blocking finding — omit if PASS)
- {tag} @ {file}:{line}: "{verbatim excerpt, max 80 chars}"
\`\`\`

## Category mapping

- Contradictory behaviors / state conflicts        → CROSS_FEATURE_CONTRADICTION
- Overlapping ownership                             → LAYER_VIOLATION
- Missing handoffs                                  → MISSING_SCENARIO
- Naming inconsistencies                            → STRUCTURAL
- Layer boundary cross-check                        → LAYER_VIOLATION
- Incompatible envelope axes across features (Angle 7) → ENVELOPE_MISMATCH

When multiple FAILs fire, pick the highest-priority category per severity.md §Category priority.

## Verdict format (strict — parsed by SubagentStop hook)

End your output with exactly one PASS or FAIL block below. The SubagentStop hook
parses only the two HTML-comment markers; text outside them is ignored.

### Rule 1 — PASS pairs only with NONE (most common failure mode)

If verdict is PASS, the category marker MUST be exactly `NONE`. No exceptions.
- Inspected CROSS_FEATURE_CONTRADICTION area but found nothing blocking? → PASS + NONE.
- Inspected LAYER_VIOLATION area but found nothing blocking? → PASS + NONE.
- Found a cosmetic/typo/style observation? → Do NOT report it. PASS + NONE.

A PASS paired with any non-NONE category (STRUCTURAL, MISSING_SCENARIO, …) is
recorded as PARSE_ERROR. Two consecutive PARSE_ERRORs halt the run.

### Rule 2 — Advisory severity labels do not exist

Per `@reference/severity.md`, only these labels are valid and ALL are blocking:
`[CRITICAL]`, `[MISSING]`, `[MANIFEST-GAP]`, `[FAIL]`, `[DOCS CONTRADICTION]`,
`[UNVERIFIED CLAIM]`. Inventing `[MINOR]`, `[NIT]`, `[INFO]`, `[ADVISORY]`,
`[STYLE]`, `[SUGGESTION]` is forbidden. If an observation does not warrant one
of the six blocking labels, omit it entirely — do not relabel it.

Corollary: if your `Findings:` list contains no blocking labels, verdict is
PASS and category is NONE. Period.

### Rule 3 — FAIL category enum (only when Rule 1 does not apply)

On FAIL, copy `<!-- category: X -->` verbatim from the `→ category:`
annotation on the angle/check that fired. Allowed enum (this critic):
`CROSS_FEATURE_CONTRADICTION | LAYER_VIOLATION | MISSING_SCENARIO | STRUCTURAL | ENVELOPE_MISMATCH`.

FORBIDDEN substitutes (recorded as PARSE_ERROR): `COMPLETENESS`, `CONSISTENCY`,
`CORRECTNESS`, `CONTRACT`, any descriptive synonym, any section title.
A FAIL without a `<!-- category: -->` marker is recorded as PARSE_ERROR.

### Blocks

PASS:
### Verdict
PASS
<!-- verdict: PASS -->
<!-- category: NONE -->

FAIL:
### Verdict
FAIL — {comma-separated blocking finding labels}
<!-- verdict: FAIL -->
<!-- category: {one of CROSS_FEATURE_CONTRADICTION | LAYER_VIOLATION | MISSING_SCENARIO | STRUCTURAL | ENVELOPE_MISMATCH} -->
CODEX_PROMPT
codex exec --full-auto - < "$_critic_cross_prompt" > "$_critic_cross_log" 2>&1
_codex_exit=$?
echo "=== Codex critic-cross exit: $_codex_exit ==="
[[ $_codex_exit -ne 0 ]] && echo "=== CODEX-INFRA-FAILURE: exit $_codex_exit ==="
echo "=== full critic log retained at $_critic_cross_log ==="
tail -200 "$_critic_cross_log"
rm -f "$_critic_cross_prompt"
```

The verdict markers in the tail are your final stdout. Do not append any commentary after `tail -200`.
