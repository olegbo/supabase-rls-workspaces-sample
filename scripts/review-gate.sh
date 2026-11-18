#!/usr/bin/env bash
# Turns the structured result of the Claude PR review into a pass/fail check.
# Input: the review JSON ({"complete": true, "summary": "...", "findings": [{"severity", "title",
# "file", "line", "detail"}]}) in $REVIEW_JSON. Fails when any open finding is high severity, and
# fails closed when there is no parsable verdict or the reviewer reports the review incomplete.
# Writes a findings table to $GITHUB_STEP_SUMMARY when it is set.
set -euo pipefail

json=${REVIEW_JSON:-}
summary_file=${GITHUB_STEP_SUMMARY:-/dev/null}

if [ -z "$json" ] || ! jq -e '(.summary | type == "string") and (.findings | type == "array")' \
  <<<"$json" >/dev/null 2>&1; then
  echo "The review produced no parsable verdict, so the check fails. Re-run the job." >&2
  echo "### Claude review: no verdict" >>"$summary_file"
  exit 1
fi

if ! jq -e '.complete == true' <<<"$json" >/dev/null; then
  echo "The reviewer reports the review as incomplete, so the check fails:" >&2
  jq -r .summary <<<"$json" >&2
  { echo "### Claude review: incomplete"; echo; jq -r .summary <<<"$json"; } >>"$summary_file"
  exit 1
fi

high=$(jq '[.findings[] | select(.severity == "high")] | length' <<<"$json")
total=$(jq '.findings | length' <<<"$json")

{
  echo "### Claude review: $total finding(s), $high high"
  echo
  jq -r '.summary' <<<"$json"
  echo
  if [ "$total" -gt 0 ]; then
    echo '| Severity | Finding | Location |'
    echo '|---|---|---|'
    jq -r '.findings | sort_by({"high": 0, "medium": 1, "low": 2}[.severity]) | .[] |
      "| \(.severity) | \(.title | gsub("\\|"; "\\|")) | `\(.file)\(if .line then ":\(.line)" else "" end)` |"' <<<"$json"
  fi
} >>"$summary_file"

jq -r '.findings[] | "\(.severity)\t\(.file)\(if .line then ":\(.line)" else "" end)\t\(.title)"' <<<"$json"

if [ "$high" -gt 0 ]; then
  echo "$high high-severity finding(s): fix them, or answer the review thread and re-run." >&2
  exit 1
fi
echo "No high-severity findings."
