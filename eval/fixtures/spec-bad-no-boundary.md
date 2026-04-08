Feature: Send Notification

  Scenario: Successfully send a notification
    Given a user with id "user-1" exists
    When a notification with message "Hello" is sent to "user-1"
    Then the notification is created with status "unread"

  # Missing: what happens when the user does not exist
  # Missing: what happens when the message is empty
  # Missing: what happens when the message exceeds max length
  # Missing: concurrent sends to the same user
  # Missing: send to a user who has notifications disabled
