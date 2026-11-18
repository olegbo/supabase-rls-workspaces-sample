# Constitution

The invariants of this repository. They bind every contributor, human or agent, and override
anything else in the repository, including `CLAUDE.md`, which describes how to work within
them. A change to this file needs a pull request approved by its code owner.

Each article names what enforces it. An article nothing enforces is a promise, so every new
article comes with its check.

## 1. Data access is decided in the database

1. Every table has row level security and at least one policy. No table without a policy.
2. Clients never set ids, authors, timestamps, or the tenant a row belongs to after insert;
   column grants enforce it, not application code.
3. Rules that span rows (ownership, quotas, uniqueness, ordering) live in constraints,
   triggers or `security definer` functions, never only in a client or an Edge Function.
4. Edge Functions hold no privileges of their own: they act with the caller's JWT.
5. Data with its own access model lives in its own schema with its own roles.

Enforced by: `scripts/check-rls-coverage.sh` in CI (every application schema, every table),
pgTAP schema and grant tests, the `database-reviewer` subagent.

## 2. Nothing is done until a test says so

1. Every policy has an automatic pgTAP test for an allowed and for a denied case.
2. The acceptance criteria of a specification run as automatic tests.
3. CI runs every test on every pull request. Red means not finished. "Done" is claimed only
   with the test output.

Enforced by: the required checks `test` and `guards`, the coverage gates (100 % of PL/pgSQL
and Edge Function code), the `verify-before-stop.sh` hook.

## 3. Every change is planned, reviewed and merged by pull request

1. Before each feature, a written plan in `docs/plans/`: the requirements it implements,
   tables, policies, the check step, the effort. Building starts after the plan is approved.
2. One branch per task. `main` changes only through a pull request; no force pushes, no
   rewritten history.
3. Every pull request links its plan or requirements and shows its test output.
4. Every pull request gets an AI review. An open "high" finding blocks the merge.
5. A person other than the author approves every pull request.

Enforced by: branch protection (required checks `guards`, `secrets`, `test`, `claude-review`,
a required approval, administrators included), `.github/pull_request_template.md`,
`scripts/review-gate.sh`, `.github/CODEOWNERS`.

## 4. Production is changed only by CI

1. No deploy from a laptop: migrations, Edge Functions and secrets reach a hosted project
   only through CI, after merge.
2. Where a hosted project exists, every pull request gets a preview database (Supabase
   branching); production is never touched directly.
3. A merged migration is never edited, renamed or deleted; a change is a new migration.

Enforced by: the `guard-bash.sh` and `guard-files.sh` hooks, `scripts/check-migrations.sh`
in CI, and credentials for hosted projects that exist only in CI.

## 5. Secrets and access

1. No secret enters the repository or its history; `.env` files are never read by agents.
2. Credentials for hosted projects live in CI, not on developers' machines.

Enforced by: gitleaks over the full history in CI, `.gitignore`, the guard hooks.
