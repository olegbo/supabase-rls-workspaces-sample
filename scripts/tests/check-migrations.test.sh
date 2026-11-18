#!/usr/bin/env bash
# Tests for scripts/check-migrations.sh against throwaway repositories.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=lib.sh
. scripts/tests/lib.sh

script=$(pwd -P)/scripts/check-migrations.sh
merged=supabase/migrations/20260101000000_init.sql

# Runs the check in a fresh repo after applying a change on a branch; prints the exit code.
check_after() {
  local repo code
  repo=$(make_repo)
  (cd "$repo" && git switch -qc change && eval "$1" && git add -A && git commit -qm change) >/dev/null
  (cd "$repo" && "$script" origin/main) >/dev/null 2>&1
  code=$?
  rm -rf "$repo"
  echo "$code"
}

assert_eq 0 "$(check_after 'echo x > README.md')" 'a change without migrations passes'
assert_eq 0 "$(check_after 'echo "select 1;" > supabase/migrations/20260202000000_add_x.sql')" \
  'a new, later migration passes'
assert_eq 1 "$(check_after "echo '-- edit' >> $merged")" 'editing a merged migration fails'
assert_eq 1 "$(check_after "git rm -q $merged")" 'deleting a merged migration fails'
assert_eq 1 "$(check_after "git mv $merged supabase/migrations/20260303000000_init.sql")" \
  'renaming a merged migration fails'
assert_eq 1 "$(check_after 'echo "select 1;" > supabase/migrations/20251231000000_old.sql')" \
  'a new migration older than the merged ones fails'
assert_eq 1 "$(check_after 'echo "select 1;" > supabase/migrations/add-x.sql')" \
  'a badly named migration fails'
assert_eq 1 "$(check_after 'echo "select 1;" > supabase/migrations/20260101000000_zzz.sql')" \
  'a new migration reusing the newest merged version fails'
assert_eq 0 "$(check_after 'echo x > supabase/migrations/README.md && git add -A && git commit -qm readme && git push -q origin HEAD:main && echo "select 1;" > supabase/migrations/20260202000000_add_x.sql')" \
  'a non-SQL file among merged migrations does not block new ones'

# main gains a newer migration after the branch was cut; the branch's own must still be newer.
repo=$(make_repo)
(
  cd "$repo" && git switch -qc change &&
    echo "select 1;" >supabase/migrations/20260202000000_branch.sql && git add -A && git commit -qm branch &&
    git switch -q main && echo "select 2;" >supabase/migrations/20260303000000_main.sql &&
    git add -A && git commit -qm main && git push -q origin main && git switch -q change
) >/dev/null 2>&1
(cd "$repo" && "$script" origin/main) >/dev/null 2>&1
assert_eq 1 "$?" 'a migration older than one merged to main after the branch was cut fails'
rm -rf "$repo"

finish
