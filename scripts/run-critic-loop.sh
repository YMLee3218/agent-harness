#!/usr/bin/env bash
set -euo pipefail

AGENT="" PHASE="" PLAN="" PROMPT="" ITER_DOC=""
PLAN_FILE_SH="$(dirname "${BASH_SOURCE[0]}")/plan-file.sh"
while [[ $# -gt 0 ]]; do
  case $1 in
    --agent)         AGENT="$2";    shift 2 ;;
    --phase)         PHASE="$2";    shift 2 ;;
    --plan)          PLAN="$2";     shift 2 ;;
    --prompt)        PROMPT="$2";   shift 2 ;;
    --iteration-doc) ITER_DOC="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

ITER_DOC="${ITER_DOC:-@reference/critics.md §Critic one-shot iteration}"

[[ -z "$AGENT" || -z "$PHASE" || -z "$PLAN" || -z "$PROMPT" ]] && {
  echo "Usage: run-critic-loop.sh --agent NAME --phase PHASE --plan PATH --prompt TEXT [--iteration-doc DOC]" >&2
  exit 2
}

# Lock file — prevent concurrent runs on the same plan
LOOP_LOCK="${PLAN}.critic.lock"
if ! (set -C; echo $$ > "$LOOP_LOCK") 2>/dev/null; then
  echo "=== run-critic-loop: already running for $PLAN ===" >&2; exit 2
fi
trap 'rm -f "$LOOP_LOCK"' EXIT

# Signal handling — clean up subprocess on interrupt
CLAUDE_PID=""
_on_interrupt() { [[ -n "$CLAUDE_PID" ]] && kill "$CLAUDE_PID" 2>/dev/null; exit 130; }
trap '_on_interrupt' INT TERM

# Timeout command (cross-platform)
TIMEOUT_CMD=$(command -v gtimeout || command -v timeout || true)
SESSION_TIMEOUT="${CLAUDE_CRITIC_SESSION_TIMEOUT:-3600}"

iter=0
LAST_PLAN_HASH=""
CONSECUTIVE_NOOP=0

while true; do
  marker=$(awk -v agent="$AGENT" -v phase="$PHASE" '/^## Open Questions/{f=1} f && /\[CONVERGED\]/{if(index($0,"[CONVERGED] " phase "/" agent)>0){print;exit};next} f && /\[BLOCKED-CEILING\]/{if(index($0,"[BLOCKED-CEILING] " phase "/" agent)>0){print;exit};next} f && /\[BLOCKED/{print;exit}' "$PLAN" 2>/dev/null || true)
  case "$marker" in
    *CONVERGED*)       echo "CONVERGED"; exit 0 ;;
    *BLOCKED-CEILING*) echo "$marker";   exit 2 ;;
    *BLOCKED*)         echo "$marker";   exit 1 ;;
  esac

  bash "$PLAN_FILE_SH" gc-verdicts "$PLAN" 2>/dev/null || true

  iter=$((iter + 1))
  ITER_PROMPT="Run one critic iteration per ${ITER_DOC}. agent=$AGENT phase=$PHASE plan=$PLAN prompt: $PROMPT"

  if [[ -n "$TIMEOUT_CMD" ]]; then
    CLAUDE_NONINTERACTIVE=1 "$TIMEOUT_CMD" --kill-after=30 "$SESSION_TIMEOUT" \
      claude --permission-mode auto --dangerously-skip-permissions -p "$ITER_PROMPT" &
  else
    CLAUDE_NONINTERACTIVE=1 claude --permission-mode auto --dangerously-skip-permissions -p "$ITER_PROMPT" &
  fi
  CLAUDE_PID=$!
  wait "$CLAUDE_PID" || {
    exit_code=$?
    CLAUDE_PID=""
    if [[ $exit_code -eq 124 ]]; then
      bash "$PLAN_FILE_SH" append-note "$PLAN" \
        "[BLOCKED] ${AGENT}: session-timeout after ${SESSION_TIMEOUT}s — increase CLAUDE_CRITIC_SESSION_TIMEOUT or re-run" 2>/dev/null || true
      echo "[BLOCKED] session-timeout after ${SESSION_TIMEOUT}s" >&2; exit 1
    fi
  }
  CLAUDE_PID=""

  # Consecutive NOOP detection — plan file unchanged across iterations
  plan_hash=$(md5 -q "$PLAN" 2>/dev/null || md5sum "$PLAN" | cut -d' ' -f1)
  if [[ "$plan_hash" == "$LAST_PLAN_HASH" ]]; then
    CONSECUTIVE_NOOP=$((CONSECUTIVE_NOOP + 1))
    if [[ $CONSECUTIVE_NOOP -ge ${MAX_CONSECUTIVE_NOOP:-2} ]]; then
      bash "$PLAN_FILE_SH" append-note "$PLAN" \
        "[BLOCKED] ${AGENT}: plan unchanged for ${CONSECUTIVE_NOOP} consecutive iterations — critic is not writing to plan file; check session logs" 2>/dev/null || true
      echo "[BLOCKED] plan unchanged for $CONSECUTIVE_NOOP consecutive iterations" >&2; exit 1
    fi
  else
    CONSECUTIVE_NOOP=0
  fi
  LAST_PLAN_HASH="$plan_hash"
done
