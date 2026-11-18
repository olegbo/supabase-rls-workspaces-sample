#!/usr/bin/env bash
# Fails when, in any application schema (every schema except the system ones and those
# Supabase manages, so `public`, `private` and any schema added later):
#   - a table has row level security disabled, or has it enabled but no policy (no table
#     without a policy), or a foreign table exists (it cannot have RLS)
#   - a view runs with its owner's rights (no security_invoker), or a materialized view
#     exists: both bypass RLS
#   - a policy has no pgTAP assertion proving an allowed case AND one proving a denied case
#
# An assertion proves a case when the comment directly above it carries a tag:
#   -- @policy kb_articles "admins delete articles" allow
#   select results_eq(...);
# Tables outside `public` are named with their schema: -- @policy hr.salaries "..." deny
# Tags that name no existing policy fail too, so renamed policies do not go stale.
# A deny tag on UPDATE or DELETE must not be masked by the read policy: target a row the
# caller can read, or leave out the WHERE clause (a WHERE on a column brings in the read
# policy, so a broken write policy would go unnoticed).
#
# Usage: scripts/check-rls-coverage.sh   (needs the local stack with migrations applied)
# Env:   DB_URL (default: from supabase status), TESTS_DIR (default: supabase/tests/database)
set -euo pipefail

cd "$(dirname "$0")/.."
tests_dir=${TESTS_DIR:-supabase/tests/database}
db_url=${DB_URL:-$(supabase status -o env 2>/dev/null | sed -n 's/^DB_URL="\(.*\)"$/\1/p')}
[ -n "$db_url" ] || { echo "No database: start the local stack or set DB_URL." >&2; exit 1; }

sql() { psql "$db_url" -v ON_ERROR_STOP=1 -Atq -F $'\t' -c "$1"; }

# Every schema except the system ones and those Supabase manages.
APP_SCHEMAS="n.nspname not like 'pg\\_%' and n.nspname not in ('information_schema', 'auth',
  'extensions', 'graphql', 'graphql_public', 'pgbouncer', 'realtime', '_realtime', 'storage',
  'supabase_functions', 'supabase_migrations', 'vault', 'net', 'cron', 'pgsodium',
  'pgsodium_masks', 'tests')"
errors=()

while read -r t; do
  [ -n "$t" ] && errors+=("table $t: row level security is disabled")
done < <(sql "
  select n.nspname || '.' || c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where $APP_SCHEMAS and c.relkind in ('r', 'p') and not c.relrowsecurity
  order by 1")

while read -r t; do
  [ -n "$t" ] && errors+=("table $t: row level security is on but there is no policy")
done < <(sql "
  select n.nspname || '.' || c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where $APP_SCHEMAS and c.relkind in ('r', 'p') and c.relrowsecurity
    and not exists (select 1 from pg_policy p where p.polrelid = c.oid)
  order by 1")

# Foreign tables cannot have RLS at all, yet PostgREST exposes them like tables.
while read -r t; do
  [ -n "$t" ] && errors+=("foreign table $t: cannot have RLS; keep foreign tables out of application schemas")
done < <(sql "
  select n.nspname || '.' || c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where $APP_SCHEMAS and c.relkind = 'f'
  order by 1")

while read -r v; do
  [ -n "$v" ] && errors+=("view $v: bypasses RLS (use security_invoker = true)")
done < <(sql "
  select n.nspname || '.' || c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where $APP_SCHEMAS
    and (c.relkind = 'm'
         or (c.relkind = 'v' and not exists (
               select 1 from unnest(coalesce(c.reloptions, '{}')) o
               where o in ('security_invoker=true', 'security_invoker=on', 'security_invoker=1'))))
  order by 1")

# Tags: "ok<TAB>table<TAB>policy<TAB>allow|deny", or "err<TAB>message" for malformed ones.
tags=$(perl -e '
  my %seen;
  my $assert = qr/^\s*select\s+(ok|is|isnt|results_eq|results_ne|set_eq|bag_eq|row_eq|is_empty|isnt_empty|throws_ok|throws_like|lives_ok|cmp_ok|matches)\s*\(/i;
  for my $f (@ARGV) {
    open my $fh, "<", $f or die "$f: $!";
    my @l = <$fh>;
    for my $i (0 .. $#l) {
      next unless $l[$i] =~ /^\s*--\s*\@policy\b/;
      if ($l[$i] !~ /^\s*--\s*\@policy\s+([a-z_][a-z0-9_]*(?:\.[a-z_][a-z0-9_]*)?)\s+"([^"]+)"\s+(allow|deny)\s*$/) {
        printf "err\t%s:%d: malformed tag, expected: -- \@policy <table> \"<policy>\" allow|deny\n", $f, $i + 1;
        next;
      }
      my ($t, $p, $k) = ($1, $2, $3);
      my $j = $i + 1;
      $j++ while $j <= $#l && $l[$j] =~ /^\s*(--\s*\@policy\b.*)?$/;
      if ($j <= $#l && $l[$j] =~ $assert) {
        # One assertion cannot prove both the allowed and the denied case of a policy.
        my $other = $k eq "allow" ? "deny" : "allow";
        if ($seen{"$f:$j\t$t\t$p\t$other"}) {
          printf "err\t%s:%d: one assertion is tagged both allow and deny for \"%s\"\n", $f, $j + 1, $p;
        }
        $seen{"$f:$j\t$t\t$p\t$k"} = 1;
        print "ok\t$t\t$p\t$k\n";
      }
      else { printf "err\t%s:%d: tag is not directly above a pgTAP assertion\n", $f, $i + 1 }
    }
  }' "$tests_dir"/*.sql)

while IFS=$'\t' read -r kind msg; do
  [ "$kind" = err ] && errors+=("$msg")
done <<<"$tags"

required=$(sql "
  select case when p.schemaname = 'public' then p.tablename else p.schemaname || '.' || p.tablename end
         || E'\t' || p.policyname || E'\t' || k
  from pg_policies p join pg_namespace n on n.nspname = p.schemaname, unnest(array['allow', 'deny']) k
  where $APP_SCHEMAS" | LC_ALL=C sort -u)
have=$(grep '^ok' <<<"$tags" | cut -f2- | LC_ALL=C sort -u || true)

while IFS=$'\t' read -r t p k; do
  [ -n "$t" ] && errors+=("policy $t \"$p\": no tagged pgTAP test for the $k case")
done < <(LC_ALL=C comm -23 <(echo "$required") <(echo "$have"))

while IFS=$'\t' read -r t p k; do
  [ -n "$t" ] && errors+=("tag $t \"$p\" $k: no such policy")
done < <(LC_ALL=C comm -13 <(echo "$required") <(echo "$have"))

if [ ${#errors[@]} -gt 0 ]; then
  echo "RLS coverage check failed:" >&2
  printf '  %s\n' "${errors[@]}" >&2
  exit 1
fi
policies=$(grep -c . <<<"$required" || true)
echo "RLS coverage OK: every table in the application schemas has RLS and a policy; $((policies / 2)) policies, each with tagged allow and deny tests."
