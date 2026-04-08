# Requirements: Notification Service (bad — layer misassignment)

## Small Features
- `send-notification` — writes notification record to Postgres directly (infrastructure concern in feature; bypasses domain)
- `NotificationManager` — manages all notification state (PascalCase; unclear layer; god object)
- `manage-notification-workflow` — calls domain.notification.create() directly (large feature bypassing small features to call domain)

## Domain Concepts
- `send-email` — sends email via SMTP server (infrastructure concern placed in domain; verb-noun instead of noun)
- `notification-repository` — database repository (infrastructure concern placed in domain)
