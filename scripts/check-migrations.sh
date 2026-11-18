#!/usr/bin/env bash
# Fails when a change edits, renames or deletes a migration that exists on the base ref,
# or adds a migration that would not run last. The server-side twin of the local hook:
# hooks can be skipped, this check cannot.
# Usage: scripts/check-migrations.sh <base-ref>   (e.g. origin/main, or a commit SHA)
set -euo pipefail

base=${1:?usage: check-migrations.sh <base-ref>}
dir=supabase/migrations
mb=$(git merge-base "$base" HEAD)
errors=()

while IFS=$'\t' read -r status path; do
  [ -n "$status" ] || continue
  case "$status" in
    A)
      name=$(basename "$path")
      if [[ ! $name =~ ^[0-9]{14}_[a-z0-9_]+\.sql$ ]]; then
        errors+=("$path: name must be <14-digit timestamp>_<snake_case>.sql")
      fi
      ;;
    *) errors+=("$path: merged migrations cannot be changed ($status); add a new migration") ;;
  esac
done < <(git diff --name-status --no-renames "$mb" HEAD -- "$dir")

# A new migration must be newer than every merged one, or it would be applied out of order
# on databases that already ran them. Supabase keys migrations by the 14-digit version, so
# compare that, not the whole name: reusing the newest version is refused too. Compare with
# the tip of the base, not the merge-base: main may have gained newer migrations since.
latest=$(git ls-tree --name-only "$base" "$dir/" | sed -n 's|.*/\([0-9]\{14\}\)_[^/]*\.sql$|\1|p' |
  LC_ALL=C sort | tail -n1)
while read -r path; do
  [ -n "$path" ] || continue
  version=$(basename "$path" | cut -c1-14)
  if [ -n "$latest" ] && [[ ! $version > $latest ]]; then
    errors+=("$path: version must be later than the newest merged migration ($latest)")
  fi
done < <(git diff --name-only --diff-filter=A "$mb" HEAD -- "$dir")

if [ ${#errors[@]} -gt 0 ]; then
  printf 'Migration check failed:\n' >&2
  printf '  %s\n' "${errors[@]}" >&2
  exit 1
fi
echo "Migrations OK: merged files unchanged, new files named and ordered correctly."
