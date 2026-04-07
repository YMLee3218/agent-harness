# eval fixture: code-bad-layer-violation
# Expected verdict: FAIL
# Critic: critic-code
# Checks: domain layer importing infrastructure — LAYER_VIOLATION

## Spec: domain/todo/spec.md
Feature: Todo Domain

  Scenario: Create a todo
    Given a title and a user id
    When a todo is created
    Then the todo is persisted with status "pending"

## Docs: docs/todo.md
Domain rule: a Todo represents a task. Domain layer must have no external dependencies.
Persistence is the responsibility of the infrastructure layer, not the domain.

## Implementation: src/domain/todo_repository.py
```python
from src.infrastructure.database import Database  # VIOLATION: domain imports infrastructure

class TodoRepository:
    def __init__(self):
        self.db = Database()  # domain directly instantiates an infrastructure component

    def save(self, todo):
        self.db.insert("todos", {
            "user_id": todo.user_id,
            "title": todo.title,
            "status": todo.status,
        })
```

## Layer Analysis
- src/domain/todo_repository.py imports from src.infrastructure.database — LAYER VIOLATION
  (domain must never import from infrastructure)
- This violates the documented domain rule: "Domain layer must have no external dependencies"
