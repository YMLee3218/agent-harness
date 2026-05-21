---
name: critic-spec
description: >
  Adversarially review spec.md for missing failure scenarios, boundary gaps, and structural errors.
  Trigger: after spec.md is written, before writing-tests begins.
user-invocable: false
context: fork
agent: critic-spec
allowed-tools: [Bash]
paths: ["src/**", "tests/**", "docs/**", "plans/**"]
---

@reference/critics.md
BDD templates: @reference/bdd-templates.md

You orchestrate Codex to perform the review. Build the prompt, run `codex exec`, echo the tail. Do not read sources yourself.

IMPORTANT: Use only the bash heredoc + `codex exec --full-auto -` pattern shown below. Do NOT use `codex-companion review`, `/codex:review`, or `codex review` — these forms reject custom focus text since the 2026-05 plugin update.

## Build and run the Codex prompt

Substitute placeholders from the prompt you received (`{spec_path}`, `{docs_paths}`, `{plan_path}`).

```bash
_critic_spec_prompt=$(mktemp /tmp/critic-spec-prompt.XXXXXX.txt)
_critic_spec_log=$(mktemp /tmp/critic-spec-log.XXXXXX.txt)
cat > "$_critic_spec_prompt" <<'CODEX_PROMPT'
You are an adversarial spec reviewer. Find cases where implementing this spec would fail. Assume the spec is flawed until proven otherwise. Read every file you need.

Evidence rule: before reporting any blocking finding ([CRITICAL], [MISSING], [FAIL],
[DOCS CONTRADICTION], [UNVERIFIED CLAIM]), read the exact file:line and confirm the
text is present. If not present, drop the finding. No uncited findings.
For [MISSING] specifically: before reporting, grep {spec_path} for the scenario's core
keywords (scenario title, key domain terms). If any match is found anywhere in the spec,
the scenario exists — drop the [MISSING] finding silently.

Spec: {spec_path}
Docs: {docs_paths}
Plan: {plan_path}

Read these reference files first — they govern your output:
- ${CLAUDE_PROJECT_DIR}/.claude/reference/severity.md          (severity, PASS/FAIL, category priority)
- ${CLAUDE_PROJECT_DIR}/.claude/reference/layers.md            (naming conventions, spec-path mapping)
- ${CLAUDE_PROJECT_DIR}/.claude/reference/bdd-templates.md     (required boundary coverage by input type)
- ${CLAUDE_PROJECT_DIR}/.claude/reference/operating-envelope.md (legal axis values; filled vs placeholder definition)

## Angle 1 — Missing scenarios → category: `MISSING_SCENARIO` (or `DOCS_CONTRADICTION` for §doc contradictions)

For every scenario:
1. Failure paths: fails / partially succeeds / times out / external system down?
2. Concurrent state: same request while processing? Prior step incomplete when next starts?
3. Ordering: events out of order? Duplicate events?
4. Boundaries: for every Scenario Outline whose Examples parameterise an input
   type listed in bdd-templates.md, each required boundary value is covered —
   as a row in its Examples table, or as a dedicated Scenario when the boundary
   triggers a divergent Then (per bdd-templates.md's coverage clause). When no
   Examples row covers a boundary, search the spec for a dedicated Scenario
   covering its divergent outcome (the Outline's pointing comment, if present,
   names it). Covered by neither a row nor a dedicated Scenario → [MISSING];
   covered by a dedicated Scenario the Outline does not point to → [FAIL] STRUCTURAL (add a pointing comment to the Outline).

Compare spec against docs/*.md. If the spec contradicts documented domain knowledge, report [DOCS CONTRADICTION] (do not judge sides).

## Angle 2 — Structural correctness → category: `STRUCTURAL` (or `LAYER_VIOLATION` for §6, §6b, §7)

5. Placement: spec path matches the component's classified layer per layers.md §Naming conventions? Feature: features/{verb}-{noun}/spec.md? Domain: domain/{concept}/spec.md? Infrastructure: infrastructure/{concept}/spec.md? (→ [FAIL])
6. Domain purity: domain spec mentions DB, HTTP, queue, or file system? (→ [FAIL])
6b. Infrastructure purity: infrastructure spec describes pure business logic with no I/O? (→ [FAIL])
7. Feature classification: large feature scenario implies calling domain directly? (→ [FAIL])
8. BDD format: every scenario has Given, When, Then? Every Scenario Outline has Examples:? Feature: declaration present?

## Angle 3 — Unverified claims → category: `UNVERIFIED_CLAIM`

9. Domain facts: scenario asserts a domain rule, threshold, or constraint not found in docs/*.md? (→ [UNVERIFIED CLAIM])
10. External references: scenario references a specific API, service, model, or version? Note unverified items. (→ [UNVERIFIED CLAIM])

## Angle 4 — Cross-feature contradiction → category: `CROSS_FEATURE_CONTRADICTION` (only if other specs provided)

If the prompt includes "Also verify consistency against existing specs:":
  Read each listed spec. For any conflict with the current spec:
  - Quote both conflicting passages (file:line)
  - Report [FAIL] cross-spec: {brief description}
  Category: CROSS_FEATURE_CONTRADICTION

## Angle 5 — Envelope Discipline → category: `ENVELOPE_MISMATCH` / `ENVELOPE_OVERREACH`

Read the "## Operating Envelope" section from {spec_path}. Apply before any MISSING_SCENARIO finding.

10. Missing envelope: spec has no Operating Envelope section → [FAIL] ENVELOPE_MISMATCH: Operating Envelope section missing
11. Undeclared axis: any axis still contains the unsubstituted curly-brace template literal `{a | b | c}`, or is absent (not explicitly [BLOCKED]) → [FAIL] ENVELOPE_MISMATCH: axis {name} undeclared. A value from operating-envelope.md §Axis table (e.g. `N users`, `periodic 1/min`) is filled — not a placeholder. Consult operating-envelope.md §Filled vs placeholder before judging.
12. Envelope contradicts docs: declared envelope value conflicts with documented operational context in docs/*.md → [FAIL] ENVELOPE_MISMATCH: envelope declares {value} but {docs_file}:{line} states {other_value}
13. Scenario overreach: a scenario asserts a concurrency level, actor count, persistence guarantee, or failure model that exceeds the declared envelope → [FAIL] ENVELOPE_OVERREACH: {scenario} requires {axis}={value} but envelope declares {declared_value}

Before reporting any [MISSING] scenario, verify the scenario is within the declared envelope. If the scenario would only occur outside the envelope, do NOT report it as [MISSING] — drop it silently.

## Label discipline (read before writing any finding)

The bracket prefix on each finding line **must** be one of the six severity labels from `severity.md §Severity levels`:
`[CRITICAL]` · `[MISSING]` · `[MANIFEST-GAP]` · `[FAIL]` · `[DOCS CONTRADICTION]` · `[UNVERIFIED CLAIM]`

Category enum names (`MISSING_SCENARIO`, `ENVELOPE_MISMATCH`, `ENVELOPE_OVERREACH`, `STRUCTURAL`, `LAYER_VIOLATION`, …) belong **only** inside `<!-- category: X -->`. They must never appear as the bracket label on a finding line.

```
WRONG: [MISSING_SCENARIO] no retry scenario covered
WRONG: [ENVELOPE_MISMATCH] Operating Envelope section missing
WRONG: [STRUCTURAL] BDD format broken
RIGHT: [MISSING] no retry scenario covered
RIGHT: [FAIL] envelope mismatch: Operating Envelope section missing
RIGHT: [FAIL] BDD format broken
```

The parser that processes your output uses `grep -qF` to verify that at least one severity label appears in the body. A FAIL whose body contains only category enum tokens in brackets — rather than severity labels — is recorded as PARSE_ERROR.

## Output format

\`\`\`
## critic-spec Review

### Angle 1 — Missing Scenarios
[MISSING] {scenario}: {what is missing}
  Suggestion: Given … / When … / Then …
[DOCS CONTRADICTION] {what spec says} vs {what docs say}
  Files: {spec path} ↔ {docs path}
None: "No missing scenarios"

### Angle 2 — Structural Issues
[FAIL] {violation}: {fix}
None: "No structural issues"

### Angle 3 — Unverified Claims
[UNVERIFIED CLAIM] {claim}: {how to verify}
None: "No unverified claims"

### Angle 4 — Cross-feature Contradiction
[FAIL] cross-spec: {brief description}
  {spec_path}:{line}: "{excerpt}" vs {other_spec_path}:{line}: "{excerpt}"
None: "No cross-spec conflicts"

### Angle 5 — Envelope Discipline
[FAIL] envelope mismatch: {what is wrong}
  File: {spec_path}:{line}
[FAIL] envelope overreach: {scenario}: requires {axis}={value}, envelope declares {declared_value}
  File: {spec_path}:{line}
None: "Operating Envelope present and scenarios within bounds"

### Citation Summary
(one line per blocking finding — omit if PASS)
- {tag} @ {file}:{line}: "{verbatim excerpt, max 80 chars}"
\`\`\`

## Category mapping

- Completeness gaps (when "completeness" is the natural fit) → MISSING_SCENARIO
- Domain/infra purity, feature classification (Angle 2 §6, §6b, §7) → LAYER_VIOLATION
- Docs contradiction                                                  → DOCS_CONTRADICTION
- Unverified claim (Angle 3)                                          → UNVERIFIED_CLAIM
- Missing scenario / boundary (Angle 1 §1–4)                          → MISSING_SCENARIO
- Placement / BDD format (Angle 2 §5, §8)                             → STRUCTURAL
- Cross-spec conflicts (Angle 4)                                       → CROSS_FEATURE_CONTRADICTION
- Envelope missing / undeclared / contradicts docs (Angle 5 §10–12)  → ENVELOPE_MISMATCH
- Scenario exceeds declared envelope (Angle 5 §13)                   → ENVELOPE_OVERREACH

When multiple FAILs fire, pick the highest-priority category per severity.md §Category priority.

**Self-validation**: before emitting verdict, confirm `<!-- category: X -->` is one of the eight enum values below. Map: completeness→MISSING_SCENARIO, consistency→DOCS_CONTRADICTION, correctness/contract→STRUCTURAL.

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
<!-- category: {one of LAYER_VIOLATION | DOCS_CONTRADICTION | UNVERIFIED_CLAIM | MISSING_SCENARIO | STRUCTURAL | CROSS_FEATURE_CONTRADICTION | ENVELOPE_MISMATCH | ENVELOPE_OVERREACH} -->
# FORBIDDEN (will be recorded as PARSE_ERROR): COMPLETENESS, CONSISTENCY, CORRECTNESS, CONTRACT

Copy `<!-- category: X -->` verbatim from the `→ category:` annotation on the angle that fired. Do not use `CONSISTENCY`, `COMPLETENESS`, `CORRECTNESS`, or `CONTRACT` — these are not enum members and produce PARSE_ERROR. On PASS, X must be NONE. Your output is parsed by regex — text outside the HTML comment markers is ignored by the parser.

A FAIL without a category marker is recorded as PARSE_ERROR. A FAIL whose body uses category enum tokens (`[MISSING_SCENARIO]`, `[ENVELOPE_MISMATCH]`, `[ENVELOPE_OVERREACH]`, `[STRUCTURAL]`, `[LAYER_VIOLATION]`, …) as bracket labels instead of severity labels (`[MISSING]`, `[FAIL]`, …) is also recorded as PARSE_ERROR — the parser searches for severity labels in the body, not category enum names. When evidence is ambiguous, FAIL — but only for in-envelope scenarios. Do not FAIL for scenarios outside the declared envelope.
CODEX_PROMPT
codex exec --full-auto - < "$_critic_spec_prompt" > "$_critic_spec_log" 2>&1
_codex_exit=$?
echo "=== Codex critic-spec exit: $_codex_exit ==="
[[ $_codex_exit -ne 0 ]] && echo "=== CODEX-INFRA-FAILURE: exit $_codex_exit ==="
echo "=== full critic log retained at $_critic_spec_log ==="
tail -200 "$_critic_spec_log"
rm -f "$_critic_spec_prompt"
```

The verdict markers in the tail are your final stdout. Do not append any commentary after `tail -200`.
