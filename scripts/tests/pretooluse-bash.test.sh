#!/usr/bin/env bash
# Regression tests for pretooluse-bash.sh
# Usage: bash pretooluse-bash.test.sh
# Exit 0 = all tests passed; exit 1 = at least one failure.

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/pretooluse-bash.sh"
PASS=0
FAIL=0

run() {
  local desc="$1" input="$2" want_exit="$3"
  local got_exit
  printf '%s' "$input" | bash "$SCRIPT" >/dev/null 2>&1
  got_exit=$?
  if [ "$got_exit" -eq "$want_exit" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit $want_exit, got $got_exit)"
    FAIL=$((FAIL + 1))
  fi
}

j() { printf '{"tool_input":{"command":"%s"}}' "$1"; }

# --- Must be blocked (exit 2) ---
run "rm -rf /tmp/x"                    "$(j 'rm -rf /tmp/x')"                       2
run "rm -rf/tmp/x (no space)"          "$(j 'rm -rf/tmp/x')"                        2
run "sudo rm -rf /"                    "$(j 'sudo rm -rf /')"                        2
run "rm -fr /tmp/x"                    "$(j 'rm -fr /tmp/x')"                       2
run "rm -fr/tmp/x (no space)"          "$(j 'rm -fr/tmp/x')"                        2
run "sudo rm -fr /"                    "$(j 'sudo rm -fr /')"                        2
run "dd if=/dev/zero"                  "$(j 'dd if=/dev/zero of=/dev/sda')"          2
run "mkfs.ext4"                        "$(j 'mkfs.ext4 /dev/sdb1')"                  2
run "echo x > /dev/sda"               "$(j 'echo x > /dev/sda')"                   2
run "git push --force"                 "$(j 'git push --force')"                    2
run "git push -f origin main"          "$(j 'git push -f origin main')"             2
run "git clean -fd ."                  "$(j 'git clean -fd .')"                     2
run "DROP TABLE"                       "$(j 'DROP TABLE users')"                    2
run "TRUNCATE TABLE"                   "$(j 'TRUNCATE TABLE orders')"               2
run "DROP DATABASE"                    "$(j 'DROP DATABASE mydb')"                  2
run "git commit -m x --no-verify"      "$(j 'git commit -m x --no-verify')"         2
run "git commit --no-verify -m x"      "$(j 'git commit --no-verify -m x')"         2

# --- Must be allowed (exit 0) ---
run "ls -rf /tmp (safe)"               "$(j 'ls -rf /tmp')"                         0
run "git push origin feature/x"        "$(j 'git push origin feature/x')"           0
run "git commit -m x (safe)"           "$(j 'git commit -m x')"                     0
run "git commit --fixup HEAD"          "$(j 'git commit --fixup HEAD')"             0
run "truncate table_backup.sql"        "$(j 'truncate table_backup.sql')"           0

# --- git commit --amend: context-sensitive ---
# When HEAD is in a remote tracking branch: blocked (exit 2).
# When not in a remote: warn and allow (exit 0).
# The test runs in a temp dir with no git → git branch -r fails → warn-only path.
TMPAMEND=$(mktemp -d)
cleanup_amend() { rm -rf "$TMPAMEND"; }
trap "cleanup_amend; ${_cleanup_prev:-true}" EXIT

(cd "$TMPAMEND" && {
  # No git repo → git branch -r returns nothing → warn-only (exit 0)
  printf '%s' "$(j 'git commit --amend')" | bash "$SCRIPT" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ]; then
    echo "PASS: git commit --amend (no remote): warn-only exit 0"
    PASS=$((PASS + 1))
  else
    echo "FAIL: git commit --amend (no remote): expected exit 0, got $got"
    FAIL=$((FAIL + 1))
  fi
})

(cd "$TMPAMEND" && {
  # Simulate pushed commit: create a git repo with a fake remote ref containing HEAD
  git init -q && git config user.email "t@t" && git config user.name "T"
  echo x > f.txt && git add f.txt && git commit -q -m "init"
  # Create a fake remote tracking ref pointing at HEAD
  git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
  printf '%s' "$(j 'git commit --amend')" | bash "$SCRIPT" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 2 ]; then
    echo "PASS: git commit --amend (HEAD in remote): blocked exit 2"
    PASS=$((PASS + 1))
  else
    echo "FAIL: git commit --amend (HEAD in remote): expected exit 2, got $got"
    FAIL=$((FAIL + 1))
  fi
})

# --- Bypass patterns (exit 2) ---
run "pipe-to-bash: echo payload | bash"    "$(j 'echo rm -rf / | bash')"               2
run "pipe-to-sh: payload | sh"             "$(j 'cat script.sh | sh')"                 2
run "git -c hooksPath bypass"              "$(j 'git -c core.hooksPath=/dev/null commit')" 2

