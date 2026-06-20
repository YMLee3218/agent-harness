#!/usr/bin/env bash
set -euo pipefail
if [[ "${CLAUDE_PLAN_CAPABILITY:-}" != "harness" ]]; then
  exec /usr/bin/env CLAUDE_PLAN_CAPABILITY=harness "$0" "$@"
fi

AGENT="" PHASE="" PLAN="" PROMPT="" ITER_DOC="" NESTED=0 UNIT=""
PLAN_FILE_SH="$(dirname "${BASH_SOURCE[0]}")/plan-file.sh"
while [[ $# -gt 0 ]]; do
  case $1 in
    --agent)         AGENT="$2";    shift 2 ;;
    --phase)         PHASE="$2";    shift 2 ;;
    --plan)          PLAN="$2";     shift 2 ;;
    --prompt)        PROMPT="$2";   shift 2 ;;
    --iteration-doc) ITER_DOC="$2"; shift 2 ;;
    --unit)          UNIT="$2";     shift 2 ;;
    --nested)        NESTED=1;      shift ;;
    *) echo "Unknown argument: $1" >&2; exit 5 ;;
  esac
done

ITER_DOC="${ITER_DOC:-@reference/critics.md §Critic one-shot iteration}"

[[ -z "$AGENT" || -z "$PHASE" || -z "$PLAN" || -z "$PROMPT" || -z "$UNIT" ]] && {
  echo "Usage: run-critic-loop.sh --agent NAME --phase PHASE --plan PATH --prompt TEXT --unit UNIT [--iteration-doc DOC] [--nested]" >&2
  echo "  --unit is required (fail-closed): the events fact-log scope — a {layer}-{slug} unit or a reserved" >&2
  echo "  sentinel (__brainstorm__/__cross__/__integration__). The legacy unit-less sidecar path is gone." >&2
  exit 5
}

