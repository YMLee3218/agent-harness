#!/usr/bin/env bash
# Telegram notification helpers for stop-check.sh.
# Provides .env file parsing and BLOCKED-AMBIGUOUS notification.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_TELEGRAM_NOTIFY_LOADED:-}" ]] && return 0
_TELEGRAM_NOTIFY_LOADED=1

# _parse_env_file is defined in stop-check.sh (primary) or here as fallback for standalone use.
# Handles values containing '=' and files without trailing newline.
if ! declare -F _parse_env_file >/dev/null 2>&1; then
  _parse_env_file() {
    while IFS= read -r _pef_line || [ -n "$_pef_line" ]; do
      [[ "$_pef_line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$_pef_line" ]] && continue
      _pef_ek="${_pef_line%%=*}"
      _pef_ev="${_pef_line#*=}"
      [[ "$_pef_ek" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
      _pef_ev="${_pef_ev%\"}"; _pef_ev="${_pef_ev#\"}"
      _pef_ev="${_pef_ev%\'}"; _pef_ev="${_pef_ev#\'}"
      export "$_pef_ek=$_pef_ev"
    done < "$1"
  }
fi

# telegram_send_blocked_ambiguous PLAN_SLUG QUESTION ENV_FILE ACCESS_FILE
# Sends a BLOCKED-AMBIGUOUS notification via Telegram if credentials exist.
# Returns 0 if notification sent, 1 if credentials missing or invalid.
telegram_send_blocked_ambiguous() {
  local _slug="$1" _question="$2" _env_file="$3" _access_file="$4"
  [ -f "$_env_file" ] && [ -f "$_access_file" ] || return 1
  _parse_env_file "$_env_file"
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    if ! [[ "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{20,50}$ ]]; then
      echo "[stop-check] WARNING: TELEGRAM_BOT_TOKEN has invalid shape — skipping Telegram notification" >&2
      unset TELEGRAM_BOT_TOKEN
    fi
  fi
  local _chat
  _chat=$(jq -r '.allowFrom[0] // ""' "$_access_file" 2>/dev/null || true)
  if [ -n "${_chat:-}" ]; then
    [[ "$_chat" =~ ^-?[0-9]+$ ]] || { echo "[stop-check] WARNING: invalid chat_id shape — skipping Telegram" >&2; _chat=""; }
  fi
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${_chat:-}" ] || return 1
  local _clear_key _msg
  _clear_key=$(printf '%s' "$_question" | sed 's/^\(\[BLOCKED-AMBIGUOUS\] [^:]*\):.*/\1/')
  _msg="[BLOCKED-AMBIGUOUS] Autonomous run paused — human decision required

Plan: ${_slug}
${_question}

To resume, run in terminal:
bash .claude/scripts/plan-file.sh clear-marker plans/${_slug}.md \"${_clear_key}\""
  curl -s -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${_chat}" \
    --data-urlencode "text=${_msg}" >/dev/null 2>&1 || true
  return 0
}
