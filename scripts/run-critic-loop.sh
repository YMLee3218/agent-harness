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

# Source sidecar for transient mechanism
source "$(dirname "${BASH_SOURCE[0]}")/lib/sidecar.sh" 2>/dev/null || true
# Source critic-helpers for Codex-driven path
source "$(dirname "${BASH_SOURCE[0]}")/lib/critic-helpers.sh" 2>/dev/null || true
# Source sandbox-lib for Tier 1 worker confinement
source "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox-lib.sh" 2>/dev/null || true
_init_worker_sandbox "$(dirname "$(dirname "$PLAN")")"
if [[ "${_SANDBOX_REQUIRED_FAIL:-0}" == "1" ]]; then
  bash "$PLAN_FILE_SH" append-note "$PLAN" "[BLOCKED:env] ${AGENT}: sandbox-unavailable — Tier 1 sandbox inactive; set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined"
  exit 1
fi

# Lock file — prevent concurrent runs on the same plan.
LOOP_LOCK="${PLAN}.critic.lock"
if [[ $NESTED -eq 0 ]]; then
  if ! (set -C; echo $$ > "$LOOP_LOCK") 2>/dev/null; then
    _record_transient "$PLAN" "$AGENT" loop-lock \
      "critic loop already running — wait or remove $(basename "$LOOP_LOCK")" "$PLAN_FILE_SH" 2>/dev/null || true
    echo "=== run-critic-loop: already running for $PLAN ===" >&2; exit 3
  fi
  trap 'rm -f "$LOOP_LOCK"' EXIT
else
  if (set -C; echo $$ > "$LOOP_LOCK") 2>/dev/null; then
    trap 'rm -f "$LOOP_LOCK"' EXIT
  fi
fi

# Signal handling — clean up subprocess on interrupt
CLAUDE_PID="" _session_out=""
_on_interrupt() {
  [[ -n "$CLAUDE_PID" ]] && kill "$CLAUDE_PID" 2>/dev/null
  rm -f "${_session_out:-}"
  exit 130
}
trap '_on_interrupt' INT TERM

# Timeout command (cross-platform)
source "$(dirname "${BASH_SOURCE[0]}")/lib/timeout-guard.sh"
SESSION_TIMEOUT="${CLAUDE_CRITIC_SESSION_TIMEOUT:-3600}"
timeout_guard_init "$SESSION_TIMEOUT" CLAUDE_CRITIC_SESSION_TIMEOUT "${AGENT}" "$PLAN" "$PLAN_FILE_SH"

iter=0
LAST_PLAN_HASH=$(md5 -q "$PLAN" 2>/dev/null || md5sum "$PLAN" | cut -d' ' -f1)
CONSECUTIVE_NOOP=0

_log_slug=$(basename "$PLAN" .md)
_log_dir="$(dirname "$PLAN")/${_log_slug}.state"

# Prior FAIL log prefill — only for B-session path
PRIOR_FAIL_LOG=""
if ! _is_codex_driven_agent "$AGENT" 2>/dev/null; then
  _prior_log="${_log_dir}/last-critic-${AGENT}.log"
  if [[ -f "$_prior_log" ]] && grep -q '<!-- verdict: FAIL -->' "$_prior_log" 2>/dev/null; then
    PRIOR_FAIL_LOG="$_prior_log"
  fi
fi

