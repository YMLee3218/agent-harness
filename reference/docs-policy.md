# Library Documentation Policy

## Rule

Before using an external library API in a spec, test, or implementation, verify the API via context7. Do not rely on training-data knowledge for library behaviour — APIs change between versions.

## When this applies

- `writing-spec`: any `Given/When/Then` that describes calling a third-party library method
- `implementing`: any new import of a library not already used in the project
- `writing-tests`: any test that stubs or mocks a library interface

## How to verify

```
/context7-plugin:docs {library-name}
```

or from a skill/agent context:

```
Skill("context7-plugin:docs", "{library-name}")
```

Fetch the specific method or module you intend to use. Confirm the signature and return type match your usage before writing code.

## What to do on mismatch

If the fetched docs differ from your draft spec/code:

1. Update the draft to match the current API.
2. If the mismatch reveals a design problem (e.g., the library no longer supports the approach), surface it to the user with `AskUserQuestion` before continuing.

## Exemptions

- Standard-library functions in the project's language (no lookup needed).
- Library methods already used and tested in the project codebase (current usage is the reference).
- Pinned version with lockfile: fetch docs for the pinned version, not latest.
