# BDD Scenario Templates

Used by `skills/writing-spec/SKILL.md §Rules` and `§Scenario templates`; reviewed by `skills/critic-spec/SKILL.md`.

## §Rules

- One `Feature:` block per file
- Every `Scenario Outline` must have `Examples:`
- No technology names (no DB engines, HTTP libraries, framework names)
- No implementation details in Given/When/Then steps
- Domain specs: no DB, HTTP, queue, or file system references
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

## Required boundary rows by input type

Every `Scenario Outline` Examples table must include boundaries applicable to the input type:

| Input type | Required boundary values |
|-----------|--------------------------|
| Numeric | zero (`0`), negative one (`-1`), maximum (`MAX_INT` or domain max) |
| Collection / list | empty (`[]`) |
| String | empty string (`""`), max-length string |
| Nullable / optional | `null` / `None` / absent |
| Boolean | `true`, `false` |
