#!/usr/bin/env bash
# engine-runner.sh — the single dispatcher for LLM / agent engine spawns (claude, codex).
# Source this file; do not execute directly.
#
# run_engine absorbs the three historical spawn idioms (worker_exec function form, the
# timeout+sandbox array splice, and the env -u capability strip) into ONE guarded command
# array. It is the sole place that builds an engine command line, so the fail-closed sandbox
# gate is centralized here and no raw `codex exec` / `claude` call can bypass it.
#
# CRITICAL (footgun #1): the timeout binary cannot wrap a shell function — it execs a
# binary. run_engine therefore builds a command ARRAY in the exact order
#   [timeout --kill-after=N S]  [sandbox-exec …]  env -u CLAUDE_PLAN_CAPABILITY [K=V…]  <engine argv>
# and NEVER calls `$TIMEOUT_CMD run_engine`. The capability strip (env -u) stays INSIDE the
# sandbox layer, immediately before the engine binary, so the worker never sees the harness
# capability (confinement invariant, footgun #2).
set -euo pipefail
[[ -n "${_ENGINE_RUNNER_LOADED:-}" ]] && return 0
_ENGINE_RUNNER_LOADED=1

_ENGINE_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_SANDBOX_LIB_LOADED:-}" ]]    || . "$_ENGINE_RUNNER_DIR/sandbox-lib.sh"
[[ -n "${_TIMEOUT_GUARD_LOADED:-}" ]]  || . "$_ENGINE_RUNNER_DIR/timeout-guard.sh"
[[ -n "${_ENGINE_REGISTRY_LOADED:-}" ]] || . "$_ENGINE_RUNNER_DIR/engine-registry.sh"

# Outputs (set by run_engine for the caller to read):
#   _ENGINE_RC           — engine process exit code (124 = wall-clock timeout). 0 on success.
#   _ENGINE_SANDBOX_FAIL — 1 when the fail-closed sandbox gate refused to spawn (engine never ran).
_ENGINE_RC=0
_ENGINE_SANDBOX_FAIL=0

# _engine_exec — runs the assembled command array, supplying codex's prompt over stdin.
# Relies on dynamic scope to see run_engine's locals (_engine, _cmd, _prompt_file).
_engine_exec() {
  if [[ "$_engine" == "codex" ]]; then
    "${_cmd[@]}" < "$_prompt_file"
  else
    "${_cmd[@]}"
  fi
}

