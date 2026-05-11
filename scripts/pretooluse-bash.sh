#!/usr/bin/env bash
# PreToolUse hook for Bash tool.
# Reads JSON from stdin, extracts .tool_input.command, blocks destructive patterns.
# Exit 2 = blocked; exit 0 = allowed.
#
# NOTE: This is a *mistake-prevention* gate, not a security boundary.
# bash quote-removal/backslash-escape can defeat any text-pattern match here.
# Real enforcement requires process isolation (uid separation) or seccomp.
# See plan: launcher-token (deferred — scope requires launcher-token isolation).
set -euo pipefail
# shellcheck source=lib/active-plan.sh
source "$(dirname "$0")/lib/active-plan.sh"
# shellcheck source=phase-policy.sh
source "$(dirname "$0")/phase-policy.sh"
# shellcheck source=pretooluse-blocks.sh
source "$(dirname "$0")/pretooluse-blocks.sh"
# shellcheck source=pretooluse-write-guards.sh
source "$(dirname "$0")/pretooluse-write-guards.sh"
# D5: bash AST tokenizer for redirect target analysis
source "$(dirname "$0")/lib/bash-parser.sh" 2>/dev/null || true

block_awk_redirect_src_tests() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])([[:space:]]*)awk[[:space:]]'; then
    if printf '%s' "$cmd" | grep -iqE 'print[[:space:]]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?src/' \
      || printf '%s' "$cmd" | grep -iqE 'print[[:space:]]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?tests/' \
      || printf '%s' "$cmd" | grep -iqE 'printf[[:space:]]+[^>]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?src/' \
      || printf '%s' "$cmd" | grep -iqE 'printf[[:space:]]+[^>]*>{1,2}[[:space:]]*"?([^"[:space:]]*/)?tests/'; then
      echo "BLOCKED: awk internal redirect to src/ or tests/ detected — use Write/Edit tool instead" >&2
      exit 2
    fi
  fi
}

_RING_C_FILES='CLAUDE\.md|reference/(markers|critics|phase-gate-config|layers)\.md'
# _ring_c_target CMD → returns 0 (match) if CMD contains a write vector targeting a Ring C file.
_ring_c_target() {
  local _cmd="$1"
  # Destination-side pattern: optional relative/absolute prefix + Ring C filename.
  local _target_pat="(\./|\.\./|/)?(${_RING_C_FILES})\b"
  # Write-vector patterns (target-side detection): redirect, tee, dd, sed -i, truncate, mv, cp.
  if printf '%s' "$_cmd" | grep -oE '>{1,2} *[^[:space:]]+' | sed 's/^>* *//' | tr -d '"'"'" \
      | grep -qE "$_target_pat"; then return 0; fi
  if printf '%s' "$_cmd" | grep -oE '\btee( +[^[:space:]]+)+' | sed 's/^tee *//' | tr ' ' '\n' \
      | grep -qE "$_target_pat"; then return 0; fi
  if printf '%s' "$_cmd" | grep -oE '\bdd\b[^|]*\bof=[^[:space:]]+' | sed 's/.*of=//' \
      | grep -qE "$_target_pat"; then return 0; fi
  if printf '%s' "$_cmd" | grep -oE '\bsed +-i[^ ]*( +[^[:space:];|&]+)+' | awk '{print $NF}' \
      | grep -qE "$_target_pat"; then return 0; fi
  if printf '%s' "$_cmd" | grep -iqE "truncate[[:space:]]+[^|;]*(${_RING_C_FILES})"; then return 0; fi
  # mv/cp destination check (last non-flag arg)
  local _cpmv _dest
  while IFS= read -r _cpmv; do
    [[ -n "$_cpmv" ]] || continue
    _dest=$(_extract_cp_mv_dest "$_cpmv")
    printf '%s' "$_dest" | grep -qE "$_target_pat" && return 0
  done < <(printf '%s' "$_cmd" | grep -oE '(^|[;|&[:space:]])(cp|mv)([[:space:]]+(-[[:alpha:]]+|--[a-zA-Z-]+=?[^[:space:];|&]*|[^[:space:];|&]+))+' || true)
  # printf redirect (printf '...' > CLAUDE.md)
  if printf '%s' "$_cmd" | grep -qE "printf[[:space:]]+[^|;]*>[[:space:]]*(${_RING_C_FILES})\b"; then return 0; fi
  # interpreter -c with open(...,'w') targeting Ring C files
  if printf '%s' "$_cmd" | grep -qE "(python[23]?|perl|ruby|node)[[:space:]]+-[ceE][^|;]*(open|write)[^|;]*(${_RING_C_FILES})"; then return 0; fi
  # ed or silent vim targeting Ring C files
  if printf '%s' "$_cmd" | grep -qE "(^|[;|&[:space:]])[[:space:]]*(ed|vim?[[:space:]]+(-e[[:space:]]|-s[[:space:]]))[^|;]*(${_RING_C_FILES})\b"; then return 0; fi
  # awk internal redirect (awk '...' > CLAUDE.md)
  if printf '%s' "$_cmd" | grep -qE "awk[[:space:]]+[^|;]*>[[:space:]]*(${_RING_C_FILES})\b"; then return 0; fi
  return 1
}

