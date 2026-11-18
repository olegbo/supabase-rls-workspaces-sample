# Plan: Article comments

## 1. Goal

Members of a workspace can leave flat, plain-text comments on any article they can read: published articles, their own drafts, and, for admins and owners, every draft. A comment is visible only to people who can read its article right now, so hiding an article also hides its comments. The rule is inherited from `kb_articles` RLS and is not copied. Authors edit and delete their own comments while they are members and can read the article; comments on a hidden article are frozen for their author. Admins and owners can delete any comment in their workspace (moderation) but cannot edit someone else's. Comments are deleted with their article (and so with the workspace). They stay when the author leaves the workspace or deletes their account; on account deletion `created_by` becomes null, as it does for articles. At most 100 of a user's comments from the last rolling hour exist at once (deleting one frees its place; open question 10), enforced in the database like the invite quota, and it holds under concurrent sessions. Everything lives in one new migration, one new pgTAP file, three new plan-regression assertions and one Deno concurrency test.

**Out of scope:** threads or replies, reactions, mentions, notifications, rich text or markdown rendering, edit history, soft delete or a moderation audit log, Realtime, Edge Function changes (none needed), and client UI.

## 2. Requirements traced

The feature request, as acceptance criteria. Section 6 maps each to the assertions that prove it.

| # | Requirement | How it is met | Proven by |
|---|---|---|---|
| R1 | Members comment on articles they can read, and only those | Insert policy: membership plus an `exists` on `kb_articles` under the caller's RLS | 4, 6, 8–10, 25, 31, 46 |
| R2 | A comment is visible exactly when its article is | Select policy reuses `kb_articles` RLS through the `exists` | 2, 3, 7, 24, 30, 38, 44, 45 |
| R3 | Authors edit and delete their own comments while members and while the article is readable | Update policy and the author branch of the delete policy: `created_by`, membership and a readable article | 18, 19, 23, 32, 39, 40, 47, 48 |
| R4 | Admins and owners delete any comment in their workspace, edit none | Delete policy admin branch; update policy has none | 33–37, 43 |
| R5 | No comment reaches or is reached from another workspace | Composite FK to `kb_articles (id, workspace_id)`; policies on `workspace_id` | 10, 21, 25–29, 49 |
| R6 | Comments go with their article and workspace; they survive the author leaving or deleting the account | `on delete cascade` from the article; `on delete set null` on `created_by` | 41, 42, 50, 51 |
| R7 | Plain text, 1 to 4000 characters, not only whitespace | Check constraint | 13–17 |
| R8 | At most 100 of a user's comments from the last rolling hour exist at once, also under concurrency | `before insert` trigger with a per-author advisory lock | 12, 52–55, Deno race test |
| R9 | Listing comments stays fast at scale | Indexes; plan-regression assertions in 04 | 04: three new assertions |

## 3. Access matrix

"Readable article" means a published article, or one of your own drafts; admins and owners can read every draft. "Outsider" is any signed-in user who is not a member of the comment's workspace, including former members.

| Action | anon | outsider | member | admin | owner |
|---|:-:|:-:|:-:|:-:|:-:|
| Read comments on a published article | — | — | ✓ | ✓ | ✓ |
| Read comments on own draft | — | — | ✓ | ✓ | ✓ |
| Read comments on someone else's draft | — | — | — | ✓ | ✓ |
| Read comments once the article is hidden from you (unpublished), own comments included | — | — | — | n/a (admins read all) | n/a |
| Comment on an article they can read (up to 100 per hour per user) | — | — | ✓ | ✓ | ✓ |
| Comment on an article they cannot read, or in another workspace | — | — | — | — | — |
| Edit own comment (`body` only) | — | — | ✓ | ✓ | ✓ |
| Edit own comment once the article is hidden from you | — | — | — | n/a (admins read all) | n/a |
| Delete own comment once the article is hidden from you | — | — | — | n/a (admins delete any) | n/a |
| Edit someone else's comment | — | — | — | — | — |
| Delete own comment | — | — | ✓ | ✓ | ✓ |
| Delete any comment in the workspace, including an owner's or a deleted user's | — | — | — | ✓ | ✓ |
| Set `id`, `created_by`, `created_at`, `updated_at`; move a comment (`article_id`, `workspace_id`) | — | — | — | — | — |
| Edit or delete own comments after leaving the workspace | — | — | n/a | n/a | n/a |

