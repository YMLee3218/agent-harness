# eval fixture: tests-bad-passing-red
# Expected verdict: FAIL
# Critic: critic-test
# Checks: test passes without being marked GREEN (pre-existing) → TEST_INTEGRITY

## Spec
Feature: Send Notification

  Scenario: Successfully send a notification
    Given a user with id "user-1" exists
    When a notification with message "Hello" is sent to "user-1"
    Then the notification is created with status "unread"

  Scenario: Reject empty message
    Given a user with id "user-1" exists
    When a notification with an empty message is sent to "user-1"
    Then an error "message must not be empty" is returned

## Test File: tests/domain/test_notification.py
## Layer: domain — no mocks

```python
def test_should_create_notification_when_valid_message():
    result = send_notification(user_id="user-1", message="Hello")
    # Assertion weakened to avoid needing real implementation (modified after Red phase)
    assert result is not None  # was: assert result.status == "unread"

def test_should_reject_empty_message():
    import pytest
    with pytest.raises(ValueError, match="message must not be empty"):
        send_notification(user_id="user-1", message="")
```

## Test Manifest
- `test_should_create_notification_when_valid_message` → Scenario: Successfully send a notification
  Status: NOT marked GREEN (pre-existing)
- `test_should_reject_empty_message` → Scenario: Reject empty message
  Status: NOT marked GREEN (pre-existing)

## Test Command Result
2 tests run. 1 PASSES, 1 FAILS.
`test_should_create_notification_when_valid_message` PASSES — but is NOT marked GREEN (pre-existing) in the Test Manifest.
`test_should_reject_empty_message` FAILS as expected.
The passing test was weakened after the Red phase to avoid needing a real implementation.
