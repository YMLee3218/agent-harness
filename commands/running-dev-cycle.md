Run the full TDD development cycle (brainstorming → spec → tests → implementation).

Delegates to the `running-dev-cycle` skill. See `skills/running-dev-cycle/SKILL.md` for full documentation.

## Profiles

Select the profile that matches the scope of the change via `--profile {name}`:

| Profile | Flag | When to use |
|---------|------|-------------|
| `trivial` | `--profile trivial` or `--trivial` | Single-file typo/comment fix that cannot affect behaviour |
| `patch` | `--profile patch` | Bug fix or small bounded change |
| `feature` | `--profile feature` *(default)* | New feature or behaviour change |
| `greenfield` | `--profile greenfield` | New project or major domain rewrite |

Use the simplest profile that is safe. When in doubt, omit `--profile` (defaults to `feature`).

## Other flags

- `--batch` — write all specs before any tests (enabled automatically by `greenfield`; opt-in for other profiles)
