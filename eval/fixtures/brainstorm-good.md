# Requirements: Notification Service

## Small Features
- `send-notification` — dispatches a notification to a user (domain: notification)
- `mark-notification-read` — marks a notification as read (domain: notification)
- `list-notifications` — returns all unread notifications for a user (domain: notification)

## Large Features
- `manage-notification-workflow` — orchestrates send → retry → archive flow (composes small features only)

## Domain Concepts
- `notification` — a message with recipient, content, status (unread/read/archived)
- `user` — a person who receives notifications
