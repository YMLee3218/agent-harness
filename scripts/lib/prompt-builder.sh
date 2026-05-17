#!/usr/bin/env bash
# DATA delimiter wrapping for prompt injection prevention.
# Source this file to get wrap_user_data(); if unavailable, callers fall back to raw output.

wrap_user_data() {
  printf '<DATA>\n%s\n</DATA>' "$1"
}