block_ring_c_bash_writes() {
  local cmd="$1"
  [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "human" ]] && return 0
  if _ring_c_target "$cmd"; then
    echo "ERROR: [phase-gate] Ring C file (CLAUDE.md / reference policy docs) is protected — only human edits accepted (set CLAUDE_PLAN_CAPABILITY=human to override)" >&2
    exit 2
  fi
}

block_new_exec_vectors() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*socat[[:space:]]+[^|]*EXEC'; then
    echo "BLOCKED: socat EXEC — remote shell execution vector not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*(nc|ncat)[[:space:]]+[^|]*-e[[:space:]]'; then
    echo "BLOCKED: nc/ncat -e — pipe-to-shell vector not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'mkfifo' && \
     printf '%s' "$cmd" | grep -iqE '(bash|sh|zsh)[[:space:]]*<'; then
    echo "BLOCKED: mkfifo with shell redirection — pipe-to-shell vector not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(perl|ruby|php|node|deno)[[:space:]]+.*-(e|r)[[:space:]].*base64' && \
     printf '%s' "$cmd" | grep -iqE '\|[[:space:]]*(bash|sh|eval|source)'; then
    echo "BLOCKED: interpreter base64-decode pipe-to-shell — security policy denies this vector" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'osascript[[:space:]]+-e[[:space:]]+["\x27].*do[[:space:]]+shell[[:space:]]+script'; then
    echo "BLOCKED: osascript do shell script — macOS shell execution vector not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(gunzip|bzcat|zstdcat|lz4cat|xzcat|gzcat|uncompress)[[:space:]]+[^|]*\|[[:space:]]*(bash|sh|eval|source|\.)'; then
    echo "BLOCKED: compressed-stream pipe-to-shell — security policy denies pipe-to-shell vectors" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(expect|gdb)[[:space:]]+.*-c[[:space:]].*shell' || \
     printf '%s' "$cmd" | grep -iqE '(expect|gdb)[[:space:]].*spawn[[:space:]]+(bash|sh)'; then
    echo "BLOCKED: expect/gdb shell spawn — execution vector not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'vim[[:space:]].*-c[[:space:]].*![^!]' && \
     printf '%s' "$cmd" | grep -iqE 'vim[[:space:]].*-c[[:space:]]q'; then
    echo "BLOCKED: vim -c !cmd shell execution — not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE 'awk[[:space:]].*BEGIN[[:space:]]*\{[[:space:]]*system[[:space:]]*\('; then
    echo "BLOCKED: awk BEGIN{system(...)} — shell execution vector not permitted" >&2; exit 2
  fi
  if printf '%s' "$cmd" | grep -iqE '(^|[;|&[:space:]])[[:space:]]*script[[:space:]]+-[a-z]*q[a-z]*c[[:space:]]+["\x27]?(bash|sh|zsh)'; then
    echo "BLOCKED: script -qc shell — execution vector not permitted" >&2; exit 2
  fi
}

