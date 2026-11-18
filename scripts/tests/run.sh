#!/usr/bin/env bash
# Offline checks for the repo tooling: shellcheck on every script and hook, then the shell
# test files that need no database. check-rls-coverage.test.sh needs the stack and runs
# separately in CI.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

status=0
echo "== shellcheck"
# shellcheck disable=SC2046 # word splitting of the file list is intended
shellcheck -x -P .claude/hooks:scripts/tests $(git ls-files -co --exclude-standard '*.sh') || status=1

for t in config hooks check-migrations review-gate; do
  echo "== $t"
  "scripts/tests/$t.test.sh" || status=1
done
exit $status