## 4. Schema

New migration: `supabase/migrations/20261117120000_kb_article_comments.sql`. It sorts after `20261110120100_kb_articles.sql`, and no merged migration changes.

**Prerequisite on `kb_articles`** (new index, existing table untouched otherwise). This is the target of the composite FK, so a comment's workspace must equal its article's workspace:

```sql
create unique index kb_articles_id_workspace_id_key on public.kb_articles (id, workspace_id);
```

**Table:**

```sql
create table public.kb_article_comments (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  article_id   uuid not null,
  body         text not null check (char_length(body) between 1 and 4000 and body ~ '[^[:space:]]'),
  created_by   uuid default auth.uid() references auth.users (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  foreign key (article_id, workspace_id)
    references public.kb_articles (id, workspace_id) on delete cascade
);
```

- **`workspace_id` is stored on the comment** so policies can use `= any (array(select private.workspace_ids_with_role(...)))` with an index, the same way every other table does. The composite FK makes it impossible to store a workspace that differs from the article's. That holds for every writer, including the service role, and no trigger is needed. Clients cannot change `kb_articles.workspace_id` (no update grant), and the default `on update no action` blocks a privileged move while comments exist.
- **No separate FK to `workspaces`.** Workspace deletion cascades to articles, and article deletion cascades to comments. One cascade path is enough.
- **`on delete cascade` from the article:** a comment has no meaning without its article.
- **`created_by ... on delete set null`:** account deletion keeps the comment, anonymised, matching `kb_articles.created_by`. See open question 1.
- **Leaving the workspace:** nothing happens to the rows. The former member loses all access through the membership predicate.
- **Body:** 1 to 4000 characters, and it must contain at least one non-whitespace character. It is plain text; clients must render it as text, never as HTML.

**Indexes:**

```sql
-- Leading columns cover the composite FK exactly (article delete cascade, `db advisors`);
-- created_at gives ordered per-article lists.
create index kb_article_comments_article_id_idx
  on public.kb_article_comments (article_id, workspace_id, created_at);
-- Policy filter on workspace_id; serves the unfiltered "recent comments" list.
create index kb_article_comments_workspace_id_idx
  on public.kb_article_comments (workspace_id, created_at desc);
-- FK to auth.users (set null on account deletion), author policies, and the quota count.
create index kb_article_comments_created_by_idx
  on public.kb_article_comments (created_by, created_at);
```

**Triggers:**

1. `kb_article_comments_touch_updated_at`: `before update ... for each row execute function private.touch_updated_at()`. This reuses the existing function, so there is no new PL/pgSQL. `updated_at > created_at` is not an "edited" flag: setting `created_by` to null on account deletion fires the trigger too.
2. Quota, a new function modelled on `before_invite_insert`:

```sql
create function private.before_comment_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Clients always have an author (grants + policy). A null author is the service role or
  -- a fixture: not limited, and the 04 fixture of 100k rows stays fast.
  if new.created_by is null then
    return new;
  end if;

  -- Serialize inserts per author, so concurrent sessions cannot each count before the
  -- others commit.
  perform pg_advisory_xact_lock(hashtextextended('kb_article_comments:' || new.created_by::text, 0));

  if (
    select count(*) from public.kb_article_comments c
    where c.created_by = new.created_by and c.created_at > now() - interval '1 hour'
  ) >= 100 then
    raise exception 'comment rate limit exceeded' using errcode = 'PT429';
  end if;

  return new;
end
$$;

-- Functions are executable by PUBLIC by default; trigger functions need no grant.
revoke all on function private.before_comment_insert from public;

create trigger kb_article_comments_before_insert
  before insert on public.kb_article_comments
  for each row execute function private.before_comment_insert();
```