# --- chmod: must be blocked (world-writable) ---
run "chmod 777 (world-writable)"           "$(j 'chmod 777 /tmp/x')"                   2
run "chmod 776 (others write)"             "$(j 'chmod 776 /tmp/x')"                   2
run "chmod 773 (others write+exec)"        "$(j 'chmod 773 /tmp/x')"                   2
run "chmod 772 (others write-only)"        "$(j 'chmod 772 /tmp/x')"                   2
run "chmod 1777 (sticky world-writable)"   "$(j 'chmod 1777 /tmp/x')"                  2
run "chmod -R 777 dir"                     "$(j 'chmod -R 777 mydir')"                 2
run "chmod o+w (symbolic)"                 "$(j 'chmod o+w file.sh')"                  2
run "chmod a+w (symbolic)"                 "$(j 'chmod a+w file.sh')"                  2
run "chmod a+rw (symbolic)"               "$(j 'chmod a+rw file.sh')"                 2

# --- chmod: must be allowed (safe modes) ---
run "chmod 755 (safe)"                     "$(j 'chmod 755 file.sh')"                  0
run "chmod 644 (safe)"                     "$(j 'chmod 644 file.txt')"                 0
run "chmod 700 (safe)"                     "$(j 'chmod 700 script.sh')"                0
run "chmod 600 (safe)"                     "$(j 'chmod 600 secret.key')"               0
run "chmod 750 (safe)"                     "$(j 'chmod 750 dir')"                      0
run "chmod +x (safe symbolic)"             "$(j 'chmod +x script.sh')"                 0
run "chmod u+w (safe symbolic)"            "$(j 'chmod u+w file.txt')"                 0
run "chmod 0755 (safe, leading zero)"      "$(j 'chmod 0755 file.sh')"                 0

# --- cp bypass detection (phase-aware, requires active plan) ---
# Without an active plan, cp is not blocked (phase gate does not fire).
# With an active plan in a blocking phase, cp to src/ or tests/ must be blocked.
TMPCP=$(mktemp -d)
PLAN_FILE_SH="$(cd "$(dirname "$SCRIPT")" && pwd)/plan-file.sh"
mkdir -p "$TMPCP/plans"
cat > "$TMPCP/plans/cp-test.md" <<'PLANEOF'
---
feature: cp-test
schema: 1
---

## Phase
red

## Critic Verdicts

## Open Questions
PLANEOF
printf '{"schema":2,"phase":"red"}' > "$TMPCP/plans/cp-test.state.json"

(cd "$TMPCP" && {
  CLAUDE_PLAN_FILE="$TMPCP/plans/cp-test.md" printf '%s' "$(j 'cp existing_file.py src/domain/target.py')" \
    | bash "$SCRIPT" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 2 ]; then
    echo "PASS: cp to src/ during red phase → blocked (exit 2)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: cp to src/ during red phase → expected exit 2, got $got"
    FAIL=$((FAIL + 1))
  fi
})

(cd "$TMPCP" && {
  CLAUDE_PLAN_FILE="$TMPCP/plans/cp-test.md" printf '%s' "$(j 'cp safe_file.py docs/notes.md')" \
    | bash "$SCRIPT" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 0 ]; then
    echo "PASS: cp to non-src/tests path during red phase → allowed (exit 0)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: cp to non-src/tests path during red phase → expected exit 0, got $got"
    FAIL=$((FAIL + 1))
  fi
})

# cp to tests/ during green phase must be blocked (tests frozen)
printf '{"schema":2,"phase":"green"}' > "$TMPCP/plans/cp-test.state.json"
(cd "$TMPCP" && {
  CLAUDE_PLAN_FILE="$TMPCP/plans/cp-test.md" printf '%s' "$(j 'cp fixture.py tests/integration/test_foo.py')" \
    | bash "$SCRIPT" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 2 ]; then
    echo "PASS: cp to tests/ during green phase → blocked (exit 2)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: cp to tests/ during green phase → expected exit 2, got $got"
    FAIL=$((FAIL + 1))
  fi
})

rm -rf "$TMPCP"

# --- Bypass patterns that should still be allowed ---
run "pipe grep (safe)"                     "$(j 'ls | grep foo')"                      0

# --- jq absent → fail-closed (exit 2) ---
if [ "$(PATH=/usr/bin command -v jq 2>/dev/null)" = "" ]; then
  PATH=/usr/bin bash "$SCRIPT" <<< '{"tool_input":{"command":"ls"}}' >/dev/null 2>&1
  got=$?
  if [ "$got" -eq 2 ]; then
    echo "PASS: jq absent → exit 2"
    PASS=$((PASS + 1))
  else
    echo "FAIL: jq absent → expected exit 2, got $got"
    FAIL=$((FAIL + 1))
  fi
else
  echo "SKIP: jq absent test (jq found in /usr/bin)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
