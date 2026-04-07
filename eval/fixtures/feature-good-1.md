# Requirements: Todo Management

## Small Features
- `add-todo` — creates a new todo item (domain: todo)
- `complete-todo` — marks a todo item as done (domain: todo)
- `list-todos` — returns all todos for a user (domain: todo)

## Large Features
- `manage-todo-workflow` — orchestrates add → assign → complete flow (composes small features)

## Domain Concepts
- `todo` — a task with title, status, owner
- `user` — a person who owns todos