**Why a quota.** PostgREST exposes inserts directly to every signed-in user, and Supabase's rate limits cover only auth endpoints. Without a cap, one member could write millions of 4000-character rows, burying an article and growing the database. The cap is per user across all workspaces, which needs one index and matches the invite quota. 100 per hour is well above human discussion pace.

**Why a lock.** Count-then-insert is not atomic: N concurrent sessions at 99 would each count 99 and each insert, and a script with many connections could post up to 100 comments per session. A transaction-scoped advisory lock keyed on the author serializes one author's inserts only; other authors never wait. Under `READ COMMITTED` the count runs after the lock is granted, so it sees every comment committed by the session that held it.

**Why `security definer`.** With invoker rights, RLS would hide the user's own comments on articles they can no longer read, so the count would be too low. With `created_by = null` (inserts without a JWT, such as fixtures or the service role) the trigger returns at once.

**Coverage.** The function has three paths: no author (hit by the 04 plan fixture, which inserts without a JWT), the raise (assertions 52 and 54) and the normal return (assertion 53). All are hit, so PL/pgSQL coverage stays at 100%. `touch_updated_at` is already covered.

## 5. Grants and policies

In migration order, after the table, indexes and triggers:

```sql
revoke all on public.kb_article_comments from anon, authenticated;

alter table public.kb_article_comments enable row level security;
```

**Pitfall to observe.** `kb_articles` also has `id`, `workspace_id`, `body` and `created_by`. Inside an `exists (select ... from public.kb_articles a ...)`, an unqualified column name resolves to `a`. Every outer column in those subqueries must be written as `kb_article_comments.<col>`.

**`"members read comments on readable articles"`**, `for select to authenticated`. The `exists` on `kb_articles` runs under the caller's `kb_articles` RLS, so the article visibility rule (published, own draft, or admin) is reused rather than duplicated, and stays correct if that rule changes later. The `workspace_id` predicate is logically implied by the FK, but it gives the planner the index.

```sql
using (
  workspace_id = any (array(select private.workspace_ids_with_role('member')))
  and exists (select 1 from public.kb_articles a where a.id = kb_article_comments.article_id)
)
```

**`"members comment on readable articles"`**, `for insert to authenticated`:

```sql
with check (
  created_by = (select auth.uid())
  and workspace_id = any (array(select private.workspace_ids_with_role('member')))
  and exists (select 1 from public.kb_articles a where a.id = kb_article_comments.article_id)
)
```

**`"authors edit own comments"`**, `for update to authenticated`. Admins are deliberately not included: the feature allows them to delete only. `using` also requires the article to be readable: an update that reads no column (`set body = '...'` with no `WHERE`) does not bring in the read policy, so without it an author could rewrite comments on an article now hidden from them. `with check` needs no `exists`: a row that passed `using` is on a readable article, and `article_id` cannot change.

```sql
using (
  created_by = (select auth.uid())
  and workspace_id = any (array(select private.workspace_ids_with_role('member')))
  and exists (select 1 from public.kb_articles a where a.id = kb_article_comments.article_id)
)
with check (
  created_by = (select auth.uid())
  and workspace_id = any (array(select private.workspace_ids_with_role('member')))
)
```

**`"authors and admins delete comments"`**, `for delete to authenticated`. The author branch also requires a readable article, like the update policy; the admin branch does not, so moderators can remove comments on any article:

```sql
using (
  workspace_id = any (array(select private.workspace_ids_with_role('admin')))
  or (
    workspace_id = any (array(select private.workspace_ids_with_role('member')))
    and created_by = (select auth.uid())
    and exists (select 1 from public.kb_articles a where a.id = kb_article_comments.article_id)
  )
)
```

**Grants.** Clients never set `id`, `created_by`, `created_at` or `updated_at`. Blocking `created_at` also stops clients from backdating comments out of the quota window. `workspace_id` and `article_id` are insert-only.

```sql
grant select, delete on public.kb_article_comments to authenticated;
grant insert (workspace_id, article_id, body) on public.kb_article_comments to authenticated;
grant update (body) on public.kb_article_comments to authenticated;
```

