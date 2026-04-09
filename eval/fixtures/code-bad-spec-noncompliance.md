# eval fixture: code-bad-spec-noncompliance
# Expected verdict: FAIL
# Critic: critic-code
# Checks: implementation does not cover a spec scenario — SPEC_COMPLIANCE

## Spec: src/features/add-todo/spec.md
Feature: Add Todo

  Scenario: Successfully add a todo
    Given a valid title and user id
    When a todo is added
    Then the todo is saved with status "pending"

  Scenario: Reject empty title
    Given an empty title
    When a todo is added
    Then an error is returned with message "Title cannot be empty"

## Docs: docs/todo.md
Domain rule: a Todo requires a non-empty title. The domain must enforce this invariant.

## Implementation: src/features/add-todo/index.ts
```typescript
import { Todo } from '../../domain/todo';
import { todoRepository } from '../../infrastructure/todo-repository';

export async function addTodo(userId: string, title: string): Promise<Todo> {
  const todo = new Todo(userId, title, 'pending');
  await todoRepository.save(todo);
  return todo;
}
```

## Layer Analysis
- src/features/add-todo/index.ts imports from domain (Todo) and infrastructure (todoRepository) — layer boundaries OK

## Spec Coverage
- Scenario "Successfully add a todo": covered
- Scenario "Reject empty title": NOT covered — no validation for empty title; empty strings will be silently accepted
