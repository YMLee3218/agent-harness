# BDD Scenario Templates

Used by `skills/writing-spec/SKILL.md §Rules` and `§Scenario templates`; reviewed by `skills/critic-spec/SKILL.md`.

## §Rules

- One `Feature:` block per file
- Every `Scenario Outline` must have `Examples:`
- No technology names (no DB engines, HTTP libraries, framework names)
- No implementation details in Given/When/Then steps
- Domain specs: no infrastructure operations in steps (DB, HTTP, queue, file I/O)
- One `Scenario:` per distinct flow; same flow + different values → `Scenario Outline`

## Basic scenario

```gherkin
Feature: {feature name}

  Scenario: {happy path description}
    Given {initial condition or context}
    When  {action taken}
    Then  {expected outcome}

  Scenario: {failure case description}
    Given {initial condition}
    When  {action that fails or edge case}
    Then  {expected error or outcome}
```

## Parameterised scenario

```gherkin
  Scenario Outline: {description covering multiple values}
    Given {condition with <param>}
    When  {action with <param>}
    Then  {outcome with <result>}

    Examples:
      | {param} | {result} |
      | value1  | result1  |
      | value2  | result2  |
```

## Required boundary coverage by input type

This rule applies to each `Scenario Outline` whose `Examples` parameterise an input of a type listed below. For such an Outline, every boundary value applicable to that input type must be **covered** — as a row in the Outline's `Examples` table, **OR**, when the boundary triggers a `Then` that diverges from the Outline's `Then` (a *distinct flow* per §Rules), as a dedicated `Scenario:`. When a boundary is relocated to a dedicated `Scenario:`, the Outline must be marked with a comment pointing to it (e.g. `# -1 boundary covered by Scenario "rejects negative quantity" — divergent flow`).

| Input type | Required boundary values |
|-----------|--------------------------|
| Numeric | zero (`0`), negative one (`-1`), maximum (`MAX_INT` or domain max) |
| Collection / list | empty (`[]`) |
| String | empty string (`""`), max-length string |
| Nullable / optional | `null` / `None` / absent |
| Boolean | `true`, `false` |

**Undocumented-max string:** When a String field has no documented maximum
length, the required "max-length" boundary is satisfied by a scenario that
asserts an extremely long string is accepted — its purpose is to verify that
the system imposes no undocumented cap. Write it as a dedicated `Scenario:`
(divergent intent from a normal-value Outline) with a `Then` of the form
"the input is accepted without truncation or rejection". This pattern is
**not** a DOCS_CONTRADICTION; it is an affirmative test of the absence of
an undocumented constraint. Document the absence with a comment in the spec
file (e.g., `# dedupe_key has no documented max length; extremely-long-string
scenario verifies no undisclosed cap is enforced`).

**Closed-enum exemption:** A column whose values form a closed enumeration
(i.e., every valid member is explicitly listed and no arbitrary string is a
valid input) is exempt from the String boundary rows, provided all three
conditions hold: (1) the value set is a closed enum with every member
enumerated, (2) values outside the enum cannot reach the system under test
as input, and (3) the column parameterises how the test precondition is
configured, not a string passed directly into the system under test.
Document the exemption with a comment in the spec file (e.g.,
`# initial_state is a closed enum whose rows enumerate the only shapes the
loader can observe; string-input boundary rows do not apply`).

**Cardinality-column exemption:** A column whose values are non-negative
integer counts of items in a collection (e.g., list length, set size, count
of entries in a persisted store, count of items in a returned response) is
categorised as Collection / list — *not* Numeric. Rationale: list cardinality
cannot be `-1` (unreachable), and `MAX_INT` falls into the same equivalence
class as any "many" representative, so Numeric boundary rows yield no new
information for such columns. Required boundary: `0` (the empty case). If the
domain documents a cardinality cap (per-collection, per-context, or system-
wide), the documented cap is an additional required boundary; otherwise no
upper boundary is required. Document the exemption with a comment in the
spec file (e.g., `# entry_count is a collection-cardinality column; Collection
rule applies — empty boundary covered by the 0 row`).
