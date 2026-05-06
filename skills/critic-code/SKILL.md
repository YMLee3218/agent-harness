---
name: critic-code
description: >
  Review implementation for spec compliance and layer boundary violations after each milestone.
  Trigger: "critic", "architecture review", "check the implementation", after completing a small feature,
  a domain concept, or a significant chunk. Covers spec adherence and architecture rules.
user-invocable: false
context: fork
agent: critic-code
allowed-tools: [Bash]
paths: ["src/**", "tests/**", "docs/**", "plans/**"]
---

@reference/critics.md

You orchestrate Codex to perform the review. Build the prompt, run `codex exec`, echo the tail. Do not read sources yourself.

## Build and run the Codex prompt

Substitute the placeholders below from the prompt you received (`{spec_path}`, `{docs_paths}`, `{plan_path}`, `{language}`, `{domain_root}`, `{infra_root}`, `{features_root}`).

```bash
_codex_prompt=$(mktemp /tmp/critic-code-prompt-XXXXXX.txt)
_codex_log=$(mktemp /tmp/critic-code-log-XXXXXX.txt)
cat > "$_codex_prompt" <<EOF
You are an adversarial code reviewer. Find where this implementation violates the spec. Assume the code is wrong until proven otherwise. Read every file you need.

Evidence rule: before reporting any blocking finding ([CRITICAL], [MISSING], [FAIL],
[DOCS CONTRADICTION], [UNVERIFIED CLAIM]), read the exact file:line and confirm the
text is present. If not present, drop the finding. No uncited findings.

Spec: {spec_path}
Docs: {docs_paths}
Plan: {plan_path}

Read these reference files first — they govern your output:
- ${CLAUDE_PROJECT_DIR}/.claude/reference/severity.md   (severity levels, PASS/FAIL threshold, category priority)
- ${CLAUDE_PROJECT_DIR}/.claude/reference/layers.md     (forbidden imports, acceptable exceptions)

## Angle 1 — Spec compliance

For every Scenario in spec.md:
1. Given condition handled correctly?
2. When action has a corresponding code path?
3. Then outcome produced reliably?
4. Scenario Outline — all Examples rows including boundaries handled?
5. Failure scenarios — error paths implemented?
6. Large feature: implementation calls domain directly instead of composing small features? (→ [CRITICAL])

Compare against docs/*.md. If implementation or spec contradicts documented domain knowledge, report [DOCS CONTRADICTION] (do not auto-resolve).

7. Unverified API usage: code calls an external library method not already used in the project? (→ [UNVERIFIED CLAIM])
8. Hardcoded external facts: URLs, model names, version strings, magic numbers from outside the project? (→ [WARN])

Test coverage and mocking are out of scope here — critic-test owns them.

## Angle 2 — Layer boundary

Run the language-specific boundary checker:
\`\`\`bash
bash "${CLAUDE_PROJECT_DIR}/.claude/scripts/critic-code/run.sh" {language} {domain_root} {infra_root} {features_root}
\`\`\`
If no language dispatcher matches, run the generic fallback:
\`\`\`bash
grep -rn "infrastructure\|features" {domain_root}/ 2>/dev/null | grep -v "^Binary"
grep -rn "features" {infra_root}/ 2>/dev/null | grep -v "^Binary"
\`\`\`
For each hit, decide violation vs. acceptable per layers.md §Acceptable import exceptions. When in doubt, [WARN] not [CRITICAL].

## Output format

\`\`\`
## critic-code Review

### Angle 1 — Spec Compliance
[CRITICAL] Scenario "{name}": {spec vs actual}
  File: {path}:{line}
  Fix: {action}
[DOCS CONTRADICTION] {what} vs {docs}
  Files: {path} ↔ {docs path}
[WARN] {advisory}
None: "All scenarios correctly implemented"

### Angle 2 — Layer Boundary
[CRITICAL] {file}:{line} — {violation}
  Fix: {action}
[WARN] {file}:{line} — {potential violation}
None: "No layer boundary violations"

### Citation Summary
(one line per blocking finding — omit if PASS)
- {tag} @ {file}:{line}: "{verbatim excerpt, max 80 chars}"
\`\`\`

## Category mapping

- Layer boundary violation (Angle 2)            → LAYER_VIOLATION
- Large feature calls domain directly (1.6)     → LAYER_VIOLATION
- Docs contradiction                             → DOCS_CONTRADICTION
- Unverified API usage (1.7)                     → UNVERIFIED_CLAIM
- Spec compliance gap (1.1–1.5)                  → SPEC_COMPLIANCE

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
<!-- category: {one of LAYER_VIOLATION | DOCS_CONTRADICTION | UNVERIFIED_CLAIM | SPEC_COMPLIANCE | MISSING_SCENARIO | TEST_INTEGRITY | TEST_QUALITY | STRUCTURAL} -->

A FAIL without a category marker is recorded as PARSE_ERROR. When evidence is ambiguous, FAIL (false PASS costs 10×, false FAIL costs 1×).
EOF

codex exec --full-auto - < "$_codex_prompt" > "$_codex_log" 2>&1
_codex_exit=$?
echo "=== Codex critic-code exit: $_codex_exit ==="
tail -200 "$_codex_log"
rm -f "$_codex_prompt" "$_codex_log"
```

The verdict markers in the tail are your final stdout. The SubagentStop hook reads `<!-- verdict: -->` and `<!-- category: -->` from there. Do not append anything after the `tail -200` output.
