#!/usr/bin/env bats
# markers.md ↔ sidecar.sh MARK_* constant sync lint.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"
REFERENCE_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/reference"

@test "R10: every MARK_* constant in sidecar.sh has its value documented in markers.md" {
  local sidecar="$SCRIPTS_DIR/lib/sidecar.sh"
  local markers="$REFERENCE_DIR/markers.md"
  [ -f "$sidecar" ] || skip "sidecar.sh not found"
  [ -f "$markers" ] || skip "markers.md not found"

  local missing=0
  while IFS= read -r line; do
    local name value
    name=$(printf '%s' "$line" | sed -E 's/^(MARK_[A-Z_]+)=.*/\1/')
    value=$(printf '%s' "$line" | sed -E 's/^MARK_[A-Z_]+="([^"]+)".*/\1/')
    if ! grep -qF "$value" "$markers"; then
      echo "MISSING from markers.md: ${name}=\"${value}\"" >&2
      missing=$((missing + 1))
    fi
  done < <(grep -E '^MARK_[A-Z_]+=' "$sidecar")
  [ "$missing" -eq 0 ]
}

@test "R10: no MARK_* constant in sidecar.sh is defined more than once" {
  local sidecar="$SCRIPTS_DIR/lib/sidecar.sh"
  [ -f "$sidecar" ] || skip "sidecar.sh not found"

  local dupes
  dupes=$(grep -oE '^MARK_[A-Z_]+=' "$sidecar" | sort | uniq -d)
  [ -z "$dupes" ]
}
