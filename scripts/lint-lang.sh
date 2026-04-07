#!/usr/bin/env bash
# lint-lang.sh — Detect Hangul (Korean) in LLM-facing prompt files.
#
# Policy: LLM-facing text (SKILL.md bodies, agent prompts, reference docs) must be in English.
#         User-facing text (stdout messages to humans) may be Korean.
#
# Files checked:
#   workspace/skills/*/SKILL.md      (body below frontmatter --- delimiter)
#   workspace/reference/*.md
#   workspace/agents/*.md            (if present)
#
# Exit 0 = no violations; exit 1 = Hangul found in LLM-facing content.

set -uo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
VIOLATIONS=0

# Hangul Unicode range: \uAC00-\uD7A3 (syllables) + \u1100-\u11FF (Jamo) + \u3130-\u318F (compatibility Jamo)
HANGUL_PATTERN='[\xAC\xAD\xAE\xAF\xB0\xB1\xB2\xB3\xB4\xB5\xB6\xB7\xB8\xB9\xBA\xBB\xBC\xBD\xBE\xBF\xC0\xC1\xC2\xC3\xC4\xC5\xC6\xC7\xC8\xC9\xCA\xCB\xCC\xCD\xCE\xCF\xD0\xD1\xD2\xD3\xD4\xD5\xD6\xD7]'

check_file() {
  local file="$1"
  local label="${file#$WORKSPACE/}"

  # For SKILL.md: only check body below the frontmatter --- delimiter
  # For other .md: check entire file
  local content
  if [[ "$file" == */SKILL.md ]]; then
    # Skip lines until second '---' (end of frontmatter), then check the rest
    content=$(awk '/^---$/{count++; if(count==2){found=1; next}} found{print}' "$file" 2>/dev/null)
  else
    content=$(cat "$file" 2>/dev/null)
  fi

  # Use Python for reliable Unicode detection (grep -P not available on macOS)
  if command -v python3 >/dev/null 2>&1; then
    local hits
    hits=$(printf '%s\n' "$content" | python3 -c "
import sys, re
lines = sys.stdin.read().splitlines()
for i, line in enumerate(lines, 1):
    if re.search(r'[\uAC00-\uD7A3\u1100-\u11FF\u3130-\u318F]', line):
        print(f'  line {i}: {line[:120]}')
" 2>/dev/null)
    if [ -n "$hits" ]; then
      echo "HANGUL DETECTED: $label"
      printf '%s\n' "$hits"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  else
    echo "SKIP: python3 not available for Unicode detection ($label)" >&2
  fi
}

echo "=== lang-lint: checking LLM-facing files for Hangul ==="

# Check skill bodies
while IFS= read -r f; do
  check_file "$f"
done < <(find "$WORKSPACE/skills" -name "SKILL.md" 2>/dev/null | sort)

# Check reference docs
while IFS= read -r f; do
  check_file "$f"
done < <(find "$WORKSPACE/reference" -name "*.md" 2>/dev/null | sort)

# Check agent prompts if directory exists
if [ -d "$WORKSPACE/agents" ]; then
  while IFS= read -r f; do
    check_file "$f"
  done < <(find "$WORKSPACE/agents" -name "*.md" 2>/dev/null | sort)
fi

echo ""
if [ "$VIOLATIONS" -eq 0 ]; then
  echo "OK: no Hangul found in LLM-facing files"
  exit 0
else
  echo "FAIL: $VIOLATIONS file(s) contain Hangul in LLM-facing content"
  exit 1
fi
