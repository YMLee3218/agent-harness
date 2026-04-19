#!/usr/bin/env bash
# Unified dispatcher for language layer boundary checkers.
# Usage: run.sh <lang> <domain_root> <infra_root> <features_root>
# <lang>: python | ts | go | rust | java | kotlin | cs | rb

lang="${1:-}"
domain="${2:-}"
infra="${3:-}"
features="${4:-}"

if [ -z "$lang" ]; then
  echo "[run.sh] language argument required" >&2
  exit 1
fi

_dir="$(dirname "$0")"

# shellcheck source=lib/common.sh
source "$_dir/lib/common.sh"

_conf="$_dir/patterns/${lang}.conf"
if [ ! -f "$_conf" ]; then
  mkdir -p "$_dir/patterns"
  bash "$_dir/patterns.template" "$lang" > "$_conf" || exit 1
fi
# shellcheck disable=SC1090
source "$_conf"

case "$lang" in
  python)  init_layer_check "Python"               "--exclude-dir=.venv --exclude-dir=venv --exclude-dir=__pycache__ --exclude-dir=.mypy_cache --exclude-dir=dist --exclude-dir=build" ;;
  ts)      init_layer_check "TypeScript/JavaScript" "--exclude-dir=node_modules --exclude-dir=dist --exclude-dir=build --exclude-dir=.next --exclude-dir=coverage" ;;
  go)      init_layer_check "Go"                   "--exclude-dir=vendor --exclude-dir=testdata" ;;
  rust)    init_layer_check "Rust"                 "--exclude-dir=target" ;;
  java)    init_layer_check "Java"                 "--exclude-dir=target --exclude-dir=build --exclude-dir=.gradle" ;;
  kotlin)  init_layer_check "Kotlin"               "--exclude-dir=target --exclude-dir=build --exclude-dir=.gradle" ;;
  cs)      init_layer_check "C#"                   "--exclude-dir=obj --exclude-dir=bin" ;;
  rb)      init_layer_check "Ruby"                 "--exclude-dir=vendor --exclude-dir=tmp --exclude-dir=log" ;;
  *)       echo "[run.sh] unknown language: ${lang}" >&2; exit 1 ;;
esac

run_layer_checks
