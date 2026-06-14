## Language Rules

**Match the user's conversation language. Default: Korean.**

Applies to user-facing output: `AskUserQuestion` text, `ExitPlanMode` summaries, conversation replies, runtime narrative from agents (abort reports, error summaries). Critic verdict outputs are excluded — they are machine-readable and must remain English regardless of conversation language. This covers all five phase-gate critics. `critic-spec/test/code/cross`: Codex review verdict (via `run-critic-loop.sh` → `codex exec`, using `skills/critic-*/SKILL.md` templates) is machine-readable and stays English; on FAIL, the decision agent (`agents/critic-{code,spec,test,cross}.md` — Claude) produces structured AUDIT/FIX-PLAN output that also stays English. `critic-feature` (`agents/critic-feature.md`): Claude fork verdict in the same machine-readable HTML comment format.

When a skill file contains hard-coded English template text for an `AskUserQuestion` call (English as file content — see §Always English below), the executing agent must render the prompt in the conversation language, not verbatim. When generating `AskUserQuestion` content dynamically (not from a skill template), all question text and option labels must also be in the conversation language — never in English.

**Always English regardless of conversation language**:
- Internal thinking and reasoning.
- File contents (harness plan files, specs, docs, comments, tests).
- Research summaries and harness-internal prompts.
- Commit messages.

**Always in user's conversation language (Korean by default)**:
- Plan mode plan files (approval plans for the user to read).