# Source sidecar for transient mechanism
source "$(dirname "${BASH_SOURCE[0]}")/lib/sidecar.sh" 2>/dev/null || true
# Source events.sh for the append-only fact log + content-addressed input hashing.
source "$(dirname "${BASH_SOURCE[0]}")/lib/events.sh" 2>/dev/null || true
# Logical stage for this critic (brainstorm/spec/cross/test/code/quality) — drives the
# events fact's stage field and the input-hash resolver. Constant per invocation.
STAGE="$(_ev_stage_of_agent "$AGENT" 2>/dev/null || echo "$PHASE")"
# append-note wrapper — always forwards UNIT + STAGE so [BLOCKED:*] notes also emit a
# unit-keyed events block fact (cmd_append_note guards on empty unit/stage, so an unset
# UNIT degrades to legacy plan.md/blocked.jsonl-only behaviour). Note arg is $1.
_an() { bash "$PLAN_FILE_SH" append-note "$PLAN" "$1" "$UNIT" "$STAGE"; }
# Convergence / ceiling gating — recomputed purely from the events log (UNIT is required, so
# there is no unit-less sidecar fallback). _conv_check [frozen_hash] → rc0 if converged.
# _ceiling_check → rc0 if ceiling reached.
_conv_check() { bash "$PLAN_FILE_SH" ev-converged "$PLAN" "$UNIT" "$STAGE" "${1:-}" 2>/dev/null; }
_ceiling_check() { bash "$PLAN_FILE_SH" ev-ceiling "$PLAN" "$UNIT" "$STAGE" 2>/dev/null; }
# _audit_reject REASON — append an events audit-reject fact at the frozen hash _H so the events
# streak breaks (pass-audit overrode the 2nd PASS / audit inconclusive). No-op without --unit.
_audit_reject() { [[ -n "$UNIT" ]] && ev_record_audit_reject "$PLAN" "$UNIT" "$STAGE" "${_H:-}" "$1" 2>/dev/null || true; }
# Source critic-helpers for Codex-driven path (also pulls in engine-registry for routing)
source "$(dirname "${BASH_SOURCE[0]}")/lib/critic-helpers.sh" 2>/dev/null || true
# Source the single engine dispatcher (run_engine) used by every LLM/agent spawn below
source "$(dirname "${BASH_SOURCE[0]}")/lib/engine-runner.sh" 2>/dev/null || true
# Source sandbox-lib for Tier 1 worker confinement
source "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox-lib.sh" 2>/dev/null || true
_init_worker_sandbox "$(dirname "$(dirname "$PLAN")")"
if [[ "${_SANDBOX_REQUIRED_FAIL:-0}" == "1" ]]; then
  _an "[BLOCKED:env] ${AGENT}: sandbox-unavailable — Tier 1 sandbox inactive; set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined"
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
  # Fail closed if the events dir does not resolve (CLAUDE_PROJECT_DIR unset → wrong log path).
  ev_ensure_dir "$PLAN" >/dev/null 2>&1 || {
    echo "[run-critic-loop] ERROR: events dir unresolved — CLAUDE_PROJECT_DIR may be unset" >&2
    _an "[BLOCKED:env] ${AGENT}: CLAUDE_PROJECT_DIR-unset — re-run with CLAUDE_PROJECT_DIR set to project root" 2>/dev/null || true
    exit 1
  }
  if _ceiling_check; then
    echo "[BLOCKED:ceiling] ${AGENT}: ${PHASE}/${AGENT} exceeded critic ceiling — manual review required" >&2
    exit 2
  fi
  # General blocked check (global; blocks remain dual-tracked this stage)
  if bash "$PLAN_FILE_SH" is-blocked "$PLAN" 2>/dev/null; then
    echo "[BLOCKED:*] active block detected — exiting critic loop" >&2
    exit 1
  fi
  # Convergence check (authoritative — events recompute when --unit threaded)
  if _conv_check; then
    echo "CONVERGED"; exit 0
  fi

  if [[ $NESTED -eq 0 ]]; then
    bash "$PLAN_FILE_SH" gc-verdicts "$PLAN" 2>/dev/null || true
  fi

  iter=$((iter + 1))

  if [[ -L "$_log_dir" ]]; then
    echo "[run-critic-loop] FATAL: sidecar dir $_log_dir is a symlink — refusing" >&2
    _an \
      "[BLOCKED:harness] run-critic-loop: sidecar-symlink — sidecar dir is a symlink, potential redirect attack; remove the symlink manually" 2>/dev/null || true
    exit 1
  fi
  mkdir -p "$_log_dir" 2>/dev/null || true

  # ── Codex-driven path (critic-spec, critic-test, critic-code, critic-cross, critic-quality) ──
  if _is_codex_driven_agent "$AGENT" 2>/dev/null; then

    # Common: fixed log path used by all paths below
    _review_log="${_log_dir}/codex-critic-${AGENT}-last.log"
    _codex_review_exit=0

    _angles_dir="${_CRITIC_WS_ROOT}/skills/${AGENT}/angles"
    if [[ -d "$_angles_dir" ]] && compgen -G "${_angles_dir}/*.md" >/dev/null 2>&1; then
      # ── Fan-out path: one codex per angle, then aggregate ──
      _sandbox_guard || {
        _an \
          "[BLOCKED:env] ${AGENT}: sandbox-unavailable — Tier 1 sandbox inactive; set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined" 2>/dev/null || true
        exit 1
      }
      _angle_logs=() _angle_pids=()
      for _angle_file in "${_angles_dir}"/*.md; do
        _angle_name=$(basename "$_angle_file" .md)
        _angle_prompt=$(mktemp /tmp/critic-${AGENT}-angle-${_angle_name}.XXXXXX)
        _angle_log="${_log_dir}/codex-critic-${AGENT}-angle-${_angle_name}.log"
        if ! build_review_prompt "$AGENT" "$_angle_prompt" "$_angle_file"; then
          rm -f "$_angle_prompt"
          _an \
            "[BLOCKED:env] ${AGENT}: angle-prompt-build-failed — ${_angle_file}" 2>/dev/null || true
          exit 1
        fi
        _angle_logs+=("$_angle_log")
        (
          run_engine --role "$AGENT" --prompt-file "$_angle_prompt" --out "$_angle_log" --timeout "$SESSION_TIMEOUT"
          _ae=$_ENGINE_RC
          rm -f "$_angle_prompt"
          exit $_ae
        ) &
        _angle_pids+=($!)
      done
      for _apid in "${_angle_pids[@]}"; do
        wait "$_apid" || { _apid_exit=$?; [[ $_apid_exit -eq 124 ]] && _codex_review_exit=124; }
      done
      aggregate_angle_verdicts "$_review_log" "${_angle_logs[@]}"
    else
      # ── Single codex path (original — no angles/ dir) ──
      _review_prompt=$(mktemp /tmp/critic-${AGENT}-review.XXXXXX)
      if ! build_review_prompt "$AGENT" "$_review_prompt"; then
        _an \
          "[BLOCKED:env] ${AGENT}: review-prompt-build-failed — check skills/${AGENT}/SKILL.md" 2>/dev/null || true
        rm -f "$_review_prompt"; exit 1
      fi
      _sandbox_guard || {
        _an \
          "[BLOCKED:env] ${AGENT}: sandbox-unavailable — Tier 1 sandbox inactive; set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined" 2>/dev/null || true
        exit 1
      }
      run_engine --role "$AGENT" --prompt-file "$_review_prompt" --out "$_review_log" --timeout "$SESSION_TIMEOUT"
      _codex_review_exit=$_ENGINE_RC
      rm -f "$_review_prompt"
    fi
    # [continues with step 3 (infra failure detection) unchanged...]

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
        _an \
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

    # 6. Record verdict directly (validates enum, handles consecutive PARSE_ERROR).
    # Freeze the content-addressed input hash NOW — the snapshot the critic just judged —
    # and carry it into the verdict fact (events log). Computed once; never re-derived at
    # append time. Skipped (empty) when no --unit was threaded (legacy/additive callers).
    _H=""
    [[ -n "$UNIT" ]] && _H="$(_stage_input_hash "$PLAN" "$UNIT" "$STAGE" 2>/dev/null || echo "")"
    _rvd_exit=0
    bash "$PLAN_FILE_SH" record-verdict-direct \
      "$PLAN" "$AGENT" "$PHASE" "$_verdict" "$_category" "$UNIT" "$_H" || _rvd_exit=$?
    # record-verdict-direct exits 1 BY DESIGN after persisting a FAIL/PARSE_ERROR verdict
    # (_persist_verdict:686 / _handle_parse_error:498); PASS exits 0. Only a deviation from this
    # contract is a genuine recorder failure (e.g. require_file exit 2, lock-absent die).
    _rvd_expected=0
    [[ "$_verdict" == "FAIL" || "$_verdict" == "PARSE_ERROR" ]] && _rvd_expected=1
    if [[ "$_rvd_exit" -ne "$_rvd_expected" ]]; then
      _an \
        "[BLOCKED:env] ${AGENT}: verdict-record-failure — record-verdict-direct exited ${_rvd_exit} (expected ${_rvd_expected}); check plan-file.sh" \
        2>/dev/null || true
      echo "[BLOCKED:env] ${AGENT}: record-verdict-direct failed (exit ${_rvd_exit}, expected ${_rvd_expected})" >&2; exit 1
    fi

    # 7. Re-check blocked/ceiling after verdict recording
    if _ceiling_check; then
      echo "[BLOCKED:ceiling] ${AGENT}: exceeded critic ceiling" >&2; exit 2
    fi
    if bash "$PLAN_FILE_SH" is-blocked "$PLAN" 2>/dev/null; then
      echo "[BLOCKED:*] active block after verdict record — exiting" >&2; exit 1
    fi

    # 8. Branch on verdict
    if [[ "$_verdict" == "PASS" ]]; then
      # Pass-audit gate uses the FROZEN hash (_H) so 1st/2nd PASS share input identity (no racy re-read).
      if _conv_check "$_H"; then
        # 2nd consecutive PASS — one Claude call for REJECT-PASS check only
        _pass_audit_prompt=$(mktemp /tmp/critic-${AGENT}-passaudit.XXXXXX)
        build_pass_audit_prompt "$AGENT" "$_review_log" "$PLAN" "$_pass_audit_prompt"

        _pass_check_out=""
        _sandbox_guard || {
          _an \
            "[BLOCKED:env] ${AGENT}: sandbox-unavailable — Tier 1 sandbox inactive; set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined" 2>/dev/null || true
          exit 1
        }
        _pass_exit=0
        run_engine --role critic-pass-audit --prompt-file "$_pass_audit_prompt" \
          --capture _pass_check_out --timeout "$SESSION_TIMEOUT" --env CLAUDE_NONINTERACTIVE=1
        rm -f "$_pass_audit_prompt"
        _pass_exit=$_ENGINE_RC
        if [[ "$_pass_exit" -eq 124 ]]; then
          _record_transient "$PLAN" "$AGENT" session-timeout \
            "PASS audit timed out after ${SESSION_TIMEOUT}s — increase CLAUDE_CRITIC_SESSION_TIMEOUT or re-run" \
            "$PLAN_FILE_SH" 2>/dev/null || true
          echo "[transient] session-timeout on PASS audit after ${SESSION_TIMEOUT}s" >&2; exit 1
        fi

        if printf '%s' "$_pass_check_out" | grep -q 'VERDICT: REJECT-PASS'; then
          _reject_reason=$(printf '%s' "$_pass_check_out" | \
            grep 'VERDICT: REJECT-PASS' | sed 's/VERDICT: REJECT-PASS[[:space:]]*—[[:space:]]*//' | \
            head -1 | cut -c1-120 || echo "gap found")
          _audit_reject "REJECT-PASS: ${_reject_reason}"   # break events streak at frozen _H
          bash "$PLAN_FILE_SH" append-audit "$PLAN" "$AGENT" "REJECT-PASS" \
            "audit overrode PASS — ${_reject_reason}" 2>/dev/null || true
          # Fall through to NOOP check and loop again
        elif printf '%s' "$_pass_check_out" | grep -q 'VERDICT: ACCEPT'; then
          bash "$PLAN_FILE_SH" append-audit "$PLAN" "$AGENT" "ACCEPT" \
            "convergence verified" 2>/dev/null || true
          echo "CONVERGED"; exit 0
        else
          # Audit produced no recognisable verdict — treat as transient and retry
          _audit_reject "audit-inconclusive: no VERDICT line"   # break events streak at frozen _H
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
      _sandbox_guard || {
        _an \
          "[BLOCKED:env] ${AGENT}: sandbox-unavailable — Tier 1 sandbox inactive; set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined" 2>/dev/null || true
        exit 1
      }
      _dec_exit=0
      run_engine --role critic-decision --prompt-file "$_decision_prompt" \
        --capture _decision_out --timeout "$SESSION_TIMEOUT" \
        --env CLAUDE_NONINTERACTIVE=1 --env "CLAUDE_PLAN_FILE=$PLAN"
      rm -f "$_decision_prompt"
      _dec_exit=$_ENGINE_RC
      if [[ "$_dec_exit" -eq 124 ]]; then
        _record_transient "$PLAN" "$AGENT" session-timeout \
          "decision agent timed out after ${SESSION_TIMEOUT}s — increase CLAUDE_CRITIC_SESSION_TIMEOUT or re-run" \
          "$PLAN_FILE_SH" 2>/dev/null || true
        echo "[transient] session-timeout on decision agent after ${SESSION_TIMEOUT}s" >&2; exit 1
      fi

      _audit_outcome=$(parse_audit_outcome "$_decision_out")

      if [[ -z "$_audit_outcome" ]]; then
        _an \
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
          _sandbox_guard || {
            _an \
              "[BLOCKED:env] ${AGENT}: sandbox-unavailable — Tier 1 sandbox inactive; set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined" 2>/dev/null || true
            exit 1
          }
          run_engine --role critic-fix --prompt-file "$_fix_prompt" --out "$_fix_log" --timeout "$SESSION_TIMEOUT"
          _fix_exit=$_ENGINE_RC
          rm -f "$_fix_prompt"
          [[ $_fix_exit -ne 0 ]] && \
            echo "[run-critic-loop] WARN: codex fix exit ${_fix_exit} for ${AGENT}" >&2
        fi
      fi

      # For BLOCKED-AMBIGUOUS: append [BLOCKED:spec] and [BLOCKED:docs] markers after fix pass
      if [[ "$_audit_outcome" == "BLOCKED-AMBIGUOUS" ]]; then
        while IFS= read -r _bs_line; do
          [[ -n "$_bs_line" ]] || continue
          _an "$_bs_line" 2>/dev/null || true
        done < <(printf '%s' "$_decision_out" | grep -E '^\[BLOCKED:(spec|docs)\]' || true)
      fi

      # Re-check blocked after potential BLOCKED-AMBIGUOUS markers
      if bash "$PLAN_FILE_SH" is-blocked "$PLAN" 2>/dev/null; then
        echo "[BLOCKED:*] blocked after fix — exiting" >&2; exit 1
      fi
    fi
    # PARSE_ERROR: record-verdict-direct handled consecutive check; loop continues

  else
    # ── B-session path (critic-feature) ──────────────────────────────────────────

    _wrapped_plan_ref=$(printf 'agent=%s phase=%s plan=%s prompt: %s' "$AGENT" "$PHASE" "$PLAN" "$PROMPT")
    _prefill=""
    [[ $iter -eq 1 && -n "$PRIOR_FAIL_LOG" ]] && _prefill=" prior_fail_log=${PRIOR_FAIL_LOG}"
    ITER_PROMPT="Run one critic iteration per ${ITER_DOC}. agent=${AGENT} phase=${PHASE} plan=${PLAN} prompt: ${PROMPT} ${_wrapped_plan_ref}${_prefill}"

    _nonce="" _session_out="" _sid=""
    _session_out=$(mktemp)
    _sandbox_guard || {
      _an \
        "[BLOCKED:env] ${AGENT}: sandbox-unavailable — Tier 1 sandbox inactive; set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined" 2>/dev/null || true
      exit 1
    }
    # Engine/model (critic-feature → claude opus, honouring CLAUDE_CRITIC_LOOP_MODEL) resolve from
    # the registry. The B-session prompt is a string; stage it to a file for run_engine, and run it
    # in a backgrounded subshell so this loop keeps PID ownership for the interrupt trap. The subshell
    # exits with the engine's exit code so `wait` still observes 124 on timeout.
    _iter_prompt_file=$(mktemp /tmp/critic-${AGENT}-bsession.XXXXXX)
    printf '%s' "$ITER_PROMPT" > "$_iter_prompt_file"
    # critic-feature records its verdict via the in-session record-verdict hook (transcript-driven,
    # no record-verdict-direct). Carry the unit + frozen input_hash through the environment so the
    # hook's cmd_record_verdict emits the events fact under the correct (unit,stage). Frozen now —
    # critic-feature only edits machine plan.md sections, so the brainstorm authored-section hash is stable.
    if [[ -n "$UNIT" ]]; then
      export CLAUDE_VERDICT_UNIT="$UNIT"
      export CLAUDE_VERDICT_INPUT_HASH="$(_stage_input_hash "$PLAN" "$UNIT" "$STAGE" 2>/dev/null || echo "")"
    fi
    ( run_engine --role critic-feature --prompt-file "$_iter_prompt_file" --out "$_session_out" \
        --timeout "$SESSION_TIMEOUT" \
        --env CLAUDE_NONINTERACTIVE=1 --env CLAUDE_CRITIC_SESSION=1 --env "CLAUDE_PLAN_FILE=$PLAN"
      exit $_ENGINE_RC ) &
    CLAUDE_PID=$!
    wait "$CLAUDE_PID" || {
      exit_code=$?
      CLAUDE_PID=""
      rm -f "$_iter_prompt_file"
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
        _an \
          "[BLOCKED:env] ${AGENT}: script-failure — exit ${exit_code}; check session logs" 2>/dev/null || true
        echo "[BLOCKED:env] script-failure: ${exit_code}" >&2; exit 1
      fi
    }
    CLAUDE_PID=""
    rm -f "$_iter_prompt_file"
    _clear_transient_for "$PLAN" "$AGENT" 2>/dev/null || true

    [[ -n "${_session_out:-}" && -s "${_session_out:-}" ]] && \
      cp "$_session_out" "${_log_dir}/last-critic-${AGENT}.log" 2>/dev/null || true
    rm -f "${_session_out:-}"; _session_out=""
  fi

  # ── NOOP detection — plan file unchanged across iterations ─────────────────
  plan_hash=$(md5 -q "$PLAN" 2>/dev/null || md5sum "$PLAN" | cut -d' ' -f1)
  if [[ "$plan_hash" == "$LAST_PLAN_HASH" ]]; then
    CONSECUTIVE_NOOP=$((CONSECUTIVE_NOOP + 1))
    if [[ $CONSECUTIVE_NOOP -ge 2 ]]; then
      _an \
        "[BLOCKED:env] ${AGENT}: plan-unchanged — for ${CONSECUTIVE_NOOP} iterations; check session logs" 2>/dev/null || true
      echo "[BLOCKED:env] plan-unchanged for $CONSECUTIVE_NOOP consecutive iterations" >&2; exit 1
    fi
  else
    CONSECUTIVE_NOOP=0
  fi
  LAST_PLAN_HASH="$plan_hash"
done
