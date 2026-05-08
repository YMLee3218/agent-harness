#!/usr/bin/env bash
set -euo pipefail

AGENT="" PHASE="" PLAN="" PROMPT="" ITER_DOC="" NESTED=0
PLAN_FILE_SH="$(dirname "${BASH_SOURCE[0]}")/plan-file.sh"
while [[ $# -gt 0 ]]; do
  case $1 in
    --agent)         AGENT="$2";    shift 2 ;;
    --phase)         PHASE="$2";    shift 2 ;;
    --plan)          PLAN="$2";     shift 2 ;;
    --prompt)        PROMPT="$2";   shift 2 ;;
    --iteration-doc) ITER_DOC="$2"; shift 2 ;;
    --nested)        NESTED=1;      shift ;;
    *) echo "Unknown argument: $1" >&2; exit 5 ;;
  esac
done

ITER_DOC="${ITER_DOC:-@reference/critics.md §Critic one-shot iteration}"

[[ -z "$AGENT" || -z "$PHASE" || -z "$PLAN" || -z "$PROMPT" ]] && {
  echo "Usage: run-critic-loop.sh --agent NAME --phase PHASE --plan PATH --prompt TEXT [--iteration-doc DOC] [--nested]" >&2
  exit 5
}

# Lock file — prevent concurrent runs on the same plan.
# record-verdict-guarded requires this lock to exist when a critic subagent stops.
LOOP_LOCK="${PLAN}.critic.lock"
if [[ $NESTED -eq 0 ]]; then
  if ! (set -C; echo $$ > "$LOOP_LOCK") 2>/dev/null; then
    echo "=== run-critic-loop: already running for $PLAN ===" >&2; exit 3
  fi
  trap 'rm -f "$LOOP_LOCK"' EXIT
else
  # Nested: if no outer lock exists (direct recovery cascade), create it and own cleanup.
  # If outer lock exists (called from inside a B-session), inherit it without taking ownership.
  if (set -C; echo $$ > "$LOOP_LOCK") 2>/dev/null; then
    trap 'rm -f "$LOOP_LOCK"' EXIT
  fi
fi

# Signal handling — clean up subprocess on interrupt
CLAUDE_PID=""
_on_interrupt() { [[ -n "$CLAUDE_PID" ]] && kill "$CLAUDE_PID" 2>/dev/null; exit 130; }
trap '_on_interrupt' INT TERM

# Timeout command (cross-platform)
TIMEOUT_CMD=$(command -v gtimeout || command -v timeout || true)
SESSION_TIMEOUT="${CLAUDE_CRITIC_SESSION_TIMEOUT:-3600}"

# Fail loudly when no timeout binary is available — silent unbounded sessions can hang
# indefinitely. Mirrors stop-check.sh:140-144. Set CLAUDE_CRITIC_SESSION_TIMEOUT=0 to bypass.
if [[ -z "$TIMEOUT_CMD" ]] && [[ "$SESSION_TIMEOUT" != "0" ]]; then
  bash "$PLAN_FILE_SH" append-note "$PLAN" \
    "[BLOCKED] ${AGENT}: no timeout binary — install GNU coreutils (brew install coreutils) or set CLAUDE_CRITIC_SESSION_TIMEOUT=0 to disable the cap" 2>/dev/null || true
  echo "[BLOCKED] ${AGENT}: no timeout binary — install GNU coreutils (brew install coreutils) or set CLAUDE_CRITIC_SESSION_TIMEOUT=0 to disable the cap" >&2
  exit 1
fi

iter=0
LAST_PLAN_HASH=$(md5 -q "$PLAN" 2>/dev/null || md5sum "$PLAN" | cut -d' ' -f1)
CONSECUTIVE_NOOP=0

while true; do
  marker=$(awk -v agent="$AGENT" -v phase="$PHASE" '/^## Open Questions/{f=1} f&&/\[BLOCKED-CEILING\]/{if(index($0,"[BLOCKED-CEILING] " phase "/" agent)>0)ceiling=$0;next} f&&/\[BLOCKED/{if(blocked=="")blocked=$0} f&&/\[CONVERGED\]/{if(index($0,"[CONVERGED] " phase "/" agent)>0)converged=$0} END{if(ceiling!=""){print ceiling}else if(blocked!=""){print blocked}else if(converged!=""){print converged}}' "$PLAN" 2>/dev/null || true)
  case "$marker" in
    *CONVERGED*)
      consecutive=$(awk -v pat="${PHASE}/${AGENT}:" '
        /^## Critic Verdicts$/{f=1;next}
        f&&/^## /{f=0}
        f&&/^- /{if(index($0,pat) && !index($0,"[MILESTONE-BOUNDARY")) lines[++n]=$0}
        END{
          c=0
          for(i=n;i>=1;i--){
            if(index(lines[i],": PASS")>0) c++
            else break
          }
          print c+0
        }
      ' "$PLAN" 2>/dev/null || echo "0")
      if [ "${consecutive:-0}" -ge 2 ]; then
        echo "CONVERGED"; exit 0
      else
        echo "[run-critic-loop] CONVERGED marker invalid (streak=${consecutive:-0}, need 2) — clearing" >&2
        bash "$PLAN_FILE_SH" clear-marker "$PLAN" "[CONVERGED] ${PHASE}/${AGENT}" 2>/dev/null || true
      fi
      ;;
    *BLOCKED-CEILING*) echo "$marker";   exit 2 ;;
    *BLOCKED*)         echo "$marker";   exit 1 ;;
  esac

  [[ $NESTED -eq 0 ]] && bash "$PLAN_FILE_SH" gc-verdicts "$PLAN" 2>/dev/null || true

  iter=$((iter + 1))
  ITER_PROMPT="Run one critic iteration per ${ITER_DOC}. agent=$AGENT phase=$PHASE plan=$PLAN prompt: $PROMPT"

  CRITIC_LOOP_MODEL="${CLAUDE_CRITIC_LOOP_MODEL:-opus}"
  if [[ -n "$TIMEOUT_CMD" ]]; then
    CLAUDE_NONINTERACTIVE=1 CLAUDE_CRITIC_SESSION=1 CLAUDE_PLAN_FILE="$PLAN" "$TIMEOUT_CMD" --kill-after=30 "$SESSION_TIMEOUT" \
      claude --model "$CRITIC_LOOP_MODEL" --permission-mode auto --dangerously-skip-permissions -p "$ITER_PROMPT" &
  else
    CLAUDE_NONINTERACTIVE=1 CLAUDE_CRITIC_SESSION=1 CLAUDE_PLAN_FILE="$PLAN" claude --model "$CRITIC_LOOP_MODEL" --permission-mode auto --dangerously-skip-permissions -p "$ITER_PROMPT" &
  fi
  CLAUDE_PID=$!
  wait "$CLAUDE_PID" || {
    exit_code=$?
    CLAUDE_PID=""
    if [[ $exit_code -eq 124 ]]; then
      bash "$PLAN_FILE_SH" append-note "$PLAN" \
        "[BLOCKED] ${AGENT}: session-timeout after ${SESSION_TIMEOUT}s — increase CLAUDE_CRITIC_SESSION_TIMEOUT or re-run" 2>/dev/null || true
      echo "[BLOCKED] session-timeout after ${SESSION_TIMEOUT}s" >&2; exit 1
    else
      bash "$PLAN_FILE_SH" append-note "$PLAN" \
        "[BLOCKED] ${AGENT}: script-failure: ${exit_code} — claude session exited unexpectedly; check session logs" 2>/dev/null || true
      echo "[BLOCKED] script-failure: ${exit_code}" >&2; exit 1
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
