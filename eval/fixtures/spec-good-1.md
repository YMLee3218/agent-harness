Feature: Add Todo

  Scenario: Successfully add a todo
    Given a user with id "user-1"
    When the user adds a todo with title "Buy milk"
    Then a todo is created with title "Buy milk" and status "pending"
    And the todo is owned by "user-1"

  Scenario: Reject empty title
    Given a user with id "user-1"
    When the user adds a todo with title ""
    Then an error "title cannot be empty" is returned
    And no todo is created

  Scenario: Reject title exceeding max length
    Given a user with id "user-1"
    When the user adds a todo with title of 256 characters
    Then an error "title too long" is returned

  Scenario Outline: Title boundary validation
    Given a user with id "user-1"
    When the user adds a todo with title of <length> characters
    Then the result is <outcome>

    Examples:
      | length | outcome         |
      | 0      | error           |
      | 1      | success         |
      | 255    | success         |
      | 256    | error           |
