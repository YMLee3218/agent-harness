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
_codex_prompt=$(mktemp /tmp/critic-cross-prompt-XXXXXX.txt)
_codex_log=$(mktemp /tmp/critic-cross-log-XXXXXX.txt)
cat > "$_codex_prompt" <<EOF
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

## Angle 1 — Contradictory behaviors
Feature A says X happens, Feature B says X does not happen.
  → Cite both files+lines, quote both statements.

## Angle 2 — Overlapping responsibilities
Two features claim to own the same data mutation, event, or domain concept.
  → Cite both features' specs.

## Angle 3 — Missing handoffs
Feature A produces output Feature B consumes, but the interface is undefined in either spec.
  → Cite the producer scenario + gap.

## Angle 4 — State machine conflicts
Two features transition the same entity to incompatible states under similar preconditions.
  → Quote both Given/When/Then blocks.

## Angle 5 — Naming inconsistencies (domain drift)
Same concept named differently across specs.
  → List all variant names + files.

## Angle 6 — Layer boundary cross-check
A feature spec directly references domain concepts owned by another feature without going
through the correct layer boundary (per layers.md).

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
[WARN] {concept}: called "{name_a}" in {file_a}:{line} and "{name_b}" in {file_b}:{line}
None: "No naming inconsistencies"

### Angle 6 — Layer Boundary Cross-check
[FAIL] {feature}:{line} references domain concept owned by {other_feature} without boundary
None: "No layer boundary violations"

### Citation Summary
(one line per blocking finding — omit if PASS)
- {tag} @ {file}:{line}: "{verbatim excerpt, max 80 chars}"
\`\`\`

## Category mapping

- Contradictory behaviors / state conflicts   → CROSS_FEATURE_CONTRADICTION
- Overlapping ownership                        → LAYER_VIOLATION
- Missing handoffs                             → MISSING_SCENARIO
- Naming inconsistencies                       → STRUCTURAL
- Layer boundary cross-check                   → LAYER_VIOLATION

When multiple FAILs fire, pick the highest-priority category per severity.md §Category priority.

## Verdict format (strict — parsed by SubagentStop hook)

End your output with exactly one of these blocks. Nothing after.

PASS:
### Verdict
PASS
<!-- verdict: PASS -->
<!-- category: NONE -->

FAIL:
### Verdict
FAIL — {comma-separated blocking finding labels}
<!-- verdict: FAIL -->
<!-- category: {one of CROSS_FEATURE_CONTRADICTION | LAYER_VIOLATION | MISSING_SCENARIO | STRUCTURAL} -->

A FAIL without a category marker is recorded as PARSE_ERROR. When evidence is ambiguous, FAIL.
EOF

codex exec --full-auto - < "$_codex_prompt" > "$_codex_log" 2>&1
_codex_exit=$?
echo "=== Codex critic-cross exit: $_codex_exit ==="
tail -200 "$_codex_log"
rm -f "$_codex_prompt" "$_codex_log"
```

The verdict markers in the tail are your final stdout. Do not append text after `tail -200`.
