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
run "git commit --amend (warn only)"   "$(j 'git commit --amend')"                  0
run "git commit -m x --amend"          "$(j 'git commit -m x --amend')"             0
run "git commit --fixup HEAD"          "$(j 'git commit --fixup HEAD')"             0
run "truncate table_backup.sql"        "$(j 'truncate table_backup.sql')"           0

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
