#!/usr/bin/env bash
# Tests for scripts/review-gate.sh.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=lib.sh
. scripts/tests/lib.sh

summary=$(mktemp)
trap 'rm -f "$summary"' EXIT

gate() {
  REVIEW_JSON=$1 GITHUB_STEP_SUMMARY=$summary scripts/review-gate.sh >/dev/null 2>&1
  echo $?
}

finding() { jq -nc --arg s "$1" '{severity: $s, title: "t | x", file: "a.sql", line: 3, detail: "d"}'; }
review() { jq -nc --argjson f "[$(IFS=,; echo "$*")]" '{complete: true, summary: "s", findings: $f}'; }

assert_eq 0 "$(gate "$(review)")" 'no findings passes'
assert_eq 0 "$(gate "$(review "$(finding low)" "$(finding medium)")")" 'low and medium pass'
assert_eq 1 "$(gate "$(review "$(finding low)" "$(finding high)")")" 'one high finding fails'
assert_eq 1 "$(gate '')" 'a missing verdict fails closed'
assert_eq 1 "$(gate 'not json')" 'an unparsable verdict fails closed'
assert_eq 1 "$(gate '{"summary": "s"}')" 'a verdict without findings fails closed'
assert_eq 1 "$(gate '{"complete": false, "summary": "subagents did not report", "findings": []}')" \
  'an incomplete review fails even without findings'
assert_eq 1 "$(gate '{"summary": "s", "findings": []}')" 'a verdict that does not say it is complete fails'

: >"$summary"
gate "$(review "$(finding high)")" >/dev/null
assert_contains "$(cat "$summary")" '1 finding(s), 1 high' 'the job summary counts findings'
assert_contains "$(cat "$summary")" 't \| x' 'pipes in titles are escaped for the table'

finish
