#!/usr/bin/env bash
set -euo pipefail
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name // "Claude"')
DIR=$(echo "$input" | jq -r '.workspace.current_dir // ""')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'

if [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

FILLED=$((PCT / 10)); EMPTY=$((10 - FILLED))
BAR=$(printf "%${FILLED}s" | tr ' ' '█')$(printf "%${EMPTY}s" | tr ' ' '░')

MINS=$((DURATION_MS / 60000)); SECS=$(((DURATION_MS % 60000) / 1000))

BRANCH=""
if git rev-parse --git-dir > /dev/null 2>&1; then
  _b=$(git branch --show-current 2>/dev/null)
  [ ${#_b} -gt 24 ] && _b="${_b:0:22}…"
  BRANCH=" | 🌿 $_b"
fi

echo -e "${CYAN}[$MODEL]${RESET} 📁 ${DIR##*/}$BRANCH"
COST_FMT=$(printf '$%.2f' "$COST")
echo -e "${BAR_COLOR}${BAR}${RESET} ${PCT}% | ${YELLOW}${COST_FMT}${RESET} | ⏱️  ${MINS}m ${SECS}s"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
plan_file=$("$SCRIPTS_DIR/plan-file.sh" find-active 2>/dev/null)
_fa_rc=$?
if [ $_fa_rc -eq 3 ]; then
  echo "plan: ambiguous"
elif [ $_fa_rc -eq 4 ]; then
  echo "plan: malformed"
elif [ $_fa_rc -ne 0 ] || [ -z "$plan_file" ]; then
  echo "plan: none"
else
  phase=$("$SCRIPTS_DIR/plan-file.sh" get-phase "$plan_file" 2>/dev/null || echo "?")
  last_verdict=$(awk '
    /^## Critic Verdicts$/ { in_s=1; next }
    in_s && /^## /         { in_s=0 }
    in_s && /^- /          { line=$0 }
    END                    { sub(/^- /, "", line); print line }
  ' "$plan_file" 2>/dev/null)
  if [ -n "$last_verdict" ]; then
    line3=$(printf '%s | last: %s' "$phase" "$last_verdict")
  else
    line3=$(printf '%s | no verdicts yet' "$phase")
  fi
  [ ${#line3} -gt 50 ] && line3="${line3:0:48}…"
  printf '%s\n' "$line3"
fi
