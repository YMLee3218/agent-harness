# Verification Policy

## Principle

Do not assert facts from training data alone. Training data has a cutoff; information may be outdated, incomplete, or wrong. Verify before stating.

## Rules

### R1 — Non-existence claims

Never assert that a tool, model, API, CLI flag, feature, or concept "does not exist" or "is not available" without first verifying via WebSearch, WebFetch, context7, or the tool's `--help`.

### R2 — Library/framework APIs

Before using an external library API in a spec, test, or implementation, verify the API via context7. Do not rely on training-data knowledge for library behaviour — APIs change between versions.

**When this applies:**
- `writing-spec`: any `Given/When/Then` that describes calling a third-party library method
- `implementing`: any new import of a library not already used in the project
- `writing-tests`: any test that stubs or mocks a library interface

**How to verify:**
```
/context7-plugin:docs {library-name}
```
or from a skill/agent context:
```
Skill("context7-plugin:docs", "{library-name}")
```

Fetch the specific method or module you intend to use. Confirm the signature and return type match your usage before writing code.

**On mismatch:** update the draft to match the current API. If the mismatch reveals a design problem, surface it to the user with `AskUserQuestion` before continuing.

**Exemptions:**
- Standard-library functions in the project's language (no lookup needed).
- Library methods already used and tested in the project codebase (current usage is the reference).
- Pinned version with lockfile: fetch docs for the pinned version, not latest.

### R3 — Domain facts

Domain rules, thresholds, regulatory requirements, and business constraints must come from `docs/*.md`. If a scenario requires a domain fact not present in `docs/`, ask the user — do not invent it.

### R4 — External facts (models, services, versions)

When referencing specific model names, service versions, pricing, or release dates, verify via WebSearch before stating. If verification is not possible, qualify with "based on training data as of [cutoff], verify current status."
