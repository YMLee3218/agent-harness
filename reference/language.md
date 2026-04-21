## Language Rules

**Match the user's conversation language. Default: Korean.**

Applies to user-facing output: `AskUserQuestion` text, `ExitPlanMode` summaries, critic verdict explanations, conversation replies, runtime narrative from agents (abort reports, error summaries).

**Always English regardless of conversation language**:
- Internal thinking and reasoning.
- File contents (plans, specs, docs, comments, tests).
- Research summaries and harness-internal prompts.
- Commit messages.
