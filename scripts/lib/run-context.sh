#!/usr/bin/env bash
# Shared run-context helpers — language detection, dir roots, feature parsing.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_RUN_CONTEXT_LOADED:-}" ]] && return 0
_RUN_CONTEXT_LOADED=1

setup_run_context() {
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  _lang=$(grep -m1 '^- Language:' "$PROJECT_DIR/.claude/local.md" 2>/dev/null \
    | sed 's/^- Language: *//;s/ .*//' | tr '[:upper:]' '[:lower:]' \
    | sed 's/python.*/python/;s/typescript.*/ts/;s/javascript.*/ts/;s/kotlin.*/kotlin/;s/java.*/java/;s/go.*/go/;s/rust.*/rust/;s/c#.*/cs/;s/ruby.*/rb/') || true
  _lang="${_lang:-python}"
  _domain_root="${PROJECT_DIR}/src/domain";    [[ -d "$_domain_root" ]] || _domain_root="${PROJECT_DIR}/domain"
  _infra_root="${PROJECT_DIR}/src/infrastructure"; [[ -d "$_infra_root" ]] || _infra_root="${PROJECT_DIR}/infrastructure"
  _features_root="${PROJECT_DIR}/src/features";  [[ -d "$_features_root" ]] || _features_root="${PROJECT_DIR}/features"
}

_features_block() {
  local _req_file="$1"
  awk '/^## (Small|Large) Features/{f=1;next} /^## /{f=0} f&&/^[-*] /{sub(/^[-*] *`/,""); sub(/`.*/,""); print}' \
    "$_req_file" 2>/dev/null || true
}

_slugify_feature() {
  printf '%s' "$1" | tr '[:upper:] ' '[:lower:]-' | tr -dc 'a-z0-9-'
}
