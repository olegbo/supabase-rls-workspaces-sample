# shellcheck shell=bash
# Minimal assertion helpers for the shell test files. Sourced, not executed.

passed=0
failed=0

ok() {
  passed=$((passed + 1))
  printf '  ok    %s\n' "$1"
}

not_ok() {
  failed=$((failed + 1))
  printf '  FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
  return 0
}

# assert_eq <expected> <actual> <description>
assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else not_ok "$3" "expected: $1
actual:   $2"; fi
}

# assert_contains <haystack> <needle> <description>
assert_contains() {
  if [[ $1 == *"$2"* ]]; then ok "$3"; else not_ok "$3" "missing: $2
in: $1"; fi
}

finish() {
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$passed" "$failed"
  [ "$failed" -eq 0 ]
}

# A throwaway repository with an origin whose main holds one merged migration.
make_repo() {
  local dir remote
  dir=$(mktemp -d)
  remote=$(mktemp -d)
  git init -q --bare -b main "$remote"
  git init -q -b main "$dir"
  (
    cd "$dir" || exit 1
    git config user.email test@example.test
    git config user.name test
    git config commit.gpgsign false
    mkdir -p supabase/migrations
    echo 'create table public.t (id int);' >supabase/migrations/20260101000000_init.sql
    git add . && git commit -qm init
    git remote add origin "$remote"
    git push -q origin main
  )
  (cd "$dir" && pwd -P)
}
