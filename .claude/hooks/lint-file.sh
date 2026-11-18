#!/usr/bin/env bash
# PostToolUse(Edit|Write|MultiEdit). Lints the file Claude just changed and feeds problems
# back (exit 2), so they are fixed in the same step instead of surfacing in CI.
#   *.ts            deno fmt --check + deno lint, with the nearest deno.json
#   *.sh            shellcheck
#   *.pl            not linted: perl -c runs BEGIN blocks, which would execute the file
#   *.json          jq (syntax)
# SQL needs a database to be checked; the Stop hook applies migrations and runs pgTAP.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

input=$(cat)
path=$(jq -r '.tool_input.file_path // ""' <<<"$input")
root=$(project_dir)
[ -f "$path" ] || exit 0
rel=$(relative_to_project "$root" "$path") || exit 0
file="$root/$rel"

fail() {
  printf 'Lint failed for %s:\n%s\n' "$rel" "$1" >&2
  exit 2
}

# Directory holding the nearest deno.json, up to the project root.
deno_dir() {
  local d
  d=$(dirname "$file")
  while [ "$d" != "$root" ] && [ "$d" != / ]; do
    [ -f "$d/deno.json" ] && { echo "$d"; return; }
    d=$(dirname "$d")
  done
  echo "$root"
}

case "$rel" in
  *.ts | *.tsx)
    dir=$(deno_dir)
    out=$(cd "$dir" && deno fmt --check "$file" 2>&1) || fail "$out
Run: (cd ${dir#"$root"/} && deno fmt ${file#"$dir"/})"
    out=$(cd "$dir" && deno lint "$file" 2>&1) || fail "$out"
    ;;
  *.sh)
    out=$(shellcheck -x -P "$(dirname "$file")" "$file" 2>&1) || fail "$out"
    ;;
  *.json)
    out=$(jq empty "$file" 2>&1) || fail "$out"
    ;;
esac
exit 0