`anon` gets nothing; the existing 01 schema assertions cover that for every public table. The new private function revokes `PUBLIC`, so the list in 05 ("authenticated can execute only the two RPCs and the policy helper") stays unchanged and will catch a missing revoke.

## 6. Tests and check step

### `supabase/tests/database/06_article_comments.test.sql` (new, `select plan(55)`)

The file is wrapped in `begin; ... rollback;`. The numbers below are the assertion order in the file.

**Fixtures** (as postgres):
- **Users:** `a1` owner, `ad` admin, `b1` member, `b2` member, `b3` member (quota only), `f5` member (to leave and be deleted). These are all in acme `w1`. `d1` owns other `w2`. `d2` owns third `w3`, which has no comments anywhere.
- **Articles:**
  - `art01` "Published": w1, published, by a1.
  - `art02` "Owner draft": w1, draft, by a1.
  - `art03` "Member draft": w1, draft, by b1.
  - `art04` "Foreign": w2, published, by d1.
  - `art05` "Board": w1, published, by a1.
- **Comments:**
  - `'owner comment'` on art01 by a1.
  - `'m2 comment'` on art01 by b2.
  - `'m1 old comment'` on art01 by b1, with `created_at` and `updated_at` set to `now() - interval '1 day'`.
  - `'gone comment'` on art01 by f5.
  - `'review note'` on art02 by ad.
  - `'foreign comment'` on art04 by d1.

**Anon**

1. anon cannot read comments: `throws_ok('select 1 from public.kb_article_comments', '42501')`, untagged (grant).

**Member** (b1)

2. member reads comments on published articles of own workspace: `results_eq('select body ... order by body', array['gone comment','m1 old comment','m2 comment','owner comment'])`, `@policy kb_article_comments "members read comments on readable articles" allow`
3. member cannot read comments on someone else's draft: `is(count where body = 'review note', 0)`, `@policy kb_article_comments "members read comments on readable articles" deny`
4. member can comment on a published article (art01, `'m1 comment'`): `lives_ok`, `@policy kb_article_comments "members comment on readable articles" allow`
5. author is set from the JWT: `is(created_by where body = 'm1 comment', b1)`, untagged
6. member can comment on own draft (art03, `'draft comment'`): `lives_ok`, `@policy kb_article_comments "members comment on readable articles" allow`
7. member reads comments on own draft: `is(count where body = 'draft comment', 1)`, `@policy kb_article_comments "members read comments on readable articles" allow`. Without it, a read policy limited to published articles would pass.
8. member cannot comment on a draft they cannot read (art02): `throws_ok(..., '42501', 'new row violates row-level security policy for table "kb_article_comments"')`, `@policy kb_article_comments "members comment on readable articles" deny`
9. member cannot comment in a foreign workspace (w2, art04): same `throws_ok`, `@policy kb_article_comments "members comment on readable articles" deny`
10. member cannot comment on a foreign article under their own workspace id (w1, art04): same `throws_ok`, `@policy kb_article_comments "members comment on readable articles" deny`
11. member cannot spoof the author (insert with `created_by = a1`): `throws_ok(..., '42501', 'permission denied for table kb_article_comments')`, untagged (column grant; the message tells a missing grant from an RLS denial, which raises 42501 too)
12. member cannot set `created_at`, so no backdating past the quota: `throws_ok(..., '42501', 'permission denied for table kb_article_comments')`, untagged (column grant; the message tells a missing grant from an RLS denial, which raises 42501 too)
13. member cannot post an empty body (art01): `throws_ok(..., '23514')`, untagged
14. a body of exactly 1 character is accepted: `lives_ok('x')` on art05, so the art01 counts below stay the same, untagged
15. member cannot post a whitespace-only body (`E' \n\t '`, art01): `throws_ok(..., '23514')`, untagged
16. member can post a body of exactly 4000 characters (art01): `lives_ok(repeat('b', 4000))`, untagged. Assertion 44 counts it.
17. member cannot post a body of 4001 characters (art01): `throws_ok(repeat('b', 4001), '23514')`, untagged
18. author can edit own comment and `updated_at` is refreshed: `results_eq('with r as (update ... set body = ''m1 edited'' where body = ''m1 old comment'' returning updated_at > created_at) select * from r', array[true])`, `@policy kb_article_comments "authors edit own comments" allow`
19. member cannot edit someone else's comment (`'m2 comment'`): `results_eq(affected count, array[0])`, `@policy kb_article_comments "authors edit own comments" deny`
20. member cannot move a comment to another article (`set article_id = art03`): `throws_ok(..., '42501', 'permission denied for table kb_article_comments')`, untagged (column grant; the message tells a missing grant from an RLS denial, which raises 42501 too)
21. member cannot move a comment to another workspace (`set workspace_id = w2`): `throws_ok(..., '42501', 'permission denied for table kb_article_comments')`, untagged (column grant; the message tells a missing grant from an RLS denial, which raises 42501 too)
22. member cannot delete someone else's comment (`'m2 comment'`): `results_eq(affected count, array[0])`, `@policy kb_article_comments "authors and admins delete comments" deny`
23. author can delete own comment (`'m1 comment'`): `results_eq(affected count, array[1])`, `@policy kb_article_comments "authors and admins delete comments" allow`

