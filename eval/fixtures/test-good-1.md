# eval fixture: test-good-1
# Expected verdict: PASS
# Critic: critic-test
# Checks: all scenarios covered, correct mocking level (domain — no mocks), all tests fail

## Spec
Feature: Add Todo

  Scenario: Successfully add a todo
    Given a valid user with id "user-1"
    When the user adds a todo with title "Buy milk"
    Then a todo is created with title "Buy milk" and status "pending"

  Scenario: Reject empty title
    Given a valid user with id "user-1"
    When the user adds a todo with an empty title ""
    Then an error "Title cannot be empty" is returned

## Test File: tests/domain/test_add_todo.py
## Layer: domain — no mocks required (pure function, no external dependencies)

```python
import pytest
from src.domain.todo import add_todo, ValidationError

def test_should_create_todo_when_valid_title():
    result = add_todo(user_id="user-1", title="Buy milk")
    assert result.title == "Buy milk"
    assert result.status == "pending"

def test_should_reject_empty_title():
    with pytest.raises(ValidationError, match="Title cannot be empty"):
        add_todo(user_id="user-1", title="")
```

## Test Manifest
- `test_should_create_todo_when_valid_title` → Scenario: Successfully add a todo → FAIL (no implementation)
- `test_should_reject_empty_title` → Scenario: Reject empty title → FAIL (no implementation)

## Test Command Result
All 2 tests FAIL — ImportError: No module named 'src.domain.todo'
No tests pass unexpectedly.
