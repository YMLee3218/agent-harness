#!/usr/bin/env bash
set -euo pipefail
if [[ "${CLAUDE_PLAN_CAPABILITY:-}" != "harness" ]]; then
  exec /usr/bin/env CLAUDE_PLAN_CAPABILITY=harness "$0" "$@"
fi

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

# Source sidecar for transient mechanism (needed before lock check and in while loop)
source "$(dirname "${BASH_SOURCE[0]}")/lib/sidecar.sh" 2>/dev/null || true

# Lock file — prevent concurrent runs on the same plan.
# record-verdict-guarded requires this lock to exist when a critic subagent stops.
LOOP_LOCK="${PLAN}.critic.lock"
if [[ $NESTED -eq 0 ]]; then
  if ! (set -C; echo $$ > "$LOOP_LOCK") 2>/dev/null; then
    _record_transient "$PLAN" "$AGENT" loop-lock \
      "critic loop already running — wait or remove $(basename "$LOOP_LOCK")" "$PLAN_FILE_SH" 2>/dev/null || true
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

# Signal handling — clean up subprocess on interrupt (also removes _session_out)
CLAUDE_PID="" _session_out=""
_on_interrupt() {
  [[ -n "$CLAUDE_PID" ]] && kill "$CLAUDE_PID" 2>/dev/null
  rm -f "${_session_out:-}"
  exit 130
}
trap '_on_interrupt' INT TERM

# Timeout command (cross-platform)
TIMEOUT_CMD=$(command -v gtimeout || command -v timeout || true)
SESSION_TIMEOUT="${CLAUDE_CRITIC_SESSION_TIMEOUT:-3600}"

# Fail loudly when no timeout binary is available — silent unbounded sessions can hang
# indefinitely. Mirrors stop-check.sh:140-144. Set CLAUDE_CRITIC_SESSION_TIMEOUT=0 to bypass.
if [[ -z "$TIMEOUT_CMD" ]] && [[ "$SESSION_TIMEOUT" != "0" ]]; then
  bash "$PLAN_FILE_SH" append-note "$PLAN" \
    "[BLOCKED:env] ${AGENT}: no-timeout-binary — install GNU coreutils (brew install coreutils) or set CLAUDE_CRITIC_SESSION_TIMEOUT=0 to disable the cap" 2>/dev/null || true
  echo "[BLOCKED:env] ${AGENT}: no-timeout-binary — install GNU coreutils or set CLAUDE_CRITIC_SESSION_TIMEOUT=0" >&2
  exit 1
fi

iter=0
LAST_PLAN_HASH=$(md5 -q "$PLAN" 2>/dev/null || md5sum "$PLAN" | cut -d' ' -f1)
CONSECUTIVE_NOOP=0

while true; do
  # Ceiling-blocked: check sidecar convergence file (per scope — not plan.md)
  # Priority per critics.md: BLOCKED checks (1–4) must precede is-converged (5).
  _conv_path=$(sc_conv_path "$PLAN" "$PHASE" "$AGENT" 2>/dev/null) || {
    echo "[run-critic-loop] ERROR: sc_conv_path failed — CLAUDE_PROJECT_DIR may be unset" >&2
    exit 1
  }
  if [[ -f "$_conv_path" ]] && command -v jq >/dev/null 2>&1; then
    if jq -r '.ceiling_blocked // false' "$_conv_path" 2>/dev/null | grep -q '^true$'; then
      echo "[BLOCKED:ceiling] ${AGENT}: ${PHASE}/${AGENT} exceeded critic ceiling — manual review required" >&2
      exit 2
    fi
  fi
  # General blocked check: sidecar blocked.jsonl only
  if bash "$PLAN_FILE_SH" is-blocked "$PLAN" 2>/dev/null; then
    echo "[BLOCKED:*] active block detected — exiting critic loop" >&2
    exit 1
  fi
  # Convergence check via sidecar (authoritative source) — after all BLOCKED checks
  if bash "$PLAN_FILE_SH" is-converged "$PLAN" "$PHASE" "$AGENT" 2>/dev/null; then
    echo "CONVERGED"; exit 0
  fi

  if [[ $NESTED -eq 0 ]]; then
    bash "$PLAN_FILE_SH" gc-verdicts "$PLAN" 2>/dev/null || true
  fi

  iter=$((iter + 1))
  _wrapped_plan_ref=$(printf 'agent=%s phase=%s plan=%s prompt: %s' "$AGENT" "$PHASE" "$PLAN" "$PROMPT")
  ITER_PROMPT="Run one critic iteration per ${ITER_DOC}. agent=${AGENT} phase=${PHASE} prompt: ${PROMPT} ${_wrapped_plan_ref}"

  CRITIC_LOOP_MODEL="${CLAUDE_CRITIC_LOOP_MODEL:-opus}"
  # Capture all B-session output; for pr-review also extract nonce-anchored verdict.
  _nonce="" _session_out=""
  if [[ "$AGENT" == "pr-review" ]]; then
    _nonce=$(uuidgen 2>/dev/null || openssl rand -hex 16 2>/dev/null || printf '%s%s' "$$" "$(date +%s%N)")
    ITER_PROMPT="${ITER_PROMPT}

