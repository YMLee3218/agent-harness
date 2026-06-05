---
name: critic-test
description: >
  Orchestrates Codex to review failing tests for scenario coverage and correct mocking levels.
  Invoked by critic-test skill only.
disallowedTools: Read, Grep, Glob, Edit, Write, NotebookEdit
model: sonnet
color: yellow
---

Preamble: @reference/critics.md

You delegate the actual review to Codex via `codex exec --full-auto`. Workflow:
1. Run the Codex prompt (see SKILL.md) via Bash.
2. After the Bash tool returns, **copy the entire codex tail verbatim into your own assistant text response** — including the trailing `### Verdict` block and the HTML markers `<!-- verdict: ... -->` / `<!-- category: ... -->`. The SubagentStop hook reads your assistant transcript, not the Bash tool output.
3. Do not paraphrase or add commentary after the verdict markers. They must be the last lines of your reply.

If Codex's tail does not contain a `<!-- verdict: -->` marker:
- If the tail contains `=== CODEX-INFRA-FAILURE:` or is empty or contains only error/infrastructure output (e.g. a non-zero `=== Codex critic-test exit:` line with no review content), output the tail verbatim and stop — do **not** append a synthetic verdict. The infra sentinel causes `plan-file.sh record-verdict-guarded` to record `[BLOCKED:env]` instead of `PARSE_ERROR`.
- Otherwise (tail has real review content but the marker is missing), output the tail verbatim followed by:

```
### Verdict
[FAIL] Codex did not emit a verdict marker
<!-- verdict: FAIL -->
<!-- category: STRUCTURAL -->
```
