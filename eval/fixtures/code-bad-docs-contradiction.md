# eval fixture: code-bad-docs-contradiction
# Expected verdict: FAIL
# Critic: critic-code
# Checks: implementation contradicts docs — DOCS_CONTRADICTION

## Spec: src/features/send-notification/spec.md
Feature: Send Notification

  Scenario: Notify user on task completion
    Given a completed task
    When the system sends a notification
    Then the user receives an email at their registered address

## Docs: docs/notification.md
Domain rule: notifications are always sent to the user's verified primary email address.
A user may have multiple email addresses but only the primary (verified) one is used for system notifications.

## Implementation: src/features/send-notification/index.ts
```typescript
import { getUserEmails } from '../get-user-emails';
import { emailClient } from '../../infrastructure/email';

export async function sendNotification(userId: string, message: string) {
  const emails = await getUserEmails(userId);
  // Send to ALL user emails instead of primary only
  for (const email of emails) {
    await emailClient.send({ to: email, body: message });
  }
}
```

## Layer Analysis
- src/features/send-notification/index.ts imports from features (get-user-emails) and infrastructure (emailClient) — layer boundaries OK
- No cross-layer violations detected

## Docs Contradiction
- docs/notification.md states: "only the primary (verified) one is used for system notifications"
- Implementation sends to ALL email addresses — contradicts the documented domain rule
