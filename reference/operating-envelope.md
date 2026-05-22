# Operating Envelope

Single source of truth for the six envelope axes and their legal values.
Referenced by writing-spec, brainstorming, critic-spec, and critic-cross.

## Axis table

| Axis | Legal values |
|------|-------------|
| **Actors** | `1 user` \| `N users` \| `tenants` \| `concurrent instances` |
| **Frequency** | `one-shot` \| `periodic 1/min` \| `per-request` \| `bursty` |
| **Concurrency** | `none` \| `reader-writer` \| `multi-writer` |
| **Persistence** | `ephemeral` \| `best-effort` \| `durable` \| `zero-loss` |
| **Failure model** | `crash-stop` \| `crash-recover` \| `partial-failure` |
| **External I/O** | `none` \| `file` \| `network` \| `distributed` |

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
