#!/usr/bin/env bash
# Statement and branch coverage of every PL/pgSQL function in public/private, measured
# with the plpgsql_check profiler while the pgTAP and Deno database suites run.
# Usage: scripts/plpgsql-coverage.sh [min_percent]   (needs a running local stack)
set -euo pipefail

cd "$(dirname "$0")/.."
min="${1:-100}"
eval "$(supabase status -o env | sed 's/^/export /')"

psql() { PGOPTIONS='-c client_min_messages=warning' command psql "$DB_URL" -v ON_ERROR_STOP=1 -Atq "$@"; }
quiet() { local out; out=$("$@" 2>&1) || { echo "$out" >&2; return 1; }; }

# Profiles live in shared memory (plpgsql_check is preloaded), so they collect data from
# every session that has the profiler on, including the ones pg_prove opens.
psql -c 'create extension if not exists plpgsql_check with schema extensions' \
     -c 'select extensions.plpgsql_profiler_reset_all()' \
     -c 'alter role postgres set plpgsql_check.profiler = on'
trap "psql -c 'alter role postgres reset plpgsql_check.profiler'" EXIT

quiet supabase test db
(cd supabase/tests/deno && DB_URL="$DB_URL" quiet deno task test)

report=$(psql -F $'\t' -c "
  select p.oid::regprocedure,
         round((100 * coalesce(extensions.plpgsql_coverage_statements(p.oid), 0))::numeric, 1),
         round((100 * coalesce(extensions.plpgsql_coverage_branches(p.oid), 1))::numeric, 1)
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join pg_language l on l.oid = p.prolang
  where n.nspname in ('public', 'private') and l.lanname = 'plpgsql'
  order by 1")

printf '%-50s %10s %9s\n' function statements branches
failed=0
while IFS=$'\t' read -r fn stmts branches; do
  printf '%-50s %9s%% %8s%%\n' "$fn" "$stmts" "$branches"
  if awk -v s="$stmts" -v b="$branches" -v m="$min" 'BEGIN { exit !(s < m || b < m) }'; then
    failed=1
  fi
done <<< "$report"

if [ "$failed" = 1 ]; then
  echo "coverage below ${min}%" >&2
  exit 1
fi
