# eval fixture: code-good-1
# Expected verdict: PASS
# Critic: critic-code
# Checks: all spec scenarios correctly implemented, no layer boundary violations

## Spec: features/add-todo/spec.md
Feature: Add Todo

  Scenario: Successfully add a todo
    Given a valid user
    When the user adds a todo with title "Buy milk"
    Then a todo is created with title "Buy milk" and status "pending"

  Scenario: Reject empty title
    Given a valid user
    When the user adds a todo with an empty title ""
    Then an error "Title cannot be empty" is returned

## Docs: docs/todo.md
Domain rule: a Todo has a non-empty title string, an owner user_id, and a status of "pending" or "done".
The title must be validated before a Todo is created.

## Implementation: src/features/add_todo.py
```python
from src.domain.todo import Todo, validate_title

def add_todo(user_id: str, title: str) -> Todo:
    validate_title(title)
    return Todo(user_id=user_id, title=title, status="pending")
```

## Domain: src/domain/todo.py
```python
class Todo:
    def __init__(self, user_id: str, title: str, status: str):
        self.user_id = user_id
        self.title = title
        self.status = status

def validate_title(title: str) -> None:
    if not title:
        raise ValueError("Title cannot be empty")
```

## Layer Analysis
- src/features/add_todo.py imports from src/domain/todo — CORRECT (features → domain allowed)
- src/domain/todo.py has no imports from src/infrastructure or src/features — CORRECT

## Test Coverage
- test_should_create_todo_when_valid_title → covers Scenario: Successfully add a todo
- test_should_reject_empty_title → covers Scenario: Reject empty title
- Domain tests: no mocks (pure function) — CORRECT mocking level
