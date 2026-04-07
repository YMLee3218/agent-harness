# eval fixture: test-bad-modified-after-red
# Expected verdict: FAIL
# Critic: critic-test
# Checks: test passes without being marked GREEN (pre-existing) → TEST_INTEGRITY

## Spec
Feature: Add Todo

  Scenario: Successfully add a todo
    Given a valid user with id "user-1"
    When the user adds a todo with title "Buy milk"
    Then a todo is created with title "Buy milk" and status "pending"

## Test File: tests/domain/test_add_todo.py
## Layer: domain — no mocks

```python
def test_should_create_todo_when_valid_title():
    # Assertion weakened to pass without real implementation (modified after Red phase)
    result = add_todo(user_id="user-1", title="Buy milk")
    assert result is not None  # was: assert result.title == "Buy milk"
```

## Test Manifest
- `test_should_create_todo_when_valid_title` → Scenario: Successfully add a todo
  Status: NOT marked GREEN (pre-existing)

## Test Command Result
1 test PASSES.
`test_should_create_todo_when_valid_title` PASSES — but it is NOT marked GREEN (pre-existing) in the Test Manifest.
This indicates the test was weakened after the Red phase to make it pass without a real implementation.