**Outsider** (d1)

24. outsider sees only comments of own workspace: `results_eq('select body ...', array['foreign comment'])`, `@policy kb_article_comments "members read comments on readable articles" deny`
25. outsider cannot comment on an acme article: `throws_ok` with the RLS message, `@policy kb_article_comments "members comment on readable articles" deny`
26. outsider cannot edit acme comments (`where workspace_id = w1`): `results_eq(affected count, array[0])`, untagged: the read policy hides acme comments from an outsider, so it cannot isolate the update policy
27. outsider cannot delete acme comments: `results_eq(affected count, array[0])`, untagged, for the same reason

**Admin of another workspace** (d2, who has written no comments anywhere)

28. an unfiltered update touches no row: `results_eq(affected count, array[0])`, `@policy kb_article_comments "authors edit own comments" deny`. With no `WHERE`, the read policy cannot mask a write policy that is not tied to the workspace.
29. an unfiltered delete touches no row: `results_eq(affected count, array[0])`, `@policy kb_article_comments "authors and admins delete comments" deny`. Same reason; this proves the admin branch of the delete policy stays in its own workspace.

**Admin** (ad)

30. admin can read comments on any draft (`where article_id = art02`): `results_eq(array['review note'])`, `@policy kb_article_comments "members read comments on readable articles" allow`
31. admin can comment on a member's draft (art03, `'admin note'`), which admins can read: `lives_ok`, `@policy kb_article_comments "members comment on readable articles" allow`. The insert policy inherits the admin branch of draft visibility.
32. admin can edit own comment (`'review note'` to `'review note, edited'`): `results_eq(affected count, array[1])`, `@policy kb_article_comments "authors edit own comments" allow`
33. admin cannot edit a member's comment (`'m2 comment'`): `results_eq(affected count, array[0])`, `@policy kb_article_comments "authors edit own comments" deny`
34. admin can delete a member's comment (`'m2 comment'`, which doubles as the control for 33): `results_eq(array[1])`, `@policy kb_article_comments "authors and admins delete comments" allow`
35. admin can delete the owner's comment (`'owner comment'`): `results_eq(array[1])`, `@policy kb_article_comments "authors and admins delete comments" allow`

**Owner** (a1)

36. owner cannot edit a member's comment (`'m1 edited'`): `results_eq(array[0])`, `@policy kb_article_comments "authors edit own comments" deny`
37. owner can delete a comment on a member's draft (`'draft comment'`): `results_eq(array[1])`, `@policy kb_article_comments "authors and admins delete comments" allow`

