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

### Axis semantic types

The four partial-order axes split into two semantic types:

- **Intrinsic axes** (Persistence, Failure model): the feature's value reflects its
  data-handling and failure-handling design. Per-feature design choice. Subject to the
  load-bearing exemption defined in §Promise distribution.

- **Propagated axes** (Frequency, Concurrency): a value is intrinsic only for **entry-point
  features** — features invoked from outside the system by an external invocation source
  (scheduler, HTTP request, user trigger, message queue). For **internal features** — those
  invoked only by other features in the system — these axes have no independent design
  freedom; their values are defined as `max(caller.value for each caller)` under the
  per-axis partial order in the table below. Authoring such a feature with any other value
  is a definition error, not a design tradeoff. Violation → `PROPAGATED_VALUE_OUT_OF_SYNC`
  (not `ENVELOPE_MISMATCH`).

A feature is **entry-point** iff at least one external invocation source is named in its
spec or in its grounding doc (docs/requirements/*.md). A feature is **internal** iff
invoked only by other features with no external invocation source. Mixed (both internal
callers and external sources) → treat as entry-point; the external source sets the
Frequency/Concurrency floor, and propagation applies as an additional lower bound
(`max(external, callers)`).

### Partial-order axes (Frequency, Concurrency, Persistence, Failure model)

These four axes have natural ordering. Rule: `callee.value ≥ caller.value` (the
callee must withstand or honor at least the level the caller demands). Violation
→ ENVELOPE_MISMATCH.

**Promise distribution**: Frequency and Concurrency apply uniformly to every callee — being called at rate R or under N-concurrency is intrinsic to being called at all. Persistence and Failure model are different: the caller's promise is satisfied by a specific load-bearing callee per data flow, and other callees handling distinct data streams do not need to honor it. For Persistence and Failure model, the critic must identify which callee carries caller's promised guarantee from spec text before applying the partial-order comparison.

| Axis | Partial order (low → high) | Rationale |
|------|-----------------------------|-----------|
| Frequency | `one-shot < periodic 1/min < per-request < bursty` | callee must withstand caller's invocation rate (propagated axis — for internal features the value is defined, not chosen; see §Axis semantic types) |
| Concurrency | `none < exclusive-writer < reader-writer < multi-writer` | callee must accept caller's concurrency level (propagated axis — for internal features the value is defined, not chosen; see §Axis semantic types). Exception: `exclusive-writer` callee is CONTEXT (not automatic MISMATCH) when caller is `reader-writer` or `multi-writer` — the callee gates concurrent callers via skip signal; verify the caller handles `lock-unavailable` in the spec text before reporting MISMATCH. |
| Persistence | `ephemeral < best-effort < durable < zero-loss` | the **load-bearing** callee (the one through which caller's promised-durable data flows) must preserve data at least as strongly as caller's promise. Other callees that handle distinct data streams (telemetry, observability, transform, validate) are not constrained by this rule. |
| Failure model | `crash-stop < crash-recover < partial-failure` | the **load-bearing** callee (whose failure would invalidate caller's promise) must handle failure at least as robustly as caller assumes. Side-channel callees whose failure is independent of caller's promise are not constrained by this rule. |

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
