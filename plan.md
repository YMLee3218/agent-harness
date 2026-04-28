# Plan — iter=132

## Real issues

1. **workspace/agents/coder.md:6** — `tools:` field includes `Skill` but the coder workflow (Steps 1–5) never invokes any skill. The coder orchestrates Codex for single-task implementation; having `Skill` available could allow scope violations (invoking brainstorming, writing-spec, etc.). No other agent definition has an explicit `tools:` field with `Skill`. Fix: remove `Skill` from the tools list.
