# Blocked Guidance

When a dev-cycle or integration-test skill surfaces a `[BLOCKED:{kind}]` marker,
follow this protocol exactly — write all user-facing output in Korean (per `@reference/language.md` default).

---

## Presentation format

1. **Quote the marker** — verbatim, as it appears in the plan file
2. **Explain the block** — one sentence in Korean: what this kind means and what needs to change
3. **Resolution path** — in Korean: recommended path (fix root cause) first, workaround second
4. **Decision required** — if scope or root cause is ambiguous, use `AskUserQuestion` with choices

> Output language: all user-facing responses per this guide must be written in Korean.
> The `language.md` "Default: Korean" rule applies to all explanations, choices, and recommendations that follow the verbatim marker output.

---

## Per-kind guidance

| Kind | Meaning | Recommended resolution (root-cause first) | Anti-pattern |
|------|---------|-------------------------------------------|--------------|
| `envelope` | Operating Envelope in spec is incorrectly declared | 1. Fix the Envelope section → 2. `unblock` | Running `unblock` without fixing the Envelope |
| `docs` | Ground-truth contradiction between docs and spec/tests | 1. Decide which is correct (docs, spec, or tests) → 2. Fix → 3. `unblock` | Running `unblock` without resolving the contradiction |
| `spec` | Spec gap or ambiguity — human decision required | 1. Clarify the ambiguous spec item → 2. `unblock` | Running `unblock` with spec left as-is |
| `code` | Root-cause bug in code or tests | 1. Fix the actual defect in code/tests → 2. `unblock` | Running `unblock` without reviewing the code |
| `env` | Environment/session/tooling issue (persistent or recurring) | 1. Install missing tool or fix environment → 2. `unblock` | Bypassing with `unblock` without fixing the environment |
| `harness` | Harness call path, sidecar integrity, or reference-data extension needed | 1. Fix harness file or extend reference enum → 2. `unblock` | Running `unblock` without fixing the harness |
| `ceiling` | Critic loop ceiling exceeded — recurring failure needs fixing | 1. Fix root cause of recurring failure → 2. `reset-milestone {agent}` | Running `reset-milestone` alone without a fix; running `unblock` alone (`milestone_seq` not incremented → immediately re-blocked) |
| `transient` | ⚠️ Should not appear in plan.md — harness handles automatically | If marker is in plan.md, notify the harness maintainer instead of unblocking | Attempting to remove with `unblock` (intentionally unsupported) |

---

## Recommendation policy — no scope-bias

> **Core rule**: recommend based on **correctness of direction**, not size of change.

When option A (fix root cause, may be large scope) and option B (workaround, smaller scope) are both available:

- **Recommend A.**
- Present B only as: "temporary workaround — incurs technical debt; a root-cause fix (option A level) will still be required later."
- "Smaller scope", "faster", "resolves it immediately" are **not valid reasons to recommend** an option.

### Forbidden patterns (examples)

| Situation | Wrong recommendation | Correct recommendation |
|-----------|---------------------|------------------------|
| `[BLOCKED:ceiling]` | "Just run `reset-milestone`" | "Fix the root cause of the recurring failure, then run `reset-milestone`" |
| `[BLOCKED:code]` | "Run `unblock` to proceed" | "Fix the code bug, then run `unblock`" |
| `[BLOCKED:spec]` | "Unblock and continue" | "Clarify the ambiguous spec item, then run `unblock`" |

---

## Anti-avoidance rule

`unblock` and `reset-milestone` are **follow-on commands to run after fixing the root cause**.
Running these commands without reviewing and fixing the underlying issue is an anti-pattern.
When presenting them as an option, always label them "temporary workaround".

```
Recommended order: [identify cause] → [fix] → [unblock or reset-milestone]
Anti-pattern:      [unblock or reset-milestone]  (immediately, without a fix)
```

Follow-on command reference: `@reference/markers.md §Clearing stop markers`
