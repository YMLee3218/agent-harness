#!/usr/bin/env bash
# Dispatcher — exit codes: 0=success 1=error 2=not-found/blocked 3=ambiguous(find-active) 4=malformed(find-active); query commands (is-blocked, is-converged): 0=true 1=false 2=jq-missing|plan-not-found
# Marker side-effects: reference/markers.md §Stop marker taxonomy
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/plan-lib.sh"
. "$SCRIPT_DIR/lib/plan-loop-helpers.sh"
. "$SCRIPT_DIR/lib/plan-cmd.sh"

[ $# -ge 1 ] || die "Usage: plan-file.sh <command> [args...]"

# Capability ring gate
case "$1" in
  # Ring A — agent-callable: read-only or narrative-safe
  init|get-phase|find-active|find-latest|context|append-note|tier-safe|is-converged|is-blocked|get-envelope|get-task-unit) ;;
  # Ring A — events-recompute query commands (pure reads over events/{scope}.jsonl)
  ev-converged|ev-implemented|ev-blocked|ev-ceiling|stage-satisfied) ;;

  # Ring B — CLAUDE_PLAN_CAPABILITY=harness required (harness scripts; human operators: export CLAUDE_PLAN_CAPABILITY=harness): state mutators
  set-phase|transition|commit-phase|add-task|update-task|reset-milestone|reset-pr-review|\
  reset-for-rollback|record-verdict|record-verdict-guarded|record-verdict-direct|\
  gc-events|gc-verdicts|record-task-completed|record-stop-block|\
  inter-feature-reset|set-task-unit|clear-task-state|resume-sweep)
    require_capability "$1" B
    if [ "$1" = "record-verdict" ]; then
      _rv_plan=$(cmd_find_active 2>/dev/null) || _rv_plan=""
      if [ -n "$_rv_plan" ] && [ ! -f "${_rv_plan}.critic.lock" ]; then
        die "BLOCKED: ${_rv_plan##*/}.critic.lock absent — record-verdict requires run-critic-loop.sh context"
      fi
    fi
    if [ "$1" = "record-verdict-direct" ]; then
      [ $# -ge 2 ] || die "Usage: plan-file.sh record-verdict-direct <plan-file> <agent> <phase> <verdict> [category]"
      [ -f "$2.critic.lock" ] || die "BLOCKED: ${2##*/}.critic.lock absent — record-verdict-direct requires run-critic-loop.sh context"
    fi
    ;;

  # Critic-loop B-session mutators — gated by .critic.lock presence only.
  # The lock proves genuine run-critic-loop.sh context for these commands regardless of capability.
  append-audit|clear-converged)
    [ $# -ge 2 ] || die "Usage: plan-file.sh $1 <plan-file> ..."
    [ -f "$2.critic.lock" ] || die "BLOCKED: ${2##*/}.critic.lock absent — $1 requires run-critic-loop.sh context"
    ;;

  # Ring C — human-only
  unblock)
    require_capability "$1" C ;;

  *)
    die "[$1] is not registered in any capability ring — add to Ring A/B/C in the case block above" ;;
esac