Output the review verdict marker before running the ultrathink audit, exactly:
<!-- review-verdict: ${_nonce} PASS -->
or
<!-- review-verdict: ${_nonce} FAIL -->"
  fi
  _session_out=$(mktemp)
  _log_slug=$(basename "$PLAN" .md)
  _log_dir="$(dirname "$PLAN")/${_log_slug}.state"
  if [[ -L "$_log_dir" ]]; then
    echo "[run-critic-loop] FATAL: sidecar dir $_log_dir is a symlink — refusing" >&2
    bash "$PLAN_FILE_SH" append-note "$PLAN" \
      "[BLOCKED:harness] run-critic-loop: sidecar-symlink — sidecar dir is a symlink, potential redirect attack; remove the symlink manually" 2>/dev/null || true
    exit 1
  fi
  mkdir -p "$_log_dir" 2>/dev/null || true
  _cmd=()
  [[ -n "$TIMEOUT_CMD" ]] && _cmd+=("$TIMEOUT_CMD" --kill-after=30 "$SESSION_TIMEOUT")
  _cmd+=(claude --model "$CRITIC_LOOP_MODEL" --permission-mode auto --dangerously-skip-permissions -p "$ITER_PROMPT")
  # pr-review sessions need Ring B capability (fix chains call transition, reset-milestone, etc.)
  # All other critic sessions have CLAUDE_PLAN_CAPABILITY stripped to prevent accidental state mutations.
  _env_unset=()
  [[ "$AGENT" != "pr-review" ]] && _env_unset=(-u CLAUDE_PLAN_CAPABILITY)
  CLAUDE_NONINTERACTIVE=1 CLAUDE_CRITIC_SESSION=1 CLAUDE_PLAN_FILE="$PLAN" \
    env "${_env_unset[@]}" "${_cmd[@]}" > "$_session_out" 2>&1 &
  CLAUDE_PID=$!
  wait "$CLAUDE_PID" || {
    exit_code=$?
    CLAUDE_PID=""
    # Preserve session output for diagnosis before removing the temp file
    [[ -n "${_session_out:-}" && -s "${_session_out:-}" ]] && \
      cp "$_session_out" "${_log_dir}/last-critic-${AGENT}.log" 2>/dev/null || true
    rm -f "${_session_out:-}"
    if [[ $exit_code -eq 124 ]]; then
      _record_transient "$PLAN" "$AGENT" session-timeout \
        "after ${SESSION_TIMEOUT}s — increase CLAUDE_CRITIC_SESSION_TIMEOUT or re-run" "$PLAN_FILE_SH" 2>/dev/null || true
      echo "[transient] session-timeout after ${SESSION_TIMEOUT}s" >&2; exit 1
    else
      bash "$PLAN_FILE_SH" append-note "$PLAN" \
        "[BLOCKED:env] ${AGENT}: script-failure — exit ${exit_code}; check session logs" 2>/dev/null || true
      echo "[BLOCKED:env] script-failure: ${exit_code}" >&2; exit 1
    fi
  }
  CLAUDE_PID=""
  _clear_transient_for "$PLAN" "$AGENT" 2>/dev/null || true

  # Preserve session output for diagnosis; echo for pr-review verdict extraction.
  [[ -n "${_session_out:-}" && -s "${_session_out:-}" ]] && \
    cp "$_session_out" "${_log_dir}/last-critic-${AGENT}.log" 2>/dev/null || true
  # nonce prevents the grep from matching a doc citation of the marker format.
  if [[ -n "${_nonce:-}" ]]; then
    cat "$_session_out"
    _rv=$(grep -o "<!-- review-verdict: ${_nonce} [A-Z]* -->" "$_session_out" | tail -1 | \
          sed "s/<!-- review-verdict: ${_nonce} //; s/ -->//" || true)
    if [[ "$_rv" == "PASS" || "$_rv" == "FAIL" ]]; then
      _arv_rc=0
      bash "$PLAN_FILE_SH" append-review-verdict "$PLAN" pr-review "$_rv" || _arv_rc=$?
      if [[ $_arv_rc -ne 0 ]]; then
        if [[ -f "$_conv_path" ]] && jq -r '.ceiling_blocked // false' "$_conv_path" 2>/dev/null | grep -q '^true$'; then
          echo "[BLOCKED:ceiling] pr-review: exceeded critic ceiling — manual review required" >&2
          exit 2
        fi
        exit 1
      fi
    else
      bash "$PLAN_FILE_SH" append-note "$PLAN" \
        "[BLOCKED:env] pr-review: no-verdict-marker — nonce-anchored marker absent from session output; check last-critic-pr-review.log" 2>/dev/null || true
      echo "[run-critic-loop] [BLOCKED:env] pr-review: no-verdict-marker" >&2
      rm -f "${_session_out:-}"; _session_out=""
      exit 1
    fi
  fi
  rm -f "${_session_out:-}"; _session_out=""

  # Consecutive NOOP detection — plan file unchanged across iterations
  plan_hash=$(md5 -q "$PLAN" 2>/dev/null || md5sum "$PLAN" | cut -d' ' -f1)
  if [[ "$plan_hash" == "$LAST_PLAN_HASH" ]]; then
    CONSECUTIVE_NOOP=$((CONSECUTIVE_NOOP + 1))
    if [[ $CONSECUTIVE_NOOP -ge 2 ]]; then
      bash "$PLAN_FILE_SH" append-note "$PLAN" \
        "[BLOCKED:env] ${AGENT}: plan-unchanged — for ${CONSECUTIVE_NOOP} iterations; check session logs" 2>/dev/null || true
      echo "[BLOCKED:env] plan-unchanged for $CONSECUTIVE_NOOP consecutive iterations" >&2; exit 1
    fi
  else
    CONSECUTIVE_NOOP=0
  fi
  LAST_PLAN_HASH="$plan_hash"
done
