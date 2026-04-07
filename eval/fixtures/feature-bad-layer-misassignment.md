# Requirements: Todo Management (bad — layer misassignment)

## Small Features
- `todo` — stores todo items in the database (domain concept placed as feature; DB concern in domain)
- `AddTodo` — creates a new todo item (PascalCase, not kebab-case)
- `manage-todo-workflow` — calls domain.todo directly to create and complete (large feature calling domain directly)

## Domain Concepts
- `send-notification` — sends email via SMTP (infrastructure concern in domain; verb-noun instead of noun)
