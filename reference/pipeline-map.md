# Pipeline Map

Single source of truth for the phase → skill → critic → next-phase flow.
Update this table whenever a new skill or phase is added.

| Phase | Entry skill | Critic | Pass → next phase | FAIL retry max | Escalation |
|-------|-------------|--------|-------------------|----------------|------------|
| brainstorm | brainstorming | critic-feature | spec | 2 | human |
| spec | writing-spec | critic-spec | red | 2 | human |
| red | writing-tests | critic-test | green | 2 | human |
| green / refactor | implementing | critic-code | integration | 2 | human |
| integration | running-integration-tests | — | done | — | route-back to spec/green |

## Notes

- **Retry max**: two consecutive same-category FAILs from the same critic trigger `[BLOCKED-CATEGORY]` in `## Open Questions` and require human intervention. Tracked by `plan-file.sh record-verdict`.
- **route-back**: integration failures are categorised (docs conflict / spec gap / implementation bug) and auto-route back to the appropriate phase. See `skills/running-integration-tests/SKILL.md` for the decision tree.
- **Profiles**: `trivial` and `patch` profiles skip phases. See `skills/running-dev-cycle/SKILL.md` for the profile matrix.
- **Critic isolation**: all `critic-*` skills run as subagents with `context: fork`; they cannot mutate state (Bash restricted to read-only dispatchers). Matched by the `SubagentStop` hook `matcher: "critic-.*"`.
