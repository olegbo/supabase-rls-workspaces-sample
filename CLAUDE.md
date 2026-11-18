# CLAUDE.md

`CONSTITUTION.md` holds the invariants of this repository and overrides this file. This file
says how to work within them.

Multi-tenant knowledge base on Supabase. Workspaces have members with roles
`member < admin < owner`; articles belong to a workspace. **Security lives in the database**:
RLS policies, column grants, triggers and `security definer` RPCs. The Edge Function
`invite-member` holds no privileges and runs with the caller's JWT. `README.md` explains
every design decision and lists the pitfalls already hit; read it before changing SQL.

## Stack

- Postgres 17 on Supabase (CLI 3.x, local stack in Docker). Schema in `supabase/migrations/`.
- Edge Function in Deno 2 + TypeScript, zod for input, `@supabase/supabase-js`.
- Tests: pgTAP (`supabase/tests/database/`), Deno (`supabase/tests/deno/`, function `*.test.ts`),
  shell tests for tooling (`scripts/tests/`).
- CI: GitHub Actions (`ci`, `claude-review`; `claude` answers `@claude` mentions). Deploys happen
  only from CI.

## Commands

```bash
# Local stack (Studio is needed only for the Supabase MCP server)
supabase start -x imgproxy,logflare,vector,supavisor,storage-api,realtime,mailpit
supabase db reset                          # re-apply all migrations after adding one

# Database
supabase test db                           # pgTAP
supabase db lint --level warning --fail-on warning && supabase db advisors
scripts/check-rls-coverage.sh              # RLS on every table, allow+deny test per policy
eval "$(supabase status -o env | sed 's/^/export /')"
(cd supabase/tests/deno && DB_URL=$DB_URL deno task test)
scripts/plpgsql-coverage.sh 100            # PL/pgSQL statement and branch coverage

# Edge Function
(cd supabase/functions/invite-member && deno task check && deno test --allow-env)
supabase functions serve --env-file supabase/functions/.env.example &   # then:
scripts/ts-coverage.sh                     # all function tests, 100% coverage gate

# Tooling (hooks, guard scripts, config)
scripts/tests/run.sh
scripts/check-migrations.sh origin/main
```

## Rules

These are requirements, not preferences. Each one is enforced, so breaking it fails loudly.

| Rule | Enforced by |
|---|---|
| Every table in an application schema has RLS and a policy; views use `security_invoker` | `scripts/check-rls-coverage.sh` in CI; pgTAP schema test |
| Every policy has a pgTAP test for an allowed **and** a denied case | `scripts/check-rls-coverage.sh` in CI and in the Stop hook |
| Deploys only through CI: no `supabase db push`, `functions deploy`, `secrets set`, no `--linked` | `guard-bash.sh` hook, `permissions.deny` |
| Merged migrations are never edited, renamed or deleted | `guard-files.sh` / `guard-bash.sh` hooks; `scripts/check-migrations.sh` in CI |
| No secrets in the repo or its history; `.env` files are never read | `guard-*.sh` hooks, `.gitignore`, gitleaks over full history in CI |
| No force pushes, no pushes to `main`; `main` changes only by reviewed PR | `guard-bash.sh` hook; branch protection |
| Work is checked before it is called done | `verify-before-stop.sh` Stop hook |

## How we work: plan → tests → code → review → PR

1. **Plan.** `/plan <feature>` runs the `planner` then `architect` subagents and saves
   `docs/plans/<date>-<slug>.md`. Wait for the user to approve it.
2. **Tests first.** Write the pgTAP (and Deno) tests from the plan. Run them and confirm they
   fail for the right reason. Commit `test: ...` and push: CI goes red. That is expected.
3. **Code.** New migration (`supabase migration new <name>`), then function code if any.
   `supabase db reset`, run the suites until green. Commit `feat: ...`, push: CI goes green.
4. **Review.** `/review` runs the `database-reviewer` and `security-reviewer` subagents
   locally. Fix what they find before opening the PR.
