---
name: critic-test
description: >
  Review failing tests for scenario coverage and correct mocking levels.
  Trigger: after writing-tests completes, before implementing starts.
user-invocable: false
context: fork
agent: critic-test
allowed-tools: [Bash]
paths: ["src/**", "tests/**", "docs/**", "plans/**"]
---

@reference/critics.md

You orchestrate Codex to perform the review. Build the prompt, run `codex exec`, echo the tail. Do not read sources yourself.

## Build and run the Codex prompt

Substitute placeholders from the prompt you received (`{spec_path}`, `{test_files}`, `{plan_path}`, `{test_command}`).

```bash
_codex_prompt=$(mktemp /tmp/critic-test-prompt-XXXXXX.txt)
_codex_log=$(mktemp /tmp/critic-test-log-XXXXXX.txt)
cat > "$_codex_prompt" <<EOF
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

## Pre-check — test file integrity

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

If no test(red): commit exists, take the oldest commit touching the file as the inferred Red baseline:
\`\`\`bash
red_sha=\$(git log --format='%H' HEAD -- {test_files} | tail -1)
git log --oneline \${red_sha}..HEAD -- {test_files}
\`\`\`
If \`red_sha\` is empty (no commits exist for the file), emit \`[SKIP] test file integrity: no commit history found for {file}\` and continue. If the second command returns commits, the test file was modified after the inferred Red commit — emit the same `[CRITICAL] test file modified after Red phase` FAIL verdict above. If git is unavailable, emit \`[SKIP] test file integrity: git unavailable\` and continue.

## Checks

1. Scenario coverage — every Scenario has a test in {test_files}?
   - If no test found in {test_files}: check ## Test Manifest in {plan_path} for a GREEN (pre-existing) entry
     that plausibly covers this scenario (grep scenario name keywords against manifest entries).
     - Match found → [MANIFEST-GAP]: covered by pre-existing test; fix = add to Test Manifest mapping
     - No match → [MISSING]: no test exists; fix = write a new test
   Every Scenario Outline row covered? Failure scenarios tested? (→ [MISSING])

2. Mocking levels — apply layers.md §Test mocking levels. Each Violation column entry is [FAIL].

3. Test quality — each test maps to exactly one Scenario; names follow "should {outcome} when {condition}"; no implementation logic inside tests. (→ [FAIL])

4. Confirm all tests fail — run the test command. Every newly written test must fail.

   Exception: a test marked \`GREEN (pre-existing)\` in the Test Manifest is allowed to pass. For each GREEN entry, verify with git that the test file predates the Red-phase commit:
   \`\`\`bash
   red_commit_ts=\$(git log --grep='^test(red):' --format='%H %at' -- {test_files} | head -1 | awk '{print \$2}')
   create_ts=\$(git log --follow --diff-filter=A --format='%at' -- "\$test_file" | tail -1)
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

- Test file modified after Red / GREEN integrity   → TEST_INTEGRITY
- Mocking level violation (Check 2)                 → LAYER_VIOLATION
- Scenario coverage gap, no test exists (Check 1)   → MISSING_SCENARIO
- Manifest mapping missing, pre-existing test covers it (Check 1) → TEST_QUALITY
- Test quality (Check 3)                            → TEST_QUALITY

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
<!-- category: {one of TEST_INTEGRITY | LAYER_VIOLATION | MISSING_SCENARIO | TEST_QUALITY} -->

A FAIL without a category marker is recorded as PARSE_ERROR. When evidence is ambiguous, FAIL.
EOF

codex exec --full-auto - < "$_codex_prompt" > "$_codex_log" 2>&1
_codex_exit=$?
echo "=== Codex critic-test exit: $_codex_exit ==="
tail -200 "$_codex_log"
rm -f "$_codex_prompt" "$_codex_log"
```

The verdict markers in the tail are your final stdout. Do not append text after `tail -200`.
