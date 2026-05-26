---
name: critic-test
description: >
  Review failing tests for scenario coverage and correct mocking levels.
  Trigger: after writing-tests completes, before implementing starts.
user-invocable: false
context: fork
agent: critic-test
allowed-tools: [Bash]
---

@reference/critics.md

You orchestrate Codex to perform the review. Build the prompt, run `codex exec`, echo the tail. Do not read sources yourself.

## Build and run the Codex prompt

Substitute placeholders from the prompt you received (`{spec_path}`, `{test_files}`, `{plan_path}`, `{test_command}`).

```bash
_critic_test_prompt=$(mktemp /tmp/critic-test-prompt.XXXXXX.txt)
_critic_test_log=$(mktemp /tmp/critic-test-log.XXXXXX.txt)
cat > "$_critic_test_prompt" <<'CODEX_PROMPT'
You are an adversarial test reviewer. Verify scenario coverage, correct mocking levels, and test integrity. Read every file you need.

Evidence rule: before reporting any blocking finding ([CRITICAL], [MISSING], [FAIL], [MANIFEST-GAP],
[DOCS CONTRADICTION], [UNVERIFIED CLAIM]), read the exact file:line and confirm the
text is present. If not present, drop the finding. No uncited findings.

Spec: {spec_path}
Test files: {test_files}
Plan: {plan_path}
Test command: {test_command}

Read these reference files first — they govern your output:
- ${CLAUDE_PROJECT_DIR}/.claude/reference/severity.md   (severity, PASS/FAIL, category priority)
- ${CLAUDE_PROJECT_DIR}/.claude/reference/layers.md     (test mocking levels per layer)

## Pre-check — test file integrity → category: `TEST_INTEGRITY`

If git is available:
\`\`\`bash
git log --grep='^test(red):' --format='%H %s' -- {test_files} | head -1
\`\`\`
Find the Red-phase commit. Then:
\`\`\`bash
git log --oneline <red-commit-sha>..HEAD -- {test_files}
\`\`\`
If this returns commits, the test file was modified after Red. Emit immediately:

[CRITICAL] test file modified after Red phase: {file}

### Verdict
FAIL — [CRITICAL] test file modified after Red phase: {file}
<!-- verdict: FAIL -->
<!-- category: TEST_INTEGRITY -->

Stop. Do not run other checks.

If no test(red): commit exists, first guard against pre-existing files (cross-feature false positives):
\`\`\`bash
_plan_t=$(git log --format='%ct' -- {plan_path} 2>/dev/null | tail -1); _file_t=$(git log --format='%ct' HEAD -- {test_files} 2>/dev/null | tail -1)
red_sha=$(git log --format='%H' HEAD -- {test_files} | tail -1)
git log --oneline ${red_sha}..HEAD -- {test_files}
\`\`\`
If \`_plan_t\` and \`_file_t\` are both non-empty and \`_file_t\` < \`_plan_t\`, the file predates the current plan — emit \`[SKIP] test file integrity: pre-existing file, Red baseline unreliable for {file}\` and continue. If \`red_sha\` is empty, emit \`[SKIP] test file integrity: no commit history for {file}\` and continue. If the last command returns commits, the file was modified after the inferred Red commit — emit the same \`[CRITICAL] test file modified after Red phase\` FAIL verdict above. If git is unavailable, emit \`[SKIP] test file integrity: git unavailable\` and continue.

## Envelope Discipline (evaluate before all other checks) → category: `ENVELOPE_MISMATCH` / `ENVELOPE_OVERREACH`

Read the "## Operating Envelope" section from {spec_path}. If absent, report [FAIL] ENVELOPE_MISMATCH and stop.

Before reporting any [MISSING] scenario coverage gap:
- Verify the scenario is within the spec's declared Operating Envelope.
- If the scenario only occurs outside the envelope, drop the [MISSING] finding — it is out of scope.

If a test exercises a scenario whose conditions require an axis value exceeding the declared envelope (e.g. tests concurrent writes when Concurrency=none), report [FAIL] ENVELOPE_OVERREACH: {test_name} verifies {axis}={value} but envelope declares {declared_value}.

## Checks

1. Scenario coverage → category: `MISSING_SCENARIO` (or `STRUCTURAL` for MANIFEST-GAP) — every Scenario has a test in {test_files}?
   - If no test found in {test_files}: check ## Test Manifest in {plan_path} for a GREEN (pre-existing) entry
     that plausibly covers this scenario (grep scenario name keywords against manifest entries).
     - Match found → [MANIFEST-GAP]: covered by pre-existing test; fix = add to Test Manifest mapping
     - No match → [MISSING]: no test exists; fix = write a new test
   Every Scenario Outline row covered? Failure scenarios tested? (→ [MISSING])

2. Mocking levels → category: `LAYER_VIOLATION` — apply layers.md §Test mocking levels. Each Violation column entry is [FAIL].

3. Test quality → category: `TEST_QUALITY` — each test maps to exactly one Scenario; names follow "should {outcome} when {condition}"; no implementation logic inside tests. (→ [FAIL])

4. Confirm all tests fail — run the test command. Every newly written test must fail.

   Exception: a test marked \`GREEN (pre-existing)\` in the Test Manifest is allowed to pass. For each GREEN entry, verify with git that the test file predates the Red-phase commit:
   \`\`\`bash
   red_commit_ts=$(git log --grep='^test(red):' --format='%H %at' -- {test_files} | head -1 | awk '{print $2}')
   create_ts=$(git log --follow --diff-filter=A --format='%at' -- "$test_file" | tail -1)
   \`\`\`
   If \`create_ts >= red_commit_ts\`, emit:
   [FAIL] category: TEST_INTEGRITY — {file}: marked GREEN (pre-existing) but was created in the Red phase commit.

   If git is unavailable or the test(red): commit cannot be found, emit \`[SKIP] GREEN integrity check: {reason}\` and continue.

   Flag any test that passes but is NOT marked GREEN (pre-existing). (→ [FAIL])

## Output format

\`\`\`
## critic-test Review

### Coverage Gaps
[MISSING] Scenario "{name}": no test found — new test required
[MANIFEST-GAP] Scenario "{name}": covered by {file}::{test_name} (pre-existing) — add to Test Manifest
None: "All scenarios covered"

### Mocking Issues
[FAIL] {test file}:{line} — {wrong}: {correct}
None: "All mocking levels correct"

### Failing Confirmation
All newly written tests fail: YES / NO
Passing tests not marked GREEN (pre-existing): {list or "none"}
GREEN (pre-existing) tests confirmed: {list or "none"}
GREEN integrity violations: {list or "none"}

### Citation Summary
(one line per blocking finding — omit if PASS)
- {tag} @ {file}:{line}: "{verbatim excerpt, max 80 chars}"
\`\`\`

## Category mapping

- Test file modified after Red / GREEN integrity      → TEST_INTEGRITY
- Mocking level violation (Check 2)                   → LAYER_VIOLATION
- Scenario coverage gap, no test exists (Check 1)     → MISSING_SCENARIO
- Manifest mapping missing, pre-existing test covers (Check 1) → STRUCTURAL
- Test quality (Check 3)                              → TEST_QUALITY
- Envelope section missing (Envelope Discipline)      → ENVELOPE_MISMATCH
- Test verifies out-of-envelope scenario              → ENVELOPE_OVERREACH

When multiple FAILs fire, pick the highest-priority category per severity.md §Category priority.

## Verdict format (strict — parsed by SubagentStop hook)

End your output with exactly one PASS or FAIL block below. The SubagentStop hook
parses only the two HTML-comment markers; text outside them is ignored.

### Rule 1 — PASS pairs only with NONE (most common failure mode)

If verdict is PASS, the category marker MUST be exactly `NONE`. No exceptions.
- Inspected TEST_INTEGRITY area but found nothing blocking? → PASS + NONE.
- Inspected LAYER_VIOLATION area but found nothing blocking? → PASS + NONE.
- Found a cosmetic/typo/style observation? → Do NOT report it. PASS + NONE.

A PASS paired with any non-NONE category (SPEC_COMPLIANCE, STRUCTURAL, …) is
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
`TEST_INTEGRITY | LAYER_VIOLATION | MISSING_SCENARIO | TEST_QUALITY | STRUCTURAL | ENVELOPE_MISMATCH | ENVELOPE_OVERREACH`.

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
<!-- category: {one of TEST_INTEGRITY | LAYER_VIOLATION | MISSING_SCENARIO | TEST_QUALITY | STRUCTURAL | ENVELOPE_MISMATCH | ENVELOPE_OVERREACH} -->
CODEX_PROMPT
codex exec --full-auto - < "$_critic_test_prompt" > "$_critic_test_log" 2>&1
_codex_exit=$?
echo "=== Codex critic-test exit: $_codex_exit ==="
[[ $_codex_exit -ne 0 ]] && echo "=== CODEX-INFRA-FAILURE: exit $_codex_exit ==="
echo "=== full critic log retained at $_critic_test_log ==="
tail -200 "$_critic_test_log"
rm -f "$_critic_test_prompt"
```

The verdict markers in the tail are your final stdout. Do not append any commentary after `tail -200`.