**Author leaves** (as postgres: delete f5's acme membership; then as f5)

38. ex-member no longer reads any comment of the workspace, own included: `is(count(*), 0)`, `@policy kb_article_comments "members read comments on readable articles" deny`
39. ex-member cannot edit their old comment, with an unfiltered update: `results_eq(array[0])`, `@policy kb_article_comments "authors edit own comments" deny`
40. ex-member cannot delete their old comment, with an unfiltered delete: `results_eq(array[0])`, `@policy kb_article_comments "authors and admins delete comments" deny`
41. the comment survives the author leaving (as postgres): `is(count where body = 'gone comment', 1)`, untagged

**Account deletion** (as postgres: `delete from auth.users where id = f5`)

42. the comment survives account deletion with no author: `ok((select created_by is null ... where body = 'gone comment'))`, untagged
43. admin can delete a comment whose author account is gone (as ad): `results_eq(array[1])`, `@policy kb_article_comments "authors and admins delete comments" allow`

**Visibility follows the article** (as b1)

44. member sees comments on art01 while it is published: `is(count where article_id = art01, 2)` (`'m1 edited'` plus the 4000-character body), `@policy kb_article_comments "members read comments on readable articles" allow`

As postgres: `update kb_articles set published = false where id = art01`. Then as b1:

45. author no longer sees own comments once the article is hidden: `is(count where article_id = art01, 0)`, `@policy kb_article_comments "members read comments on readable articles" deny`
46. member cannot comment on an article once it is unpublished: `throws_ok` with the RLS message, `@policy kb_article_comments "members comment on readable articles" deny`
47. author cannot edit own comments on an article once it is unpublished: as b1, `with r as (update ... set body = 'edited while hidden' returning 1) select count(*)`, expecting `array[1]` (only b1's comment on art05; the two on art01 stay). `@policy kb_article_comments "authors edit own comments" deny`. The update sets a constant and reads no column, so the read policy does not join in and cannot mask the update policy.
48. author cannot delete own comments on an article once it is unpublished: as b1, an unfiltered `with r as (delete ... returning 1) select count(*)`, expecting `array[1]` (only the comment on art05). `@policy kb_article_comments "authors and admins delete comments" deny`. Unfiltered for the same reason as 47.

**Integrity and cascades** (as postgres, RLS bypassed)

49. the FK holds even without RLS: a comment with `workspace_id = w1` cannot point at art04 in w2: `throws_ok(..., '23503')`, untagged
50. comments go with their article (`delete from kb_articles where id = art01`): `is(count where article_id = art01, 0)`, untagged
51. comments go with the workspace (`delete from workspaces where id = w2`): `is(count where body = 'foreign comment', 0)`, untagged

**Quota** (as postgres, with `created_by = b3` written out because `request.jwt.claims` set earlier in the transaction still applies: insert 50 b3 comments on art05 at `now() - interval '61 minutes'`, one at exactly `now() - interval '1 hour'`, then 99 inside the window: one at `now() - interval '1 hour' + interval '1 second'` (pins the inner edge: a narrower window would miss it) and 98 at `now() - interval '30 minutes'`; as b3)

52. a two-row insert at 99 is refused as a whole (a PostgREST bulk POST is one multi-row INSERT): `throws_ok(insert ... select ... from generate_series(1, 2), 'PT429', 'comment rate limit exceeded')`, untagged. The row trigger sees rows inserted earlier in the same statement because the function is volatile; marked `stable`, it would let both through. Assertion 53 then shows neither row was kept.
53. b3's 100th comment within an hour is accepted: `lives_ok`, untagged. Hits the trigger's return branch.
54. b3's 101st comment within an hour is refused: `throws_ok(..., 'PT429', 'comment rate limit exceeded')`, untagged. Hits the raise branch. The rows at 61 minutes and at exactly one hour pin both edges of the window: a wider window, or `>=` instead of `>`, would count them and refuse the 100th comment.
55. the quota is per user, so another member is unaffected (b1 on art05): `lives_ok`, untagged

**Tag tally** (every policy has at least one allow and one deny):

| Policy | Allow | Deny |
|---|---|---|
| select | 2, 7, 30, 44 | 3, 24, 38, 45 |
| insert | 4, 6, 31 | 8, 9, 10, 25, 46 |
| update | 18, 32 | 19, 28, 33, 36, 39, 47 |
| delete | 23, 34, 35, 37, 43 | 22, 29, 40, 48 |

### `supabase/tests/database/04_policy_plans.test.sql` (edit, `plan(4)` becomes `plan(7)`)

A plan test is needed. The SELECT policy semi-joins `kb_articles` under its own OR-ed RLS, which can tempt the planner into a hash semi-join over a sequential scan of `kb_articles`. That is the regression this file exists for, and PostgREST lets any client issue an unfiltered `GET /kb_article_comments`.

**Fixture** (before `set local role`, so `created_by` is null and the quota trigger counts 0):

```sql
insert into public.kb_article_comments (workspace_id, article_id, body)
select workspace_id, id, 'C' from public.kb_articles;
```

This gives 100k comments, one per article. Add `public.kb_article_comments` to the `analyze` line.

**New assertions:**
- reader can list one article's comments without a full scan: `doesnt_match(tests.plan_of(format('select id from public.kb_article_comments where article_id = %L order by created_at limit 50', <an article id the reader can see>)), 'Seq Scan on kb_article_comments')`
- reader can list recent comments without scanning either table: `doesnt_match(tests.plan_of('select id from public.kb_article_comments order by created_at desc limit 20'), 'Seq Scan on kb_article(s|_comments)')`
- visible comments match visible articles: `is((select count(*)::int from public.kb_article_comments), (select count(*)::int from public.kb_articles))`. With one comment per article, this proves comments on hidden drafts are hidden and that the plans above are not trivially empty.

### `supabase/tests/deno/comment_quota_race.test.ts` (new)

The quota under concurrency cannot be tested in one pgTAP transaction. The author starts with 99 comments inside the window. Session 1 inserts the 100th and keeps its transaction open; only then does session 2 insert. Session 1 commits once session 2 is waiting on a lock (`pg_stat_activity`), or has finished, which happens only when nothing blocks it. The order is fixed, not left to timing: with the lock, session 2 waits, counts 100 and gets `PT429`, and the author ends with exactly 100 comments; without it, session 2 counts 99 and inserts too, and the test fails.

**Unchanged suites:** 01 (RLS on every table; anon has no privileges) and 05 (function execute list) pick up the new table and function automatically, and must still pass. The Edge Function does not change.

**Check step.** Every requirement in section 2 maps to the assertions above. Each new test is also run once against a deliberately broken policy or trigger, to see it fail: the read policy limited to published articles (7 fails), the delete policy's admin branch untied from the workspace (29 fails), the update or delete policy without the readable-article check (47 or 48 fails), the lock removed (the Deno race test fails).

## 7. Commits

1. `docs: plan article comments`: this plan as `docs/plans/2026-11-17-article-comments.md`.
2. `test: article comments`: the new `06_article_comments.test.sql`, the 04 additions and the Deno race test. CI goes red because `relation "public.kb_article_comments" does not exist`. `check-rls-coverage.sh` also fails, on tags naming policies that do not exist yet. Both are expected; report them.
3. `feat: article comments`: `supabase/migrations/20261117120000_kb_article_comments.sql`, plus README updates:
   - the data model diagram (`kb_articles ──< kb_article_comments`)
   - a comments row in the role table
   - a "Design decisions" bullet on the composite FK, RLS inherited from articles, the quota and its lock
   - Quotas: 100 comments per hour per user; concurrency: two comments at the quota edge at once
   - counts: pgTAP 129 → 187, Deno tests 5 → 6, PL/pgSQL functions 6 → 7, RLS policies 13 → 17

   Then run `supabase db reset`, `supabase test db`, `scripts/check-rls-coverage.sh`, the Deno DB tests, `scripts/plpgsql-coverage.sh 100`, `supabase db lint --level warning --fail-on warning && supabase db advisors`, and `scripts/check-migrations.sh origin/main`. CI goes green.
4. Follow-ups from `/review` and `claude-review`, one commit per fix.

## 8. Effort

| Step | Hours | What drives it |
|---|---|---|
| Plan and architect review | 1.5 | The access matrix and the inherited-visibility design; checking plans on 100k rows |
| Tests | 3 | 55 pgTAP assertions with exact counts, unmasked write denials, the race test with two connections, and a mutation run per new test |
| Migration and README | 1.5 | Small DDL; most of the time is the quota trigger and the coverage gate |
| Review fixes | 1–2 | Depends on what review finds |
| **Total** | **7–8** | |

## 9. Risks and open questions

1. **Account deletion keeps comment bodies.** `created_by` becomes null and the text stays, matching articles. For a GDPR erasure request, should a user's comments be deleted instead (`on delete cascade` on `created_by`)? This needs a product or legal decision.
2. **Limits.** Confirm the body limit of 4000 characters and the quota of 100 comments from the last rolling hour per user, across all workspaces.
3. **Moderation does not follow the strict role hierarchy.** Admins can delete an owner's comment, consistent with admins editing and deleting owners' articles today. Confirm this is wanted.
4. **No moderation trail.** Deletes are hard deletes, so there is no record of who removed what. Acceptable for now?
5. **Rejoining restores rights.** A former member who is invited back regains edit and delete rights on their old comments, because the rights are keyed on `created_by` plus current membership. Acceptable?
6. **The quota lock serializes one author's inserts.** Concurrent comments by the same user wait for each other for the length of a transaction. Other users are not affected. Acceptable at human posting rates.
7. **Migration lock on `kb_articles`.** `create unique index kb_articles_id_workspace_id_key` takes a SHARE lock, blocking article writes while it builds. That is brief at the scale of the README's benchmark (around 600k rows; this demo has no production data), and `concurrently` is unavailable inside a migration transaction. With a hosted project, check its size before deploying.
8. **Editing and deleting comments on a hidden article.** *Decided at plan approval, corrected in PR review:* comments on a hidden article are frozen for their author: no edit (assertion 47) and no delete (48); admins can still delete them. The first decision let authors delete them, but every API delete has a filter, which brings in the read policy and hides those rows, so it could not work as written.
9. **Plain text rendering is a client responsibility.** The database stores raw text and cannot prevent XSS. The UI must render comment bodies as text.
10. **What the quota limits.** *Raised in PR review, accepted:* it counts the author's comments from the last hour that still exist, the same way the invite quota counts invites. Deleting a comment frees its place, so post-delete-repost loops are not capped, and edits are not limited at all. The goal is to stop one member from burying an article or growing the database, which this does: deleted rows take no space, and an edit rewrites one row. Counting attempts would need a per-author counter that deletes do not decrement, and rate-limiting edits a second trigger; both are left for when abuse shows up, and are better handled per IP at the API gateway.

## 10. Architect review

**Verdict: approve with changes.** The required changes are applied above.

Checked: the design fits the tenant model; the composite FK keeps a comment in its article's workspace; read and insert reuse `kb_articles` RLS instead of copying it; grants follow the constitution (§1.2); the quota is enforced in the database. Numbering, tag tally and the requirement mapping agree, and `plan(52)` matched the numbered assertions at the time of the review.

Required changes, all applied:
1. The Deno race test is described precisely: session 1 holds its transaction open while session 2 inserts, and the final count is asserted, so the test fails without the lock instead of passing by timing.
2. Admin rows of the access matrix are proven too: an admin comments on a member's draft (31) and edits their own comment (32).
3. The README count was stale: the suites total 129, not 127 (fixed before this branch); with this feature, 184 at the time of the review (185 with assertion 47).

Suggestions not taken, to keep the change small: `before update of body` for the touch trigger (an "edited" flag is out of scope); dropping the redundant lower bound in the body check (it documents the rule); refusing `REPEATABLE READ` in the quota trigger (PostgREST does not let clients choose the isolation level).

Recommendations on the open questions: accept 1–7 and 9 as written. On 8, add the `exists` on `kb_articles` to the UPDATE policy with one tagged deny, and leave DELETE without it, so authors can always remove their own text while they are members. Adopted at plan approval: assertion 47, `plan(53)`.