# run_engine --role ROLE [--engine E] [--model M] --prompt-file PATH
#            [--out FILE | --capture VARNAME] [--timeout S] [--cwd DIR]
#            [--env KEY=VAL]... [--extra ARG]...
#
# Delivery mode is decided by the engine, NOT the caller (footgun #5):
#   codex  → prompt on stdin (`- < PROMPT_FILE`)
#   claude → prompt as `-p "$(cat PROMPT_FILE)"`
# Output mode:
#   --out FILE     → > FILE 2>&1            (codex logs; parser reads stderr sentinels)
#   --capture VAR  → VAR=$(… 2>/dev/null)   (claude decision/audit; clean stdout)
#   (neither)      → inherit stdout/stderr  (orchestrator run_llm streaming)
# Engine/model resolve from the registry when --engine/--model are omitted.
# Returns 0 on all runtime paths (read _ENGINE_RC / _ENGINE_SANDBOX_FAIL); 2 on arg misuse.
run_engine() {
  local _role="" _engine="" _model="" _model_set=0 _prompt_file=""
  local _out_file="" _capture_var="" _timeout="" _has_timeout=0 _cwd=""
  local _envs=() _extra=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)        _role="$2"; shift 2 ;;
      --engine)      _engine="$2"; shift 2 ;;
      --model)       _model="$2"; _model_set=1; shift 2 ;;
      --prompt-file) _prompt_file="$2"; shift 2 ;;
      --out)         _out_file="$2"; shift 2 ;;
      --capture)     _capture_var="$2"; shift 2 ;;
      --timeout)     _timeout="$2"; _has_timeout=1; shift 2 ;;
      --cwd)         _cwd="$2"; shift 2 ;;
      --env)         _envs+=("$2"); shift 2 ;;
      --extra)       _extra+=("$2"); shift 2 ;;
      *) echo "[engine] ERROR: unknown argument: $1" >&2; return 2 ;;
    esac
  done

  _ENGINE_RC=0
  _ENGINE_SANDBOX_FAIL=0

  [[ -n "$_prompt_file" ]] || { echo "[engine] ERROR: --prompt-file is required" >&2; return 2; }
  [[ -n "$_out_file" && -n "$_capture_var" ]] && { echo "[engine] ERROR: --out and --capture are mutually exclusive" >&2; return 2; }

  # Resolve engine/model from the registry when not explicitly provided.
  if [[ -z "$_engine" ]]; then
    _engine=$(engine_for "$_role") || { echo "[engine] ERROR: unknown role: ${_role:-<none>}" >&2; return 2; }
  fi
  if [[ "$_model_set" -eq 0 ]]; then
    _model=$(model_for "$_role" 2>/dev/null) || _model=""
  fi

  # Build the engine argv (footgun #5: delivery mode keyed on engine; #8: -m only when set).
  local _engine_argv=()
  case "$_engine" in
    codex)
      _engine_argv=(codex exec --dangerously-bypass-approvals-and-sandbox)
      [[ -n "$_model" ]] && _engine_argv+=(-m "$_model")
      [[ ${#_extra[@]} -gt 0 ]] && _engine_argv+=("${_extra[@]}")
      _engine_argv+=(-)
      ;;
    claude)
      _engine_argv=(claude --model "$_model" --permission-mode auto --dangerously-skip-permissions)
      [[ ${#_extra[@]} -gt 0 ]] && _engine_argv+=("${_extra[@]}")
      _engine_argv+=(-p "$(cat "$_prompt_file")")
      ;;
    *) echo "[engine] ERROR: unknown engine: $_engine" >&2; return 2 ;;
  esac

  # Fail-closed sandbox gate — the one central guard (footgun #3). Never spawn raw.
  if ! _sandbox_guard; then
    _ENGINE_SANDBOX_FAIL=1
    _ENGINE_RC=1
    return 0
  fi

  # Assemble the full command array: timeout → sandbox → env strip+inject → engine.
  local _cmd=()
  if [[ "$_has_timeout" -eq 1 && -n "${TIMEOUT_CMD:-}" && "$_timeout" != "0" ]]; then
    _cmd+=("$TIMEOUT_CMD" "--kill-after=$TG_KILL_AFTER" "$_timeout")
  fi
  [[ ${#_WORKER_SANDBOX_ARGS[@]} -gt 0 ]] && _cmd+=("${_WORKER_SANDBOX_ARGS[@]}")
  _cmd+=(env -u CLAUDE_PLAN_CAPABILITY)
  [[ ${#_envs[@]} -gt 0 ]] && _cmd+=("${_envs[@]}")
  _cmd+=("${_engine_argv[@]}")

  # Execute in the requested output mode. Capture/out assignments are split from the
  # exit-status read so `124` (timeout) survives command substitution (footgun #6).
  if [[ -n "$_capture_var" ]]; then
    local _cap=""
    if [[ -n "$_cwd" ]]; then
      _cap=$( cd "$_cwd" && _engine_exec 2>/dev/null ) || _ENGINE_RC=$?
    else
      _cap=$( _engine_exec 2>/dev/null ) || _ENGINE_RC=$?
    fi
    printf -v "$_capture_var" '%s' "$_cap"
  elif [[ -n "$_out_file" ]]; then
    if [[ -n "$_cwd" ]]; then
      ( cd "$_cwd" && _engine_exec ) > "$_out_file" 2>&1 || _ENGINE_RC=$?
    else
      _engine_exec > "$_out_file" 2>&1 || _ENGINE_RC=$?
    fi
  else
    if [[ -n "$_cwd" ]]; then
      ( cd "$_cwd" && _engine_exec ) || _ENGINE_RC=$?
    else
      _engine_exec || _ENGINE_RC=$?
    fi
  fi
  return 0
}
