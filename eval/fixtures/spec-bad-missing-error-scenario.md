Feature: Add Todo

  Scenario: Successfully add a todo
    Given a user with id "user-1"
    When the user adds a todo with title "Buy milk"
    Then a todo is created with title "Buy milk" and status "pending"

  # Missing: empty title rejection
  # Missing: max-length boundary
  # Missing: duplicate title handling
  # Missing: concurrent add by same user
