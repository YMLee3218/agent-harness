# Operating Envelope

Single source of truth for the six envelope axes and their legal values.
Referenced by writing-spec, brainstorming, critic-spec, and critic-cross.

## Axis table

| Axis | Legal values |
|------|-------------|
| **Actors** | `1 user` \| `N users` \| `tenants` |
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
