## Language Rules

**Match the user's conversation language. Default: Korean.**

Applies to user-facing output: `AskUserQuestion` text, `ExitPlanMode` summaries, conversation replies, runtime narrative from agents (abort reports, error summaries). Critic verdict outputs are excluded — they are machine-readable and must remain English regardless of conversation language. This covers all four phase-gate critics: `agents/critic-{code,spec,test}.md` output is copied verbatim from Codex; `agents/critic-feature.md` output is a Claude fork verdict but uses the same machine-readable HTML comment format.

When a skill file contains hard-coded English template text for an `AskUserQuestion` call (English as file content — see §Always English below), the executing agent must render the prompt in the conversation language, not verbatim.

**Always English regardless of conversation language**:
- Internal thinking and reasoning.
- File contents (harness plan files, specs, docs, comments, tests).
- Research summaries and harness-internal prompts.
- Commit messages.

**Always in user's conversation language (Korean by default)**:
- Plan mode plan files (approval plans for the user to read).
