# Workspace KB: Supabase sample

An anonymised excerpt from a multi-tenant knowledge-base SaaS we built and run in production. The original runs on plain Postgres with RLS. This sample ports the same tenant model to Supabase: `auth.uid()`, policies, an Edge Function, and tests at every layer.

Contents:

| What | Where |
|---|---|
| Migration: workspaces, roles, invites, account deletion | `supabase/migrations/20261110120000_workspaces_rbac.sql` |
| Migration: workspace-scoped articles | `supabase/migrations/20261110120100_kb_articles.sql` |
| Migration: comments on articles | `supabase/migrations/20261117120000_kb_article_comments.sql` |
| Edge Function: `invite-member` | `supabase/functions/invite-member/` |
| Database tests (pgTAP, 187 assertions incl. a plan regression test and edge cases) | `supabase/tests/database/` |
| Concurrency and auth-config tests (Deno, 6) | `supabase/tests/deno/` |
| Function tests (36): handler, config, adapters against the live stack, end to end | `supabase/functions/invite-member/*.test.ts` |
| Coverage gates | `scripts/plpgsql-coverage.sh`, `scripts/ts-coverage.sh` |
| CI | `.github/workflows/ci.yml` |
| Rules, hooks, subagents, MCP and Claude in CI, and where to look | [AI-assisted development](#ai-assisted-development) |

## Data model and roles

```
auth.users ──< workspace_members >── workspaces ──< kb_articles ──< kb_article_comments
                  role: member | admin | owner        └─< workspace_invites
```

The hierarchy is strict: you manage only roles below your own.

| Action | member | admin | owner |
|---|:-:|:-:|:-:|
| Read the workspace and its members | ✓ | ✓ | ✓ |
| Read published articles and own drafts, write own articles | ✓ | ✓ | ✓ |
| Read and write comments on articles you can read, edit or delete own comments | ✓ | ✓ | ✓ |
| Read all drafts, edit or delete any article | | ✓ | ✓ |
| Delete any comment (moderation; nobody edits another person's comment) | | ✓ | ✓ |
| Rename the workspace | | ✓ | ✓ |
| Invite members, revoke invites, remove members | | ✓ | ✓ |
| Invite admins, change roles, remove admins and owners | | | ✓ |
| Transfer ownership, delete the workspace | | | ✓ |
| Leave the workspace | ✓ | ✓ | ✓, unless last owner |

## Design decisions

- **Explicit grants.** The migrations revoke whatever the platform's default privileges hand out and grant per column. Hosted defaults include `TRUNCATE`, and `TRUNCATE` ignores RLS. `anon` ends up with no table or column privileges. `slug`, `workspace_id`, `created_by`, `invited_by` and `expires_at` can't be set or changed by clients.
- **Policy helpers in a private schema.** `private.workspace_ids_with_role(min_role)` is `SECURITY DEFINER` with an empty `search_path` and lives outside the exposed API schemas. Policies call it as `workspace_id = any (array(select ...))`, so it runs once per statement. That form also lets the planner use the `workspace_id` index. The more common `workspace_id in (select ...)` does not when two such predicates are OR-ed: an unfiltered article list on 600k rows took 57–73 ms with a sequential scan, and takes 0.44 ms with the array form. `04_policy_plans.test.sql` fails if a sequential scan comes back.
- **Multi-row invariants live in the database.**
  - `create_workspace()` inserts the workspace and its owner membership in one transaction.
  - A trigger refuses to remove or demote the last owner. It locks the workspace row (`FOR NO KEY UPDATE`, so inserts into child tables aren't blocked), and it refuses `REPEATABLE READ`, where its check would read a stale snapshot. A two-session test proves that two owners stepping down at the same time leave exactly one owner.
  - Deleting an account (dashboard, admin API, GDPR request) hands each workspace the user solely owns to the longest-standing admin, or to a member if there is no admin. A workspace with no one else in it is deleted.
- **Invites.**
  - Only a SHA-256 of the token is stored. `token_hash` can be written by clients but not read back.
  - `accept_workspace_invite()` requires a confirmed, non-anonymous email that matches the invite. The token works once and expires after 7 days.
  - The inviter must still hold a role above the invited one when the invite is accepted. An admin removed after inviting can't leave a working invite behind.
  - Every failure returns the same error, so the endpoint can't be used to probe for tokens.
  - An expired invite no longer blocks re-inviting the same address.
- **Comments.**
  - A comment is visible exactly when its article is: the policy checks `exists (select 1 from kb_articles ...)`, which runs under the reader's own `kb_articles` RLS, so the article rule is reused, not copied. Unpublishing an article hides its comments, the author's included.
  - A composite foreign key `(article_id, workspace_id)` to `kb_articles (id, workspace_id)` makes a comment's workspace equal its article's for every writer, the service role included. The stored `workspace_id` lets the policies use the index.
  - Comments go with their article and workspace; they stay, without an author, when the account is deleted.
  - Authors edit and delete their own comments only while they can read the article, so unpublishing an article freezes its comments for their authors. Admins can still delete them. Both policies check the article themselves: a statement with no `WHERE` does not bring in the read policy.
  - Bodies are plain text, 1 to 4000 characters, not only whitespace. Clients must render them as text, never as HTML.
- **Quotas.** Each user can send 20 invites per hour, each workspace can have 100 pending invites, each user can create 10 workspaces, and each user can post 100 comments per hour across all workspaces. Signup and email rates use Supabase's `[auth.rate_limit]`.
- **Auth config is part of the security model.** Invites trust `email_confirmed_at`, which means nothing if Supabase confirms every signup on its own. `enable_confirmations = true` is committed, and a test fails if it is turned off. Anonymous sign-ins are off, and passwords need 8 characters.
- **The Edge Function holds no privileges.** `invite-member` runs with the caller's JWT, never the service role, so RLS decides whether the caller may invite.
  - It authenticates before reading the body.
  - It accepts only tokens of signed-in users, so API keys and forged tokens get a 401.
  - It validates input with zod.
  - It maps database errors to 400, 403, 409 and 429, plus a generic 500 that hides the details.
  - Its logs record the workspace and the email domain, never the address.
  - A missing `APP_URL` or `INVITE_FROM_EMAIL` stops the function at boot instead of falling back to dev values.
  - I/O goes through small interfaces, so the handler is unit-tested without a running stack.
- **Error codes.** RPCs raise PostgREST's `PTxxx` codes, so clients get real HTTP statuses: `PT400` invalid invite, `PT401` not signed in, `PT403` email not confirmed, `PT409` last owner, `PT429` quota.

## Coverage

CI fails below 100%, and both gates have been checked to fail when a test is removed.

| Layer | Measured with | Statements / lines | Branches |
|---|---|---|---|
| PL/pgSQL functions and triggers (7) | `plpgsql_check` profiler while pgTAP and the Deno DB tests run | 100% | 100% |
| Edge Function modules (`handler.ts`, `config.ts`, `adapters.ts`) | `deno test --coverage` | 100% | 100% |
| RLS policies (17) | not measurable by tools; `scripts/check-rls-coverage.sh` requires a tagged allowed and denied case for every policy | 17 / 17 | allow and deny |

`index.ts` only passes config to `Deno.serve`. The end-to-end test exercises it inside the edge runtime, where coverage can't be collected. A source file that no test imports would be missing from Deno's report instead of showing 0%, so `ts-coverage.sh` requires each module by name.

Edge cases covered, besides the role matrix:
- **Identity:** a JWT without `sub`, the anon and service-role keys, a validly signed token with a user `sub` but a non-user role, expired, tampered and garbage tokens, anonymous and unconfirmed users.
- **Input bounds:** name, slug, email, title and body lengths, exactly at and one past each limit; slug format and reserved words; the `token_hash` format; non-object and empty JSON bodies; extra fields smuggled into the request body; tokens that need URL encoding.
- **Quotas:** invites per hour, pending invites per workspace, workspaces per user, comments per hour.
- **Lifecycle:** invite revocation by each role; invites from removed, demoted or deleted inviters; workspace deletion cascading to members, invites and articles; account deletion with and without a co-owner, admin-over-member succession, and users owning several workspaces.
- **Concurrency:** two owners stepping down at once; two comments at the quota edge at once; bulk demotion in one statement; refusal under `REPEATABLE READ`.
- **Failure modes:** the auth server or database unreachable from the function, email provider errors and timeouts. All return a JSON error with CORS headers and no internal details.

## Pitfalls

These turned up while writing the tests, and all are fixed:

1. `auto_expose_new_tables = false` still leaves `TRUNCATE`, `REFERENCES` and `TRIGGER` granted to `anon` and `authenticated`. The explicit `revoke all` takes care of that.
2. Inside a function with `search_path = ''`, `=` and `<>` between `citext` values resolve to the case-sensitive `text` operators. It bit us twice, in the invite check and in the expired-invite cleanup. The code now uses `lower()` or `operator(extensions.=)`.
3. Denied `UPDATE` and `DELETE` statements don't raise under RLS, they just touch no rows. A test that checks only the row afterwards can pass for the wrong reason. Our tests count affected rows and pair each denial with an allowed control case.
4. Functions are executable by `PUBLIC` by default, and `authenticated` needs `USAGE` on the `private` schema for the policy helper. Together that made every trigger function in `private` callable by signed-in users. `ALTER DEFAULT PRIVILEGES IN SCHEMA ... REVOKE ... FROM PUBLIC` does not help, because per-schema defaults can only add to the global ones. Each function now revokes `PUBLIC` explicitly, and a test lists exactly which functions each role can execute.
5. `getClaims()` accepts any correctly signed token. A token with a real user's `sub` and `role: service_role` would pass a check on `sub` alone, so the function also requires `role = authenticated`.

A known trade-off: the unique `slug` makes `create_workspace` reveal whether a slug is taken. That is inherent to user-chosen slugs and needs to be shown in the UI anyway.

## AI-assisted development

This repository is set up for work with Claude Code. The agent gets written rules, guard rails that stop it from breaking them, and reviewer subagents; CI repeats the checks on the server, where nothing can be skipped.

### Development rules, and where to look

| Rule | Where to look | How it is enforced or shown |
|---|---|---|
| Row level security on every table; no table without a policy | [`scripts/check-rls-coverage.sh`](scripts/check-rls-coverage.sh), [`CONSTITUTION.md`](CONSTITUTION.md) §1 | Required check `test`. Every application schema is covered (`public`, `private`, and any schema added later): a table without RLS or without a policy fails. A self-test proves each failure mode. |
| A pgTAP test for every policy; acceptance criteria as tests | [`supabase/tests/database/`](supabase/tests/database/), the same script | Each policy needs a tagged test for an allowed and a denied case, or `test` fails. The planner maps each acceptance criterion to the assertion that proves it. |
| CI runs all tests on every pull request; red = not finished; "done" only with test output | [`.github/workflows/ci.yml`](.github/workflows/ci.yml), [`.github/pull_request_template.md`](.github/pull_request_template.md), [`verify-before-stop.sh`](.claude/hooks/verify-before-stop.sh) | Four required checks. The PR template asks for the test output. The agent cannot report work as done while the suites for its changes fail. |
| Pull requests only, one branch per task | Branch protection, [`guard-bash.sh`](.claude/hooks/guard-bash.sh) | `main` accepts only pull requests with all four checks green and an approval, administrators included; no force pushes. Locally the hook refuses pushes to `main` and force pushes. |
| A person approves every pull request | Branch protection, [`.github/CODEOWNERS`](.github/CODEOWNERS) | An approval from someone other than the author. Changes to CI, the Claude configuration, the constitution and the guard scripts need the code owner's approval. Merging and approving are refused to the agent. |
| AI code review on every pull request; open "high" findings block | [`.github/workflows/claude-review.yml`](.github/workflows/claude-review.yml), [`scripts/review-gate.sh`](scripts/review-gate.sh) | Required check `claude-review`. It also fails when the review is incomplete. The reviewer judges against the base branch's rules and constitution, so a pull request cannot rewrite them for its own review, and it has no write access beyond comments. |
| No deploy from a laptop; migrations and functions only through CI | [`guard-bash.sh`](.claude/hooks/guard-bash.sh), [`scripts/check-migrations.sh`](scripts/check-migrations.sh) | The hook refuses deploy and remote-project commands, including `psql` to a hosted database. Required check `guards` fails when a merged migration is edited, renamed or deleted. |
| `CLAUDE.md` and the constitution are binding; plans and specs in `docs/` | [`CONSTITUTION.md`](CONSTITUTION.md), [`CLAUDE.md`](CLAUDE.md), [`docs/plans/`](docs/plans/) | Every Claude Code session, every subagent and the CI reviewer read both. A change that breaks an article of the constitution is a high finding. |
| A plan before each feature (requirements, tables, policies, check step, effort); building after approval | [`/plan`](.claude/commands/plan.md), [`planner`](.claude/agents/planner.md), [`architect`](.claude/agents/architect.md) | `/plan` writes `docs/plans/<date>-<slug>.md`, has it reviewed by the architect subagent, and stops for approval. |
| No secrets in the repository; credentials for hosted projects only in CI | [`.github/workflows/ci.yml`](.github/workflows/ci.yml) (`secrets`), [`.gitignore`](.gitignore), [`.mcp.json`](.mcp.json) | gitleaks scans the full history on every pull request and push. The agent cannot read `.env` files. MCP configuration holds no credentials. |

### The agent's tooling

| Part | Where | What it does |
|---|---|---|
| Rules | [`CONSTITUTION.md`](CONSTITUTION.md), [`CLAUDE.md`](CLAUDE.md) | The invariants, then how to work: stack, check commands, conventions, the order plan → tests → code → review → PR. |
| Hooks | [`.claude/settings.json`](.claude/settings.json), [`.claude/hooks/`](.claude/hooks/) | Refuse deploys, pushes to `main`, force pushes, `.env` access, edits to merged migrations, and the actions that belong to a person (merging, approving, secrets, repository settings). Lint every edited file. Run the affected suites before the agent reports "done". The hooks protect themselves: only a person can change them. 177 tests in [`scripts/tests/hooks.test.sh`](scripts/tests/hooks.test.sh), run in CI. |
| Subagents | [`.claude/agents/`](.claude/agents/) | `planner`, `architect`, `database-reviewer`, `security-reviewer`. |
| Commands | [`.claude/commands/`](.claude/commands/) | `/plan` and `/review`. |
| MCP | [`.mcp.json`](.mcp.json) | Supabase (the local stack, read-only) and GitHub (read-only, token from `GITHUB_PAT`). |
| Claude in CI | [`.github/workflows/claude-review.yml`](.github/workflows/claude-review.yml), [`.github/workflows/claude.yml`](.github/workflows/claude.yml) | Reviews every pull request with the reviewer subagents and comments inline; the required check fails on a high finding. `@claude` in a comment asks Claude for help on an issue or pull request. |

### About this demo

- The setup (rules, hooks, reviewers, CI) arrived as one commit. Later changes to it go through pull requests, like any other change.
- This demo has no hosted Supabase project, so it has no deploy job and no per-PR preview branch. With a hosted project, migrations, functions and secrets reach it only from CI after merge, and every pull request gets a Supabase preview branch.

### Limits of the guard rails

- The hooks are guard rails for the agent, not a sandbox. They read commands word by word, so a value hidden in a variable, brace expansion, a here-document or a git alias can get past them, as can a recursive `grep` over the working tree. They also refuse some harmless commands whose text only looks dangerous. What matters is enforced again on the server: branch protection, the required checks, and credentials for hosted projects that exist only in CI.
- GitHub runs a pull request's own copy of the workflow, so a pull request could change the review job itself. [`.github/CODEOWNERS`](.github/CODEOWNERS) names an owner for CI, the Claude configuration, the constitution and the guard scripts, and code-owner review makes such changes need that owner's approval.

## Running it

Requires Docker, Supabase CLI 3.x and Deno 2.x.

```bash
supabase start -x studio,imgproxy,logflare,vector,supavisor,storage-api,realtime,postgres-meta,mailpit
# (for the Supabase MCP server, keep studio and postgres-meta: see CLAUDE.md)
supabase test db                                  # pgTAP
supabase db lint --level warning --fail-on warning && supabase db advisors

eval "$(supabase status -o env | sed 's/^/export /')"
(cd supabase/tests/deno && DB_URL=$DB_URL deno task test)   # concurrency + auth config
scripts/plpgsql-coverage.sh                       # PL/pgSQL coverage, fails below 100%

(cd supabase/functions/invite-member && deno task check && deno test --allow-env)  # offline unit tests

# everything for the function, live stack and end to end, with the coverage gate
supabase functions serve --env-file supabase/functions/.env.example &
scripts/ts-coverage.sh
```

The function requires `APP_URL` and `INVITE_FROM_EMAIL`. `ALLOWED_ORIGIN` defaults to the origin of `APP_URL`. Without `RESEND_API_KEY` it sends no email and returns the accept link to the admin instead.

## Versions

Postgres 17, Supabase CLI 3.1.0, `@supabase/supabase-js` 2.119.0, zod 4.6.7, postgres.js 4.1.0, `@std/assert` 1.0.19, `@std/toml` 1.0.11, Deno 2.
