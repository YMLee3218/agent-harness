# Enforcement Tiers

## Overview

Harness protections are organized into two tiers. **Only Tier 1 provides structural guarantees.** Tier 2 is UX-only and does not need to be bypass-proof.

## Tier 1 — AUTHORITATIVE (Kernel-enforced)

**Mechanism**: macOS Seatbelt (`sandbox-exec`) wraps every leaf worker spawn (Claude and Codex sessions) via `scripts/lib/sandbox-lib.sh`. The sandbox profile (`scripts/worker.sb`) enforces write-deny at the OS syscall level. All subprocesses inherit the restriction.

**Write model**: allow project root (`PROJ_ROOT` subpath — open set covering `src/`, `tests/`, `docs/`, `domain/`, `features/`, `infrastructure/`, `plans/*.md`, etc.), then explicitly deny the control paths below (closed set; Seatbelt last-match-wins).

**Protected paths** (denied by explicit deny rules — workers cannot write these regardless of command form):
- `plans/*.phase` (`PLANS_PHASE_REGEX`) — phase authority files
- `plans/*.state/` (`PLANS_STATE_REGEX`) — sidecar control state
- `.claude-harness/` (`PROJ_HARNESS` subpath) — `scripts/`, `reference/`, `settings.json`, `CLAUDE.md`, `history.md`, `agents/`, `skills/`
- `CLAUDE.md` (`PROJ_CLAUDE_MD` literal) — workspace CLAUDE.md
- `.git` (`PROJ_GITFILE` literal) — gitdir pointer

**Bypass is structurally impossible** for confined worker processes: Bash redirect (`>`), `python -c "open(...).write(...)"`, `sed -i`, `find -exec`, and `codex exec` all hit the same kernel EPERM. The attack surface is closed.

**Git commit ownership**: the `test(red):` commit (and all other commits) are made by the orchestrator (`dev-cycle-phases.sh`), not by workers. Workers leave files in the working tree only. This avoids exposing `git common dir` (which lives outside `PROJ_ROOT`) as a required Tier 1 write surface.

**Note on `claude` worker `sandbox.enabled`**: the claude worker runs under the external Seatbelt profile only. `settings.json` keeps `sandbox.enabled: false` intentionally — the internal sandbox would also restrict interactive human sessions, which is undesirable. Single external Seatbelt enforcement is the design.

**Note on timeout-prefixed spawn sites**: `timeout`/`gtimeout` exec their first argument as a binary via `execvp`, so they cannot invoke `worker_exec` (a bash shell function). Spawn sites that carry a timeout prefix (`${TIMEOUT_CMD:+…}`) must use `"${_WORKER_SANDBOX_ARGS[@]}"` array expansion directly, preceded by a `_sandbox_guard` call for fail-closed behaviour. `worker_exec` is reserved for timeout-free spawn sites (`run-merge-gate.sh`, `llm-runner.sh`). Timeout-prefixed array+guard sites: `implement-helpers.sh`, `integration-helpers.sh`, `run-critic-loop.sh` (codex spawns).

**When Tier 1 is absent** (non-macOS, `sandbox-exec` unavailable, or `worker.sb` missing): the harness is **fail-closed by default**. `_init_worker_sandbox` sets `_SANDBOX_REQUIRED_FAIL=1`; each calling script (`run-implement.sh`, `run-critic-loop.sh`, `run-integration.sh`, `run-merge-gate.sh`, `run-dev-cycle.sh`) checks this flag immediately after the call and exits with `[BLOCKED:env] sandbox: tier1-unavailable`. Workers are NOT spawned. To opt out of this requirement (e.g., Linux CI or development environments without Seatbelt), set `CLAUDE_ALLOW_UNSANDBOXED=1`; only the orchestrator process can set this env var before spawning workers, so adversarial workers cannot self-grant the override. Linux Tier 1 equivalent (bubblewrap) is not yet implemented; Linux runs require `CLAUDE_ALLOW_UNSANDBOXED=1`.

**Profile completeness**: run with `SANDBOX_DENY_LOG=1` to surface residual EPERM hits after the first dry-run.

## Tier 2 — BEST-EFFORT-NUDGE (Software-level)

**Mechanism**: regex-based pattern matching in shell hooks (`phase-gate.sh`, `pretooluse-blocks.sh`, `pretooluse-bash.sh`) and Claude Code `permissions.deny` rules. These intercept common tool patterns and provide immediate error messages.

**Known bypass gaps** (documented, accepted):
- No-destination Bash commands (`touch`, `exec`, stdin-redirect patterns) are not intercepted by `pretooluse-bash.sh`.
- `phase-gate.sh`'s `_guard_plan_phase_mutation` is a UX nudge only — phase authority has moved to `plans/{slug}.phase` (Tier 1 protected).
- `pretooluse-blocks.sh` covers common redirect/copy/move patterns but not every possible syntax variation.

**Purpose**: immediate error message to the agent on accidental misuse (defense-in-depth). NOT a security boundary. Does not require bypass-proofing.

## Reviewer Guidance (harness-builder review agents)

When Tier 1 is operative (`sandbox-exec` available and `worker_exec` wrapping is present at all spawn points), nudge-layer bypass findings are **not real issues**:

- Phase-gate regex misses (`_guard_plan_phase_mutation` edge cases) → **NOISSUE**
- `pretooluse-blocks.sh` pattern gaps → **NOISSUE**
- Ring C `_guard_ring_c` regex edge cases → **NOISSUE**

Report as real issues **only**:
1. A path or command form that defeats the Tier 1 `sandbox-exec` profile itself (e.g., exploits a Seatbelt escape or a `worker.sb` allowWrite path that accidentally covers a protected path).
2. A spawn site that calls `claude` or `codex` without `worker_exec` wrapping — leaving that worker outside the Tier 1 boundary.

Record Tier 2 bypass findings that do NOT breach Tier 1 as:
```
result=NOISSUE | <agent> | <file:line> | <finding keyword> — Tier 2 nudge bypass; Tier 1 kernel sandbox covers this
```
