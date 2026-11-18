---
description: Review the current branch against origin/main with the database and security reviewers
argument-hint: "[focus or file]"
---

Review the changes on this branch. Extra focus, if any: $ARGUMENTS

1. Run `git fetch origin main -q` and `git diff --stat origin/main...HEAD`. If there are
   uncommitted changes, include them and say so.
2. In parallel, run the **database-reviewer** subagent (when `supabase/` changed) and the
   **security-reviewer** subagent (always) on the same diff.
3. Verify each finding yourself before reporting it: open the code, follow the failure
   scenario. Drop findings that do not hold up and say how many you dropped.
4. Report the verified findings ranked high → medium → low, each with `file:line`, the
   failure scenario, and the suggested fix. End with one line: ready for PR, or not.

Do not fix anything unless the user asks. The same reviewers run in CI on the PR, where a
high finding fails the `claude-review` check.
