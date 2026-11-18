#!/usr/bin/env bash
# Stop hook: Claude may not report work as done while the checks for what it changed fail.
#
# Changes are everything that differs from origin/main (commits on the branch, the working
# tree, untracked files). Only the suites those changes affect run:
#   supabase/functions/**                        deno check, lint, fmt, unit tests
#   supabase/migrations|tests/**, config.toml    db reset (when migrations changed), db lint,
#                                                pgTAP, RLS/policy coverage, Deno DB tests
#   scripts/**, .claude/**, .github/**           scripts/tests/run.sh (shellcheck + script tests)
# A passing change set is remembered by fingerprint, so finishing again costs nothing.
#
# Failing checks block the stop (exit 2) and Claude gets the log tail. For the red step of
# test-first work (only tests changed, no migration or function code yet), a second stop with
# no further changes is let through: by then Claude has been told the tests fail and has to
# say so. With migrations or function code in the change set, failing checks always block.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

[ "${GITHUB_ACTIONS:-}" = true ] && exit 0 # the CI review job only reads code

input=$(cat)
root=$(project_dir)
cd "$root" || exit 0
state=.claude/.state
mkdir -p "$state"

base=$(base_ref "$root") || exit 0
mb=$(git merge-base "$base" HEAD) || exit 0

untracked() {
  git ls-files -o --exclude-standard -z | while IFS= read -r -d '' f; do
    printf '%s %s\n' "$(git hash-object -- "$f")" "$f"
  done
}

changed=$({ git diff --name-only "$mb"; git ls-files -o --exclude-standard; } | grep -v '^\.claude/\.state/' | sort -u)
[ -n "$changed" ] || exit 0

fingerprint=$({ echo "$mb"; git diff --binary "$mb" -- . ":(exclude)$state"; untracked | grep -v " $state/"; } | shasum | cut -c1-40)
[ "$fingerprint" = "$(cat "$state/green" 2>/dev/null)" ] && exit 0
# The red step of test-first work: tests written, code not yet. Only then may a second stop
# with unchanged, failing checks pass; once migrations or function code are in the change
# set, failing checks always block.
red_step_only() {
  local f
  while IFS= read -r f; do
    case "$f" in
      supabase/migrations/*) return 1 ;;
      supabase/functions/*.test.ts) ;;
      supabase/functions/*) return 1 ;;
    esac
  done <<<"$changed"
  return 0
}
if [ "$(jq -r '.stop_hook_active // false' <<<"$input")" = true ] &&
  [ "$fingerprint" = "$(cat "$state/red" 2>/dev/null)" ] && red_step_only; then
  exit 0
fi

touches() { grep -Eq "$1" <<<"$changed"; }

# shellcheck disable=SC2317,SC2329 # invoked through run(); the code differs by shellcheck version
functions_suite() {
  local d
  for d in supabase/functions/*/; do
    [ -f "$d/deno.json" ] || continue
    echo "== $d"
    (cd "$d" && deno task check && deno test --allow-env) || return 1
  done
}

# shellcheck disable=SC2317,SC2329 # invoked through run(); the code differs by shellcheck version
database_suite() {
  if ! supabase status >/dev/null 2>&1; then
    echo "The local Supabase stack is not running. Start it, then finish again:"
    echo "  supabase start -x imgproxy,logflare,vector,supavisor,storage-api,realtime,mailpit"
    return 1
  fi
  local migrations
  migrations=$(for f in supabase/migrations/*.sql; do echo "$f"; cat "$f"; done | shasum | cut -c1-40)
  if [ "$migrations" != "$(cat "$state/migrations" 2>/dev/null)" ]; then
    echo "== supabase db reset (migrations changed)"
    rm -f "$state/migrations"
    supabase db reset || return 1
    echo "$migrations" >"$state/migrations"
  fi
  echo "== db lint" && supabase db lint --level warning --fail-on warning &&
    echo "== pgTAP" && supabase test db &&
    echo "== RLS and policy test coverage" && scripts/check-rls-coverage.sh &&
    echo "== Deno DB tests" &&
    (eval "$(supabase status -o env | sed 's/^/export /')" &&
      cd supabase/tests/deno && DB_URL="$DB_URL" deno task test)
}

# shellcheck disable=SC2317,SC2329 # invoked through run(); the code differs by shellcheck version
scripts_suite() { scripts/tests/run.sh; }

failed=()
run() {
  local name=$1
  shift
  "$@" >"$state/$name.log" 2>&1 || failed+=("$name")
}
touches '^supabase/functions/' && run functions functions_suite
touches '^supabase/(migrations|tests)/|^supabase/config\.toml$|^scripts/check-rls-coverage' && run database database_suite
touches '^(scripts|\.claude|\.github)/' && run scripts scripts_suite

if [ ${#failed[@]} -eq 0 ]; then
  echo "$fingerprint" >"$state/green"
  rm -f "$state/red"
  exit 0
fi

echo "$fingerprint" >"$state/red"
{
  echo "Checks failed for your changes: ${failed[*]}."
  for name in "${failed[@]}"; do
    echo
    echo "--- $name (full log: $state/$name.log) ---"
    tail -n 40 "$state/$name.log"
  done
  echo
  echo "Fix the failures before reporting the work as done. If they are the intended red step"
  echo "(tests written, no migration or function code yet), tell the user which tests fail and"
  echo "why; finishing again without further changes is then allowed."
} >&2
exit 2
