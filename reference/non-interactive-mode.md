# Non-Interactive Mode

The harness always operates in non-interactive mode. All skills write `[BLOCKED]` markers to `## Open Questions` instead of prompting the user with `AskUserQuestion`. The next session reads the markers and resumes.

`CLAUDE_NONINTERACTIVE=1` may be passed to autonomous runs for compatibility but has no additional effect — behavior is identical.

## Critic loop

- `[FIRST-TURN]`: auto-approve + re-run. Call `record-auto-approved`, then re-run the critic.
- `[BLOCKED-AMBIGUOUS]`: stop cleanly. Do not attempt fixes.
- Any other `[BLOCKED]` marker: stop cleanly.

Full branching protocol: `@reference/critics.md §Skill branching logic`.