case "$1" in
  init)                 [ $# -ge 2 ] || die "Usage: plan-file.sh init <plan-file> [mode]"; cmd_init "$2" "${3:-}" ;;
  get-phase)            [ $# -eq 2 ] || die "Usage: plan-file.sh get-phase <plan-file>"; cmd_get_phase "$2" ;;
  set-phase)            [ $# -eq 3 ] || die "Usage: plan-file.sh set-phase <plan-file> <phase>"; cmd_set_phase "$2" "$3" ;;
  append-audit)         [ $# -eq 5 ] || die "Usage: plan-file.sh append-audit <plan-file> <agent> <ACCEPT|ACCEPT-OVERRIDE|REJECT-PASS|BLOCKED-AMBIGUOUS> <summary>"; cmd_append_audit "$2" "$3" "$4" "$5" ;;
  append-note)          [ $# -ge 3 ] || die "Usage: plan-file.sh append-note <plan-file> <note> [unit] [stage]"; cmd_append_note "$2" "$3" "${4:-}" "${5:-}" ;;
  find-active)          cmd_find_active ;;
  find-latest)          cmd_find_latest ;;
  record-verdict)         cmd_record_verdict ;;
  record-verdict-guarded)   cmd_record_verdict_guarded ;;
  record-verdict-direct) [ $# -ge 5 ] || die "Usage: plan-file.sh record-verdict-direct <plan-file> <agent> <phase> <verdict> [category] [unit] [input-hash]"; cmd_record_verdict_direct "$2" "$3" "$4" "$5" "${6:-}" "${7:-}" "${8:-}" ;;
  record-task-completed)  cmd_record_task_completed ;;
  context)              cmd_context "${2:-}" ;;
  gc-events)            cmd_gc_events ;;
  gc-verdicts)          [ $# -eq 2 ] || die "Usage: plan-file.sh gc-verdicts <plan-file>"; cmd_gc_verdicts "$2" ;;
  add-task)             [ $# -eq 4 ] || die "Usage: plan-file.sh add-task <plan-file> <task-id> <layer>"; cmd_add_task "$2" "$3" "$4" ;;
  update-task)          [ $# -ge 4 ] || die "Usage: plan-file.sh update-task <plan-file> <task-id> <status> [commit-sha]"; cmd_update_task "$2" "$3" "$4" "${5:--}" ;;
  record-stop-block)    [ $# -eq 4 ] || die "Usage: plan-file.sh record-stop-block <plan-file> <phase> <reason>"; cmd_record_stop_block "$2" "$3" "$4" ;;
  unblock)              [ $# -le 2 ] || die "Usage: plan-file.sh unblock [plan-file]"; cmd_unblock "${2:-}" ;;
  clear-converged)      [ $# -eq 3 ] || die "Usage: plan-file.sh clear-converged <plan-file> <agent>"; cmd_clear_converged "$2" "$3" ;;
  reset-milestone)      [ $# -eq 3 ] || die "Usage: plan-file.sh reset-milestone <plan-file> <agent>"; cmd_reset_milestone "$2" "$3" ;;
  reset-pr-review)      [ $# -eq 2 ] || die "Usage: plan-file.sh reset-pr-review <plan-file>"; cmd_reset_pr_review "$2" ;;
  reset-for-rollback)   [ $# -eq 3 ] || die "Usage: plan-file.sh reset-for-rollback <plan-file> <target-phase>"; cmd_reset_phase_state "$2" "$3" ;;
  transition)           [ $# -eq 4 ] || die "Usage: plan-file.sh transition <plan-file> <to-phase> <reason>"; cmd_transition "$2" "$3" "$4" ;;
  commit-phase)         [ $# -eq 3 ] || die "Usage: plan-file.sh commit-phase <plan-file> <commit-message>"; cmd_commit_phase "$2" "$3" ;;
  tier-safe)            [ $# -ge 3 ] || die "Usage: plan-file.sh tier-safe <plan-file> <task-id>..."; cmd_tier_safe "$2" "${@:3}" ;;
  is-converged)         [ $# -eq 4 ] || die "Usage: plan-file.sh is-converged <plan-file> <phase> <agent>"; cmd_is_converged "$2" "$3" "$4" ;;
  is-blocked) [ $# -ge 2 ] || die "Usage: plan-file.sh is-blocked <plan-file> [kind]"; cmd_is_blocked "$2" "${3:-}" ;;
  # events-recompute readers: rc0=true/SKIP, rc1=false/RUN (pure functions over events log)
  ev-converged)    [ $# -ge 4 ] || die "Usage: plan-file.sh ev-converged <plan> <unit> <stage> [frozen-hash]"; ev_is_converged "$2" "$3" "$4" "${5:-}" ;;
  ev-implemented)  [ $# -eq 3 ] || die "Usage: plan-file.sh ev-implemented <plan> <unit>"; ev_is_implemented "$2" "$3" ;;
  ev-blocked)      [ $# -eq 4 ] || die "Usage: plan-file.sh ev-blocked <plan> <unit> <stage>"; ev_is_blocked "$2" "$3" "$4" ;;
  ev-ceiling)      [ $# -eq 4 ] || die "Usage: plan-file.sh ev-ceiling <plan> <unit> <stage>"; ev_ceiling_reached "$2" "$3" "$4" ;;
  stage-satisfied) [ $# -eq 4 ] || die "Usage: plan-file.sh stage-satisfied <plan> <unit> <stage>"; stage_is_satisfied "$2" "$3" "$4" ;;
  get-envelope)         [ $# -eq 2 ] || die "Usage: plan-file.sh get-envelope <plan-file>"; cmd_get_envelope "$2" ;;
  inter-feature-reset)  [ $# -eq 2 ] || die "Usage: plan-file.sh inter-feature-reset <plan-file>"; cmd_inter_feature_reset "$2" ;;
  set-task-unit)        [ $# -eq 3 ] || die "Usage: plan-file.sh set-task-unit <plan-file> <unit-key>"; cmd_set_task_unit "$2" "$3" ;;
  get-task-unit)        [ $# -eq 2 ] || die "Usage: plan-file.sh get-task-unit <plan-file>"; cmd_get_task_unit "$2" ;;
  clear-task-state)     [ $# -eq 2 ] || die "Usage: plan-file.sh clear-task-state <plan-file>"; cmd_clear_task_state "$2" ;;
  resume-sweep)         [ $# -eq 2 ] || die "Usage: plan-file.sh resume-sweep <plan-file>"; cmd_resume_sweep "$2" ;;
  *) die "Unknown command: $1" ;;
esac