while true; do
  # Ceiling-blocked check (sidecar)
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
  # General blocked check
  if bash "$PLAN_FILE_SH" is-blocked "$PLAN" 2>/dev/null; then
    echo "[BLOCKED:*] active block detected — exiting critic loop" >&2
    exit 1
  fi
  # Convergence check (authoritative)
  if bash "$PLAN_FILE_SH" is-converged "$PLAN" "$PHASE" "$AGENT" 2>/dev/null; then
    echo "CONVERGED"; exit 0
  fi

  if [[ $NESTED -eq 0 ]]; then
    bash "$PLAN_FILE_SH" gc-verdicts "$PLAN" 2>/dev/null || true
  fi

  iter=$((iter + 1))

  if [[ -L "$_log_dir" ]]; then
    echo "[run-critic-loop] FATAL: sidecar dir $_log_dir is a symlink — refusing" >&2
    bash "$PLAN_FILE_SH" append-note "$PLAN" \
      "[BLOCKED:harness] run-critic-loop: sidecar-symlink — sidecar dir is a symlink, potential redirect attack; remove the symlink manually" 2>/dev/null || true
    exit 1
  fi
  mkdir -p "$_log_dir" 2>/dev/null || true

  # ── Codex-driven path (critic-spec, critic-test, critic-code, critic-cross) ──
  if _is_codex_driven_agent "$AGENT" 2>/dev/null; then

    # 1. Build review prompt from SKILL.md template
    _review_prompt=$(mktemp /tmp/critic-${AGENT}-review.XXXXXX)
    if ! build_review_prompt "$AGENT" "$_review_prompt"; then
      bash "$PLAN_FILE_SH" append-note "$PLAN" \
        "[BLOCKED:env] ${AGENT}: review-prompt-build-failed — check skills/${AGENT}/SKILL.md" 2>/dev/null || true
      rm -f "$_review_prompt"; exit 1
    fi

    # 2. Run Codex review → fixed log path (reliably accessible for diagnosis)
    _review_log="${_log_dir}/codex-critic-${AGENT}-last.log"
    _codex_review_exit=0
    if [[ -n "$TIMEOUT_CMD" && "$SESSION_TIMEOUT" != "0" ]]; then
      "$TIMEOUT_CMD" --kill-after=$TG_KILL_AFTER "$SESSION_TIMEOUT" \
        "${_WORKER_SANDBOX_ARGS[@]}" codex exec --full-auto - < "$_review_prompt" > "$_review_log" 2>&1 || _codex_review_exit=$?
    else
      "${_WORKER_SANDBOX_ARGS[@]}" codex exec --full-auto - < "$_review_prompt" > "$_review_log" 2>&1 || _codex_review_exit=$?
    fi
    rm -f "$_review_prompt"

    if [[ $_codex_review_exit -eq 124 ]]; then
      _record_transient "$PLAN" "$AGENT" session-timeout \
        "codex review timed out after ${SESSION_TIMEOUT}s — increase CLAUDE_CRITIC_SESSION_TIMEOUT or re-run" \
        "$PLAN_FILE_SH" 2>/dev/null || true
      echo "[transient] session-timeout after ${SESSION_TIMEOUT}s" >&2; exit 1
    fi

    # 3. Detect infra failure (non-zero exit with no output, or CODEX-INFRA-FAILURE sentinel)
    if [[ $_codex_review_exit -ne 0 && ! -s "$_review_log" ]]; then
      if _record_transient "$PLAN" "$AGENT" thinking-block-api-error \
          "codex review exit ${_codex_review_exit} with empty output — retrying" "$PLAN_FILE_SH" 2>/dev/null; then
        echo "[transient] promoted to [BLOCKED:env] after threshold" >&2; exit 1
      else
        echo "[transient] codex exit ${_codex_review_exit} with empty output — retrying" >&2; continue
      fi
    fi
    if grep -q '=== CODEX-INFRA-FAILURE:' "$_review_log" 2>/dev/null; then
      _infra_detail=$(grep '=== CODEX-INFRA-FAILURE:' "$_review_log" | head -1 | cut -c1-120 || echo "infra failure")
      if _record_transient "$PLAN" "$AGENT" thinking-block-api-error \
          "codex infra failure — ${_infra_detail}" "$PLAN_FILE_SH" 2>/dev/null; then
        echo "[transient] promoted to [BLOCKED:env] after threshold" >&2; exit 1
      else
        echo "[transient] codex infra failure — retrying" >&2; continue
      fi
    fi

    _clear_transient_for "$PLAN" "$AGENT" 2>/dev/null || true

    # 4. Parse verdict/category from Codex log
    _vc=$(parse_verdict_from_log "$_review_log")
    _verdict="${_vc%%|*}"
    _category="${_vc##*|}"

    # 5. Handle missing verdict marker
    if [[ -z "$_verdict" ]]; then
      if [[ ! -s "$_review_log" ]]; then
        bash "$PLAN_FILE_SH" append-note "$PLAN" \
          "[BLOCKED:env] ${AGENT}: critic-skill-not-run — codex produced empty output"
        exit 1
      fi
      # Has content but no verdict marker → PARSE_ERROR (will retry; second consecutive → BLOCKED:code)
      _verdict="PARSE_ERROR"
      _category=""
    fi

    # 6a. Guard: FAIL must include at least one blocking-label finding
    if [[ "$_verdict" == "FAIL" ]]; then
      _has_blocking=$(extract_all_findings "$_review_log" | head -1)
      if [[ -z "$_has_blocking" ]]; then
        _verdict="PARSE_ERROR"
        _category=""
      fi
    fi

    # 6. Record verdict directly (validates enum, handles consecutive PARSE_ERROR)
    _rvd_exit=0
    bash "$PLAN_FILE_SH" record-verdict-direct \
      "$PLAN" "$AGENT" "$PHASE" "$_verdict" "$_category" || _rvd_exit=$?
    # record-verdict-direct exits 1 BY DESIGN after persisting a FAIL/PARSE_ERROR verdict
    # (_persist_verdict:686 / _handle_parse_error:498); PASS exits 0. Only a deviation from this
    # contract is a genuine recorder failure (e.g. require_file exit 2, lock-absent die).
    _rvd_expected=0
    [[ "$_verdict" == "FAIL" || "$_verdict" == "PARSE_ERROR" ]] && _rvd_expected=1
    if [[ "$_rvd_exit" -ne "$_rvd_expected" ]]; then
      bash "$PLAN_FILE_SH" append-note "$PLAN" \
        "[BLOCKED:env] ${AGENT}: verdict-record-failure — record-verdict-direct exited ${_rvd_exit} (expected ${_rvd_expected}); check plan-file.sh" \
        2>/dev/null || true
      echo "[BLOCKED:env] ${AGENT}: record-verdict-direct failed (exit ${_rvd_exit}, expected ${_rvd_expected})" >&2; exit 1
    fi

    # 7. Re-check blocked/ceiling after verdict recording
    if [[ -f "$_conv_path" ]] && command -v jq >/dev/null 2>&1; then
      if jq -r '.ceiling_blocked // false' "$_conv_path" 2>/dev/null | grep -q '^true$'; then
        echo "[BLOCKED:ceiling] ${AGENT}: exceeded critic ceiling" >&2; exit 2
      fi
    fi
    if bash "$PLAN_FILE_SH" is-blocked "$PLAN" 2>/dev/null; then
      echo "[BLOCKED:*] active block after verdict record — exiting" >&2; exit 1
    fi

    # 8. Branch on verdict
    if [[ "$_verdict" == "PASS" ]]; then
      if bash "$PLAN_FILE_SH" is-converged "$PLAN" "$PHASE" "$AGENT" 2>/dev/null; then
        # 2nd consecutive PASS — one Claude call for REJECT-PASS check only
        _pass_audit_prompt=$(mktemp /tmp/critic-${AGENT}-passaudit.XXXXXX)
        build_pass_audit_prompt "$AGENT" "$_review_log" "$PLAN" "$_pass_audit_prompt"

        _pass_check_out=""
        _pass_cmd=()
        [[ -n "$TIMEOUT_CMD" && "$SESSION_TIMEOUT" != "0" ]] && \
          _pass_cmd+=("$TIMEOUT_CMD" --kill-after=$TG_KILL_AFTER "$SESSION_TIMEOUT")
        [[ ${#_WORKER_SANDBOX_ARGS[@]} -gt 0 ]] && _pass_cmd+=("${_WORKER_SANDBOX_ARGS[@]}")
        _pass_cmd+=(claude --model sonnet --dangerously-skip-permissions --permission-mode auto \
          -p "$(cat "$_pass_audit_prompt")")
        rm -f "$_pass_audit_prompt"

        _pass_exit=0
        _pass_check_out=$(CLAUDE_NONINTERACTIVE=1 env -u CLAUDE_PLAN_CAPABILITY \
          "${_pass_cmd[@]}" 2>/dev/null) || _pass_exit=$?
        if [[ "$_pass_exit" -eq 124 ]]; then
          bash "$PLAN_FILE_SH" clear-converged "$PLAN" "$AGENT" 2>/dev/null || true
          _record_transient "$PLAN" "$AGENT" session-timeout \
            "PASS audit timed out after ${SESSION_TIMEOUT}s — increase CLAUDE_CRITIC_SESSION_TIMEOUT or re-run" \
            "$PLAN_FILE_SH" 2>/dev/null || true
          echo "[transient] session-timeout on PASS audit after ${SESSION_TIMEOUT}s" >&2; exit 1
        fi

        if printf '%s' "$_pass_check_out" | grep -q 'VERDICT: REJECT-PASS'; then
          _reject_reason=$(printf '%s' "$_pass_check_out" | \
            grep 'VERDICT: REJECT-PASS' | sed 's/VERDICT: REJECT-PASS[[:space:]]*—[[:space:]]*//' | \
            head -1 | cut -c1-120 || echo "gap found")
          bash "$PLAN_FILE_SH" clear-converged "$PLAN" "$AGENT" 2>/dev/null || true
          bash "$PLAN_FILE_SH" append-audit "$PLAN" "$AGENT" "REJECT-PASS" \
            "audit overrode PASS — ${_reject_reason}" 2>/dev/null || true
          # Fall through to NOOP check and loop again
        elif printf '%s' "$_pass_check_out" | grep -q 'VERDICT: ACCEPT'; then
          bash "$PLAN_FILE_SH" append-audit "$PLAN" "$AGENT" "ACCEPT" \
            "convergence verified" 2>/dev/null || true
          echo "CONVERGED"; exit 0
        else
          # Audit produced no recognisable verdict — treat as transient and retry
          bash "$PLAN_FILE_SH" clear-converged "$PLAN" "$AGENT" 2>/dev/null || true
          _record_transient "$PLAN" "$AGENT" thinking-block-api-error \
            "PASS audit produced no VERDICT line — retrying" "$PLAN_FILE_SH" 2>/dev/null && {
            echo "[transient] promoted pass-audit failure to [BLOCKED:env] after threshold" >&2; exit 1
          } || { echo "[transient] pass-audit no-verdict — retrying" >&2; }
        fi
      fi
      # 1st PASS or post-REJECT-PASS: loop continues, no Claude call

    elif [[ "$_verdict" == "FAIL" ]]; then
      # One Claude call: ultrathink audit + comprehensive FIX-PLAN for all findings
      _decision_prompt=$(mktemp /tmp/critic-${AGENT}-decision.XXXXXX)
      build_decision_prompt "$AGENT" "$_review_log" "$PLAN" "$_decision_prompt"

      _decision_out=""
      _dec_cmd=()
      [[ -n "$TIMEOUT_CMD" && "$SESSION_TIMEOUT" != "0" ]] && \
        _dec_cmd+=("$TIMEOUT_CMD" --kill-after=$TG_KILL_AFTER "$SESSION_TIMEOUT")
      [[ ${#_WORKER_SANDBOX_ARGS[@]} -gt 0 ]] && _dec_cmd+=("${_WORKER_SANDBOX_ARGS[@]}")
      _dec_cmd+=(claude --model sonnet --dangerously-skip-permissions --permission-mode auto \
        -p "$(cat "$_decision_prompt")")
      rm -f "$_decision_prompt"

      _dec_exit=0
      _decision_out=$(CLAUDE_NONINTERACTIVE=1 CLAUDE_PLAN_FILE="$PLAN" \
        env -u CLAUDE_PLAN_CAPABILITY \
        "${_dec_cmd[@]}" 2>/dev/null) || _dec_exit=$?
      if [[ "$_dec_exit" -eq 124 ]]; then
        _record_transient "$PLAN" "$AGENT" session-timeout \
          "decision agent timed out after ${SESSION_TIMEOUT}s — increase CLAUDE_CRITIC_SESSION_TIMEOUT or re-run" \
          "$PLAN_FILE_SH" 2>/dev/null || true
        echo "[transient] session-timeout on decision agent after ${SESSION_TIMEOUT}s" >&2; exit 1
      fi

      _audit_outcome=$(parse_audit_outcome "$_decision_out")

      if [[ -z "$_audit_outcome" ]]; then
        bash "$PLAN_FILE_SH" append-note "$PLAN" \
          "[BLOCKED:env] ${AGENT}: decision-parse-failure — claude decision agent produced no AUDIT: line; check decision prompt output" 2>/dev/null || true
        echo "[run-critic-loop] [BLOCKED:env] ${AGENT}: decision-parse-failure" >&2
        exit 1
      fi

      bash "$PLAN_FILE_SH" append-audit "$PLAN" "$AGENT" "$_audit_outcome" \
        "$(printf '%s' "$_decision_out" | head -3 | tr '\n' ' ' | cut -c1-120)" 2>/dev/null || true

      # Apply Codex fix for GENUINE findings first (skip on ACCEPT-OVERRIDE).
      # BLOCKED-AMBIGUOUS: fix GENUINE findings before writing [BLOCKED:spec] markers —
      # the pre-tool hook blocks Bash writes once a [BLOCKED:spec] marker is present.
      if [[ "$_audit_outcome" != "ACCEPT-OVERRIDE" ]]; then
        _fix_plan=$(parse_fix_plan "$_decision_out")
        if [[ -n "$_fix_plan" ]]; then
          _spec_ref="${CRITIC_SPEC_PATH:-${CRITIC_ALL_SPEC_PATHS:-${PLAN}}}"
          _fix_prompt=$(mktemp /tmp/critic-${AGENT}-fix.XXXXXX)
          build_fix_prompt "$AGENT" "$_review_log" "$_fix_plan" "$_spec_ref" "$PLAN" "$_fix_prompt"

          _fix_log="${_log_dir}/codex-critic-${AGENT}-fix.log"
          _fix_exit=0
          if [[ -n "$TIMEOUT_CMD" && "$SESSION_TIMEOUT" != "0" ]]; then
            "$TIMEOUT_CMD" --kill-after=$TG_KILL_AFTER "$SESSION_TIMEOUT" \
              "${_WORKER_SANDBOX_ARGS[@]}" codex exec --full-auto - < "$_fix_prompt" > "$_fix_log" 2>&1 || _fix_exit=$?
          else
            "${_WORKER_SANDBOX_ARGS[@]}" codex exec --full-auto - < "$_fix_prompt" > "$_fix_log" 2>&1 || _fix_exit=$?
          fi
          rm -f "$_fix_prompt"
          [[ $_fix_exit -ne 0 ]] && \
            echo "[run-critic-loop] WARN: codex fix exit ${_fix_exit} for ${AGENT}" >&2
        fi
      fi

      # For BLOCKED-AMBIGUOUS: append [BLOCKED:spec] and [BLOCKED:docs] markers after fix pass
      if [[ "$_audit_outcome" == "BLOCKED-AMBIGUOUS" ]]; then
        while IFS= read -r _bs_line; do
          [[ -n "$_bs_line" ]] || continue
          bash "$PLAN_FILE_SH" append-note "$PLAN" "$_bs_line" 2>/dev/null || true
        done < <(printf '%s' "$_decision_out" | grep -E '^\[BLOCKED:(spec|docs)\]' || true)
      fi

      # Re-check blocked after potential BLOCKED-AMBIGUOUS markers
      if bash "$PLAN_FILE_SH" is-blocked "$PLAN" 2>/dev/null; then
        echo "[BLOCKED:*] blocked after fix — exiting" >&2; exit 1
      fi
    fi
    # PARSE_ERROR: record-verdict-direct handled consecutive check; loop continues

  else
    # ── B-session path (critic-feature, pr-review) — original logic ─────────────

    _wrapped_plan_ref=$(printf 'agent=%s phase=%s plan=%s prompt: %s' "$AGENT" "$PHASE" "$PLAN" "$PROMPT")
    _prefill=""
    [[ $iter -eq 1 && -n "$PRIOR_FAIL_LOG" ]] && _prefill=" prior_fail_log=${PRIOR_FAIL_LOG}"
    ITER_PROMPT="Run one critic iteration per ${ITER_DOC}. agent=${AGENT} phase=${PHASE} plan=${PLAN} prompt: ${PROMPT} ${_wrapped_plan_ref}${_prefill}"

    CRITIC_LOOP_MODEL="${CLAUDE_CRITIC_LOOP_MODEL:-opus}"
    _nonce="" _session_out="" _sid=""
    if [[ "$AGENT" == "pr-review" ]]; then
      _nonce=$(uuidgen 2>/dev/null || openssl rand -hex 16 2>/dev/null || printf '%s%s' "$$" "$(date +%s%N)")
      _sid=$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z' || true)
      ITER_PROMPT="${ITER_PROMPT}

MANDATORY OUTPUT CONTRACT — the session is invalid without this:
Print the review verdict marker as a literal raw line (NOT inside a code block,
NOT described in prose — the exact bytes must appear in your output). Emit it before
the ultrathink audit, exactly one of:
<!-- review-verdict: ${_nonce} PASS -->
<!-- review-verdict: ${_nonce} FAIL -->
Do NOT write \"I output the marker\" or refer to \"the marker above\" — actually print
the line. The nonce ${_nonce} must appear verbatim."
    fi
    _session_out=$(mktemp)
    _cmd=()
    [[ -n "$TIMEOUT_CMD" ]] && _cmd+=("$TIMEOUT_CMD" --kill-after=$TG_KILL_AFTER "$SESSION_TIMEOUT")
    [[ ${#_WORKER_SANDBOX_ARGS[@]} -gt 0 ]] && _cmd+=("${_WORKER_SANDBOX_ARGS[@]}")
    _cmd+=(claude --model "$CRITIC_LOOP_MODEL" --permission-mode auto --dangerously-skip-permissions -p "$ITER_PROMPT")
    [[ -n "${_sid:-}" ]] && _cmd+=(--session-id "$_sid")
    _env_unset=()
    [[ "$AGENT" != "pr-review" ]] && _env_unset=(-u CLAUDE_PLAN_CAPABILITY)
    CLAUDE_NONINTERACTIVE=1 CLAUDE_CRITIC_SESSION=1 CLAUDE_PLAN_FILE="$PLAN" \
      env "${_env_unset[@]}" "${_cmd[@]}" > "$_session_out" 2>&1 &
    CLAUDE_PID=$!
    wait "$CLAUDE_PID" || {
      exit_code=$?
      CLAUDE_PID=""
      [[ -n "${_session_out:-}" && -s "${_session_out:-}" ]] && \
        cp "$_session_out" "${_log_dir}/last-critic-${AGENT}.log" 2>/dev/null || true
      rm -f "${_session_out:-}"
      if [[ $exit_code -eq 124 ]]; then
        _record_transient "$PLAN" "$AGENT" session-timeout \
          "after ${SESSION_TIMEOUT}s — increase CLAUDE_CRITIC_SESSION_TIMEOUT or re-run" "$PLAN_FILE_SH" 2>/dev/null || true
        echo "[transient] session-timeout after ${SESSION_TIMEOUT}s" >&2; exit 1
      elif [[ $exit_code -eq 1 ]] && grep -q "thinking.*blocks.*cannot be modified\|redacted_thinking.*cannot be modified" \
          "${_log_dir}/last-critic-${AGENT}.log" 2>/dev/null; then
        if _record_transient "$PLAN" "$AGENT" thinking-block-api-error \
            "Claude API 400: thinking blocks modified in multi-turn session — will retry" "$PLAN_FILE_SH" 2>/dev/null; then
          echo "[transient] thinking-block-api-error promoted to [BLOCKED:env] after threshold" >&2; exit 1
        else
          echo "[transient] thinking-block-api-error — retrying session" >&2; continue
        fi
      else
        bash "$PLAN_FILE_SH" append-note "$PLAN" \
          "[BLOCKED:env] ${AGENT}: script-failure — exit ${exit_code}; check session logs" 2>/dev/null || true
        echo "[BLOCKED:env] script-failure: ${exit_code}" >&2; exit 1
      fi
    }
    CLAUDE_PID=""
    _clear_transient_for "$PLAN" "$AGENT" 2>/dev/null || true

    [[ -n "${_session_out:-}" && -s "${_session_out:-}" ]] && \
      cp "$_session_out" "${_log_dir}/last-critic-${AGENT}.log" 2>/dev/null || true
    if [[ -n "${_nonce:-}" ]]; then
      cat "$_session_out"
      _rv=$(grep -o "<!-- review-verdict: ${_nonce} [A-Z]* -->" "$_session_out" | tail -1 | \
            sed "s/<!-- review-verdict: ${_nonce} //; s/ -->//" || true)
      if [[ "$_rv" != "PASS" && "$_rv" != "FAIL" && -n "${_sid:-}" ]]; then
        _retry_out=$(mktemp); _rcmd=()
        [[ -n "$TIMEOUT_CMD" ]] && _rcmd+=("$TIMEOUT_CMD" --kill-after=$TG_KILL_AFTER "$SESSION_TIMEOUT")
        [[ ${#_WORKER_SANDBOX_ARGS[@]} -gt 0 ]] && _rcmd+=("${_WORKER_SANDBOX_ARGS[@]}")
        _rcmd+=(claude --resume "$_sid" --model "$CRITIC_LOOP_MODEL" --permission-mode auto \
          --dangerously-skip-permissions -p "Output ONLY the review verdict marker as a literal raw line, using the final verdict you reached in this session, exactly one of: <!-- review-verdict: ${_nonce} PASS --> or <!-- review-verdict: ${_nonce} FAIL -->. Print nothing else.")
        CLAUDE_NONINTERACTIVE=1 CLAUDE_CRITIC_SESSION=1 CLAUDE_PLAN_FILE="$PLAN" "${_rcmd[@]}" > "$_retry_out" 2>&1 || true
        cat "$_retry_out"
        _rv=$(grep -o "<!-- review-verdict: ${_nonce} [A-Z]* -->" "$_retry_out" | tail -1 | \
              sed "s/<!-- review-verdict: ${_nonce} //; s/ -->//" || true)
        rm -f "$_retry_out"
      fi
      if [[ "$_rv" == "PASS" || "$_rv" == "FAIL" ]]; then
        _arv_rc=0
        # Session may have left plan in implement phase after fix-chain without restoring to review.
        # append-review-verdict uses the plan's current phase for the verdict label and convergence
        # sidecar key; ensure we write to review/pr-review, not implement/pr-review.
        if [[ "$(bash "$PLAN_FILE_SH" get-phase "$PLAN" 2>/dev/null)" != "review" ]]; then
          bash "$PLAN_FILE_SH" transition "$PLAN" review \
            "pr-review session ended — restoring review phase for verdict recording" || {
            bash "$PLAN_FILE_SH" append-note "$PLAN" \
              "[BLOCKED:env] pr-review: phase-restore-failed — could not restore review phase before verdict recording" 2>/dev/null || true
            echo "[run-critic-loop] [BLOCKED:env] pr-review: phase-restore-failed" >&2
            exit 1
          }
        fi
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
          "[BLOCKED:env] pr-review: no-verdict-marker — nonce-anchored marker absent from session output after resume retry; check last-critic-pr-review.log" 2>/dev/null || true
        echo "[run-critic-loop] [BLOCKED:env] pr-review: no-verdict-marker" >&2
        rm -f "${_session_out:-}"; _session_out=""
        exit 1
      fi
    fi
    rm -f "${_session_out:-}"; _session_out=""
  fi

  # ── NOOP detection — plan file unchanged across iterations ─────────────────
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
