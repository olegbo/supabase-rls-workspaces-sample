# Workspace KB: Supabase sample

An anonymised excerpt from a multi-tenant knowledge-base SaaS we built and run in production. The original runs on plain Postgres with RLS. This sample ports the same tenant model to Supabase: `auth.uid()`, policies, an Edge Function, and tests at every layer.

Contents:

| What | Where |
|---|---|
| Migration: workspaces, roles, invites, account deletion | `supabase/migrations/20261110120000_workspaces_rbac.sql` |
| Migration: workspace-scoped articles | `supabase/migrations/20261110120100_kb_articles.sql` |
| Edge Function: `invite-member` | `supabase/functions/invite-member/` |
| Database tests (pgTAP, 127 assertions incl. a plan regression test and edge cases) | `supabase/tests/database/` |
| Concurrency and auth-config tests (Deno, 5) | `supabase/tests/deno/` |
| Function tests (36): handler, config, adapters against the live stack, end to end | `supabase/functions/invite-member/*.test.ts` |
| Coverage gates | `scripts/plpgsql-coverage.sh`, `scripts/ts-coverage.sh` |
| CI | `.github/workflows/ci.yml` |

## Data model and roles

```
auth.users ──< workspace_members >── workspaces ──< kb_articles
                  role: member | admin | owner        └─< workspace_invites
```

The hierarchy is strict: you manage only roles below your own.

| Action | member | admin | owner |
|---|:-:|:-:|:-:|
| Read the workspace and its members | ✓ | ✓ | ✓ |
| Read published articles and own drafts, write own articles | ✓ | ✓ | ✓ |
| Read all drafts, edit or delete any article | | ✓ | ✓ |
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
- **Quotas.** Each user can send 20 invites per hour, each workspace can have 100 pending invites, and each user can create 10 workspaces. Signup and email rates use Supabase's `[auth.rate_limit]`.
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
| PL/pgSQL functions and triggers (6) | `plpgsql_check` profiler while pgTAP and the Deno DB tests run | 100% | 100% |
| Edge Function modules (`handler.ts`, `config.ts`, `adapters.ts`) | `deno test --coverage` | 100% | 100% |
| RLS policies (13) | not measurable by tools; every policy has at least one allowed and one denied case | 13 / 13 | allow and deny |

`index.ts` only passes config to `Deno.serve`. The end-to-end test exercises it inside the edge runtime, where coverage can't be collected. A source file that no test imports would be missing from Deno's report instead of showing 0%, so `ts-coverage.sh` requires each module by name.

Edge cases covered, besides the role matrix:
- **Identity:** a JWT without `sub`, the anon and service-role keys, a validly signed token with a user `sub` but a non-user role, expired, tampered and garbage tokens, anonymous and unconfirmed users.
- **Input bounds:** name, slug, email, title and body lengths, exactly at and one past each limit; slug format and reserved words; the `token_hash` format; non-object and empty JSON bodies; extra fields smuggled into the request body; tokens that need URL encoding.
- **Quotas:** invites per hour, pending invites per workspace, workspaces per user.
- **Lifecycle:** invite revocation by each role; invites from removed, demoted or deleted inviters; workspace deletion cascading to members, invites and articles; account deletion with and without a co-owner, admin-over-member succession, and users owning several workspaces.
- **Concurrency:** two owners stepping down at once; bulk demotion in one statement; refusal under `REPEATABLE READ`.
- **Failure modes:** the auth server or database unreachable from the function, email provider errors and timeouts. All return a JSON error with CORS headers and no internal details.

## Pitfalls

These turned up while writing the tests, and all are fixed:

1. `auto_expose_new_tables = false` still leaves `TRUNCATE`, `REFERENCES` and `TRIGGER` granted to `anon` and `authenticated`. The explicit `revoke all` takes care of that.
2. Inside a function with `search_path = ''`, `=` and `<>` between `citext` values resolve to the case-sensitive `text` operators. It bit us twice, in the invite check and in the expired-invite cleanup. The code now uses `lower()` or `operator(extensions.=)`.
3. Denied `UPDATE` and `DELETE` statements don't raise under RLS, they just touch no rows. A test that checks only the row afterwards can pass for the wrong reason. Our tests count affected rows and pair each denial with an allowed control case.
4. Functions are executable by `PUBLIC` by default, and `authenticated` needs `USAGE` on the `private` schema for the policy helper. Together that made every trigger function in `private` callable by signed-in users. `ALTER DEFAULT PRIVILEGES IN SCHEMA ... REVOKE ... FROM PUBLIC` does not help, because per-schema defaults can only add to the global ones. Each function now revokes `PUBLIC` explicitly, and a test lists exactly which functions each role can execute.
5. `getClaims()` accepts any correctly signed token. A token with a real user's `sub` and `role: service_role` would pass a check on `sub` alone, so the function also requires `role = authenticated`.

A known trade-off: the unique `slug` makes `create_workspace` reveal whether a slug is taken. That is inherent to user-chosen slugs and needs to be shown in the UI anyway.

## Running it

Requires Docker, Supabase CLI 3.x and Deno 2.x.

```bash
supabase start -x studio,imgproxy,logflare,vector,supavisor,storage-api,realtime,postgres-meta,mailpit
supabase test db                                  # pgTAP
supabase db lint && supabase db advisors

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