input=$(cat)

require_jq_or_block "pretooluse-bash"

cmd=$(extract_tool_input_command "$input")
if [ $? -ne 0 ]; then
  echo "BLOCKED: failed to parse hook input JSON" >&2
  exit 2
fi
if [ -z "$cmd" ] && [ -n "$input" ]; then
  echo "BLOCKED: could not extract command field from hook input" >&2
  exit 2
fi

# ── Static blocking rules ─────────────────────────────────────────────────────
block_ring_c_bash_writes "$cmd"
block_capability_spoofing "$cmd"
block_env_injection "$cmd"
block_human_marker_commands "$cmd"
block_destructive_rm "$cmd"
block_destructive_truncate "$cmd"
block_disk_commands "$cmd"
block_git_clean "$cmd"
block_git_sidecar_writes "$cmd"
block_ln_sidecar "$cmd"
block_rm_sidecar "$cmd"
block_awk_inplace_sidecar "$cmd"
block_write_tools_sidecar "$cmd"
block_interpreter_sidecar "$cmd"
block_sql_ddl "$cmd"
block_git_amend "$cmd"
block_git_hooks_bypass "$cmd"
block_pipe_to_shell "$cmd"
block_world_writable_chmod "$cmd"
block_eval_source "$cmd"
block_awk_redirect_src_tests "$cmd"
block_new_exec_vectors "$cmd"
block_new_destructive_patterns "$cmd"

# ── Phase-aware bash write detection ─────────────────────────────────────────
PLAN_FILE_SH="$(dirname "$0")/plan-file.sh"

if [ -f "$PLAN_FILE_SH" ]; then
  BLOCKED_LABEL="phase-gate/bash"
  if resolve_active_plan_and_phase _active_plan _current_phase; then
    # [BLOCKED-AMBIGUOUS] → block all bash writes (consistent with phase-gate.sh)
    if grep -qF "[BLOCKED-AMBIGUOUS]" "$_active_plan" 2>/dev/null; then
      _ba_write=0
      while IFS= read -r _ba_p; do [ -n "$_ba_p" ] && _ba_write=1 && break; done < <(_bash_dest_paths "$cmd")
      [ "$_ba_write" -eq 1 ] && { echo "BLOCKED [phase-gate/bash]: [BLOCKED-AMBIGUOUS] present — write prohibited; human must resolve the question and clear the marker from terminal" >&2; exit 2; }
      block_ambiguous_interpreter_inline "$cmd"
      block_ambiguous_interpreter_heredoc "$cmd"
      block_ambiguous_shell_inline "$cmd"
      block_ambiguous_file_install "$cmd"
      block_ambiguous_tar_extract "$cmd"
    fi
    while IFS= read -r _dest_p; do
      [ -z "$_dest_p" ] && continue
      if is_sidecar_path "$_dest_p"; then
        echo "BLOCKED [phase-gate/bash]: plans/{slug}.state/ is harness-exclusive — write denied" >&2; exit 2
      fi
      apply_phase_block "$_dest_p" "$_current_phase" "phase-gate/bash" || exit 2
    done < <(_bash_dest_paths "$cmd")
  else
    while IFS= read -r _dest_p; do
      [ -z "$_dest_p" ] && continue
      if is_sidecar_path "$_dest_p"; then
        echo "BLOCKED [phase-gate/bash]: plans/{slug}.state/ is harness-exclusive — write denied" >&2; exit 2
      fi
      bootstrap_block_if_strict "$_dest_p" || exit 2
    done < <(_bash_dest_paths "$cmd")
  fi
fi

exit 0
