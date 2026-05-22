# Operating Envelope

Single source of truth for the six envelope axes and their legal values.
Referenced by writing-spec, brainstorming, critic-spec, and critic-cross.

## Axis table

| Axis | Legal values |
|------|-------------|
| **Actors** | `1 user` \| `N users` \| `tenants` \| `concurrent instances` |
| **Frequency** | `one-shot` \| `periodic 1/min` \| `per-request` \| `bursty` |
| **Concurrency** | `none` \| `reader-writer` \| `multi-writer` \| `exclusive-writer` |
| **Persistence** | `ephemeral` \| `best-effort` \| `durable` \| `zero-loss` |
| **Failure model** | `crash-stop` \| `crash-recover` \| `partial-failure` |
| **External I/O** | `none` \| `file` \| `network` \| `distributed` — or comma-separated compound (e.g., `network, file`) when a feature genuinely touches multiple surfaces |

## Filled vs placeholder

- **Placeholder**: the raw template literal `{a | b | c}` with curly braces still present in the spec.
  Example: `- **Actors**: {1 user | N users | tenants}` — curly braces not replaced → placeholder.

- **Filled**: one legal value from the table above has been selected.
  Example: `- **Actors**: N users` — curly braces replaced with a chosen value → filled.

`N users` is the filled value meaning "multiple users acting independently" (distinct from `tenants`,
which implies isolated data partitions). The `N` is a category label, not an unknown quantity.
It is **not** a placeholder. Do not report `N users` as undeclared or ambiguous.

`concurrent instances` means the actor is a system process replicated across deployments, with no
user identity (e.g., a scheduled cron job or autonomous polling loop). Distinct from `N users`:
no authentication, ownership, or user-id-based isolation scenarios apply.

`exclusive-writer` means at most one writer proceeds at a time; concurrent callers receive a
skip signal (e.g., lock-unavailable) rather than blocking and waiting. Distinct from `multi-writer`
(concurrent writes allowed) and `none` (no concurrent callers expected).

## Envelope axis compatibility

When `critic-cross` Angle 7 compares two interacting features' envelopes (handoff,
composition, or state-transition relationship), the rules below apply per axis. All
rules assume the caller-callee direction has been identified from spec text. For
bidirectional handoff (no strict direction, e.g. shared store), apply the
direction-symmetric variant noted per axis.

### Partial-order axes (Frequency, Concurrency, Persistence, Failure model)

These four axes have natural ordering. Rule: `callee.value ≥ caller.value` (the
callee must withstand or honor at least the level the caller demands). Violation
→ ENVELOPE_MISMATCH.

| Axis | Partial order (low → high) | Rationale |
|------|-----------------------------|-----------|
| Frequency | `one-shot < periodic 1/min < per-request < bursty` | callee must withstand caller's invocation rate |
| Concurrency | `none < exclusive-writer < reader-writer < multi-writer` | callee must accept caller's concurrency level (exclusive-writer accepts concurrent calls but serializes via skip; reader-writer accepts concurrent reads; multi-writer accepts concurrent writes). Exception: `exclusive-writer` callee is CONTEXT (not automatic MISMATCH) when caller is `reader-writer` or `multi-writer` — the callee gates concurrent callers via skip signal; verify the caller handles `lock-unavailable` in the spec text before reporting MISMATCH. |
| Persistence | `ephemeral < best-effort < durable < zero-loss` | callee must preserve data at least as strongly as caller's promise |
| Failure model | `crash-stop < crash-recover < partial-failure` | callee must handle failure at least as robustly as caller assumes |

Bidirectional handoff variant: require `caller.value == callee.value` (no
direction → no broader/narrower distinction).

### Actors lookup (no natural partial order)

The Actors axis encodes user-identity scope, which is not totally ordered.
Compatibility per (caller, callee) pair:

| caller \\ callee     | 1 user   | N users   | tenants  | concurrent instances |
|----------------------|----------|-----------|----------|----------------------|
| 1 user               | OK       | MISMATCH  | MISMATCH | OK                   |
| N users              | OK       | OK        | CONTEXT  | OK                   |
| tenants              | MISMATCH | MISMATCH  | OK       | OK                   |
| concurrent instances | OK*      | MISMATCH  | CONTEXT  | OK                   |

Legend:
- **MISMATCH**: structurally incompatible (callee scope wider than caller can
  supply, or boundary lost).
- **CONTEXT**: outcome depends on spec text. The critic must verify whether
  the tenant boundary is preserved through the call: preserved → OK, not
  preserved → MISMATCH. If ambiguous, report as MISMATCH with a citation
  asking the spec to clarify the boundary.
- **OK***: only valid if the callee's spec body shows a system-invocation path
  (no user identity required). If callee requires user identity, treat as
  MISMATCH.

Bidirectional handoff variant for Actors: require `caller.value == callee.value`
(no direction → cannot apply asymmetric rules above).

### External I/O (compound + direction-aware subset)

External I/O is the only axis permitting comma-separated compound values
(see §Axis table). Compatibility:

- Parse each spec's External I/O as a set: single value → singleton set; compound
  → split on `,` and trim; `none` → empty set ∅.
- Direction-aware rule: `callee.surfaces ⊆ caller.surfaces` (every surface the
  callee touches must be exposed through the caller's envelope). Violation →
  ENVELOPE_MISMATCH.
- `caller = none` + `callee ≠ none` → MISMATCH (caller exposes no I/O but callee
  uses some).
- `caller ≠ none` + `callee = none` → OK (callee touches no surface).
- Bidirectional handoff variant: require `caller.surfaces ∩ callee.surfaces ≠ ∅`
  (some common surface exists as the handoff medium).
