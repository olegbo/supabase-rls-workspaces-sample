## What and why

<!-- One paragraph. Link the approved plan: docs/plans/<date>-<slug>.md -->

## Requirements

<!-- The spec, issue or acceptance criteria this PR implements, and which of them it covers.
     Or "none" with a reason (refactoring, tooling). -->

## Test output

<!-- "Done" only with test output. Paste the summary lines or link the CI run. -->

- pgTAP:
- RLS and policy coverage (`scripts/check-rls-coverage.sh`):
- Other suites touched:

## Checklist

- [ ] A plan was approved before code (`docs/plans/`), or this PR needs none (docs, fix)
- [ ] Tests came first: the `test:` commit was red before the `feat:` commit
- [ ] New tables have RLS and policies; every policy has tagged allow and deny tests
- [ ] No merged migration changed; no secrets; no deploy outside CI
- [ ] Every review thread is answered: fixed in a commit or replied to with a reason
