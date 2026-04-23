## Language Rules

**Match the user's conversation language. Default: Korean.**

Applies to user-facing output: `AskUserQuestion` text, `ExitPlanMode` summaries, critic verdict explanations, conversation replies, runtime narrative from agents (abort reports, error summaries).

**Always English regardless of conversation language**:
- Internal thinking and reasoning.
- File contents (harness plan files, specs, docs, comments, tests).
- Research summaries and harness-internal prompts.
- Commit messages.

**Always in user's conversation language (Korean by default)**:
- Plan mode plan files (approval plans for the user to read).
