## Language Rules

**Match the user's conversation language. Default: Korean.**

Applies to user-facing output: `AskUserQuestion` text, `ExitPlanMode` summaries, conversation replies, runtime narrative from agents (abort reports, error summaries). Critic verdict outputs are excluded — they are machine-readable and copied verbatim from Codex per `agents/critic-{code,spec,test}.md` (English regardless of conversation language).

**Always English regardless of conversation language**:
- Internal thinking and reasoning.
- File contents (harness plan files, specs, docs, comments, tests).
- Research summaries and harness-internal prompts.
- Commit messages.

**Always in user's conversation language (Korean by default)**:
- Plan mode plan files (approval plans for the user to read).
