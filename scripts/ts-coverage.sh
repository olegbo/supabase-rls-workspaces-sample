#!/usr/bin/env bash
# Runs every Edge Function test (unit, adapters against the stack, end to end) with
# coverage and fails on any uncovered line or branch. Needs a running local stack and
# `supabase functions serve` for the end-to-end test.
set -euo pipefail

cd "$(dirname "$0")/.."
eval "$(supabase status -o env 2>/dev/null | sed 's/^/export /')"
cov="$(mktemp -d)"
trap 'rm -rf "$cov"' EXIT

cd supabase/functions/invite-member
SUPABASE_URL="$API_URL" SUPABASE_ANON_KEY="$ANON_KEY" \
SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" JWT_SECRET="$JWT_SECRET" \
  deno test --allow-env --allow-net=127.0.0.1 --coverage="$cov"

deno coverage "$cov"
lcov=$(deno coverage "$cov" --lcov)

# A module no test imports is absent from the report rather than at 0%, so require every
# source file explicitly. index.ts only wires config to Deno.serve; the end-to-end test
# exercises it inside the edge runtime, where coverage cannot be collected.
for src in *.ts; do
  case "$src" in *.test.ts | index.ts) continue ;; esac
  grep -q "^SF:.*/invite-member/$src$" <<< "$lcov" || { echo "Not covered at all: $src" >&2; exit 1; }
done

uncovered=$(awk -F'[:,]' '
  /^SF:/ { file = $2; sub(".*/invite-member/", "", file) }
  /^DA:/ && $3 == "0" { print file ":" $2 " line" }
  /^BRDA:/ && ($5 == "0" || $5 == "-") { print file ":" $2 " branch" }' <<< "$lcov")
if [ -n "$uncovered" ]; then
  echo "Uncovered:" >&2
  echo "$uncovered" >&2
  exit 1
fi
