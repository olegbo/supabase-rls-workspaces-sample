#!/usr/bin/env bash
# Proves scripts/check-rls-coverage.sh fails for each problem it claims to catch.
# Needs the local stack: it briefly creates probe objects in public and drops them.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=lib.sh
. scripts/tests/lib.sh

DB_URL=${DB_URL:-$(supabase status -o env 2>/dev/null | sed -n 's/^DB_URL="\(.*\)"$/\1/p')}
export DB_URL
sql() { psql "$DB_URL" -v ON_ERROR_STOP=1 -q -c "$1" >/dev/null; }

tests=$(mktemp -d)
cleanup() {
  rm -rf "$tests"
  sql 'drop view if exists public.rls_probe_view; drop table if exists public.rls_probe;
       drop foreign table if exists public.rls_probe_ft; drop server if exists rls_probe_srv;
       drop schema if exists rls_probe_extra cascade;'
}
trap cleanup EXIT

reset_tests() { rm -f "$tests"/*.sql && cp supabase/tests/database/*.sql "$tests/"; }

# Prints the exit code; the output goes to $tests/out.
check() {
  TESTS_DIR=$tests scripts/check-rls-coverage.sh >"$tests/out" 2>&1
  echo $?
}

reset_tests
assert_eq 0 "$(check)" 'the real test suite passes'

perl -0pi -e 's/-- \@policy kb_articles "admins delete articles" deny\n//' "$tests"/03_*.sql
assert_eq 1 "$(check)" 'a policy without a deny test fails'
assert_contains "$(cat "$tests/out")" 'kb_articles "admins delete articles": no tagged pgTAP test for the deny case' \
  'the missing case is named'

reset_tests
printf -- '-- @policy kb_articles "no such policy" allow\nselect ok(true);\n' >"$tests/99_x.test.sql"
assert_eq 1 "$(check)" 'a tag naming no policy fails'

reset_tests
printf -- '-- @policy kb_articles admins delete articles allow\nselect ok(true);\n' >"$tests/99_x.test.sql"
assert_eq 1 "$(check)" 'a malformed tag fails'

reset_tests
printf -- '-- @policy kb_articles "admins delete articles" allow\nselect set_config(%s);\n' "'a', 'b', true" \
  >"$tests/99_x.test.sql"
assert_eq 1 "$(check)" 'a tag that is not above an assertion fails'

reset_tests
printf -- '-- @policy kb_articles "admins delete articles" allow\n-- @policy kb_articles "admins delete articles" deny\nselect ok(true);\n' \
  >"$tests/99_x.test.sql"
assert_eq 1 "$(check)" 'one assertion tagged both allow and deny fails'

reset_tests
sql 'create table public.rls_probe (id int)'
assert_eq 1 "$(check)" 'a table without RLS fails'
assert_contains "$(cat "$tests/out")" 'table public.rls_probe: row level security is disabled' \
  'the table is named'
sql 'alter table public.rls_probe enable row level security'
assert_eq 1 "$(check)" 'a table with RLS but no policy fails (no table without a policy)'
assert_contains "$(cat "$tests/out")" 'table public.rls_probe: row level security is on but there is no policy' \
  'the policy-less table is named'
sql 'drop table public.rls_probe'

sql 'create schema rls_probe_extra; create table rls_probe_extra.runs (id int)'
assert_eq 1 "$(check)" 'a table without RLS in another application schema fails'
assert_contains "$(cat "$tests/out")" 'table rls_probe_extra.runs: row level security is disabled' \
  'tables outside public are named with their schema'
sql 'drop schema rls_probe_extra cascade'

sql 'create view public.rls_probe_view as select 1 as x'
assert_eq 1 "$(check)" 'a view running with owner rights fails'
sql 'alter view public.rls_probe_view set (security_invoker = true)'
assert_eq 0 "$(check)" 'a security_invoker view passes'

sql 'create extension if not exists postgres_fdw with schema extensions;
     create server rls_probe_srv foreign data wrapper postgres_fdw;
     create foreign table public.rls_probe_ft (id int) server rls_probe_srv'
assert_eq 1 "$(check)" 'a foreign table in public fails'
sql 'drop foreign table public.rls_probe_ft'

finish
