# Commit Policy

## Cycle commit splitting

Each cycle commit must be verifiably correct before it is recorded. Rules:

1. **One commit per phase group.** C (Critical), H (High), D (Deferred wiring), R (Refactor), and L (Cleanup) items are each committed separately. Do not bundle phases into a single commit.
2. **Claim ↔ code parity.** Before writing a commit message, grep the codebase to confirm every claim in the message is matched by the code. Forbidden: stating "X applied" when X is only sourced but not called, or "Y removed" when Y still appears.
3. **Test gate.** `bash scripts/run-tests.sh` must pass at zero failures before each commit. Record the passing test count in the commit message body.
4. **Size limit.** A single commit touching more than 30 files is a signal that phases were merged. Split and recommit.

## Message format

```
<phase-label>: <one-line summary>

- <item-id>: <what changed> (<file:line>)
- tests: <test count> ok, 0 failed
```

Example:
```
C3: GIT_* env deny list expansion

- C3: added GIT_SSH_COMMAND, GIT_EXTERNAL_DIFF, GIT_CONFIG_GLOBAL to pretooluse-capability-blocks.sh:109
- tests: 386 ok, 0 failed
```

## Why

18차 commit 78d05ed bundled 86 files / 8737+ lines across C, H, D, R, L items in a single commit. This made post-hoc audit impossible and produced 3 false-claim findings (R11/C7/R6) where commit message assertions did not match the actual diff.