5. **PR.** Open it with `gh pr create`. The `claude-review` check posts inline comments and
   fails on any high finding. Answer every thread: fix it in a new commit, or reply with why
   it does not apply. A human approves and merges with a merge commit. No squashing, no
   force pushes: the history shows the process.

Keep commits small and in that order. One review fix per commit.

## Conventions

**SQL**
- New table: `revoke all on <t> from anon, authenticated`, then `enable row level security`,
  then per-command policies `to authenticated`, then per-column grants. Clients never set
  ids, `workspace_id` on update, `created_by`, or timestamps.
- Policies call `private.workspace_ids_with_role('<role>')` as
  `workspace_id = any (array(select private.workspace_ids_with_role('member')))`.
  Not `in (select ...)`: it loses the index when two predicates are OR-ed.
- UPDATE policies have both `using` and `with check`.
- Functions: `set search_path = ''`, schema-qualified names, `revoke all on function ... from public`.
  With an empty `search_path`, `citext` comparisons are case-sensitive: use `lower()`.
- Every FK and every column a policy filters on gets an index.
- Errors raised for clients use PostgREST codes (`PT400`, `PT403`, `PT409`, `PT429`).

**pgTAP**
- One file per area, wrapped in `begin; ... rollback;`, with `select plan(n)` kept exact.
- Tag the assertion that proves a policy case on the line directly above it:
  ```sql
  -- @policy kb_articles "admins delete articles" deny
  select results_eq(...);
  ```
- A tagged INSERT denial asserts the message too:
  `throws_ok(..., '42501', 'new row violates row-level security policy for table "<t>"', ...)`.
  A bare `42501` is also what a missing column grant raises, so it proves nothing about the policy.
- A tagged UPDATE/DELETE denial must not be masked by the read policy: target a row the
  caller can read, or leave out the WHERE clause. A WHERE on a column brings in the read
  policy, so a row the caller cannot see proves nothing about the write policy.
- Denied UPDATE/DELETE do not raise under RLS: assert the affected-row count
  (`with r as (... returning 1) select count(*)::int from r`) and pair it with an allowed
  control case.
- Test bounds exactly at and one past each limit.

**TypeScript**
- `deno fmt` (single quotes, width 100) and `deno lint` clean. I/O behind small interfaces
  so the handler is unit-testable. Validate all input with zod. Never log emails or tokens.

## Guard rails (hooks)

`.claude/settings.json` wires these. When one blocks you, it says why. Do not work around
it; change approach or ask the user.

- `guard-bash.sh`: blocks deploys and remote-project commands (including `psql` to a host
  other than the local stack), force pushes, pushes to `main`, commands touching `.env`
  files, and commands that modify merged migrations. It also blocks what is a person's
  decision: `gh pr merge`, approving, secrets, repository settings, and GitHub API writes
  other than replies on review threads.
- `guard-files.sh`: blocks reading or writing `.env` files and editing merged migrations.
- Both refuse changes to the guard rails themselves (`.claude/settings*.json`,
  `.claude/hooks/`, and the user-level `~/.claude/settings*.json`, which can switch the hooks
  off too): a person changes those, outside the agent.
- `lint-file.sh`: after every edit, lints the file (deno fmt/lint, shellcheck, JSON).
  Fix what it reports straight away.
- `verify-before-stop.sh`: before you finish, runs the suites your changes affect. The
  database suite needs the local stack running. In the red step of test-first work (tests
  only, no migration or function code yet), report the expected failures to the user;
  finishing again is then allowed. With code in the change set, failing checks always block.

## MCP

`.mcp.json` defines two servers; neither holds a secret.
- `supabase`: the local stack only, read-only (`supabase_read_only_user`). Needs Studio
  running. Use it to inspect schema, policies and advisors, never to change anything.
  Schema changes go through migrations.
- `github`: read-only (`X-MCP-Readonly`), needs `GITHUB_PAT` in the environment
  (`export GITHUB_PAT=$(gh auth token)`). Write actions (opening PRs, replying to review
  threads) go through `gh`, where the Bash hooks see them.
