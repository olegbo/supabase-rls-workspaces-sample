-- kb_article_comments: access matrix, lifecycle, integrity and quota.
-- Plan: docs/plans/2026-11-17-article-comments.md
--
-- A comment is visible exactly when its article is visible to the reader. Authors edit and
-- delete their own comments; admins and owners delete any comment (moderation) but edit none.
-- Denied UPDATE/DELETE do not raise under RLS, so they assert the affected-row count and
-- are paired with an allowed case on the same row.
begin;
create extension if not exists pgtap with schema extensions;
select plan(54);

-- Fixtures (as postgres, RLS does not apply) ------------------------------------
--   acme  (w1): a1 owner, ad admin, b1 b2 b3 f5 members
--   other (w2): d1 owner
--   third (w3): d2 owner, and no comments anywhere
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'a1@example.test', now()),
  ('00000000-0000-0000-0000-0000000000ad', 'ad@example.test', now()),
  ('00000000-0000-0000-0000-0000000000b1', 'b1@example.test', now()),
  ('00000000-0000-0000-0000-0000000000b2', 'b2@example.test', now()),
  ('00000000-0000-0000-0000-0000000000b3', 'b3@example.test', now()),
  ('00000000-0000-0000-0000-0000000000f5', 'f5@example.test', now()),
  ('00000000-0000-0000-0000-0000000000d1', 'd1@example.test', now()),
  ('00000000-0000-0000-0000-0000000000d2', 'd2@example.test', now());

insert into public.workspaces (id, name, slug) values
  ('10000000-0000-0000-0000-000000000001', 'Acme', 'acme'),
  ('10000000-0000-0000-0000-000000000002', 'Other', 'other'),
  ('10000000-0000-0000-0000-000000000003', 'Third', 'third');

insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000ad', 'admin'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000b1', 'member'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000b2', 'member'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000b3', 'member'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000f5', 'member'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000d1', 'owner'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000d2', 'owner');

insert into public.kb_articles (id, workspace_id, title, published, created_by) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Published', true,
   '00000000-0000-0000-0000-0000000000a1'),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Owner draft', false,
   '00000000-0000-0000-0000-0000000000a1'),
  ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'Member draft', false,
   '00000000-0000-0000-0000-0000000000b1'),
  ('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002', 'Foreign', true,
   '00000000-0000-0000-0000-0000000000d1'),
  ('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', 'Board', true,
   '00000000-0000-0000-0000-0000000000a1');

insert into public.kb_article_comments (workspace_id, article_id, body, created_by) values
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'owner comment',
   '00000000-0000-0000-0000-0000000000a1'),
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'm2 comment',
   '00000000-0000-0000-0000-0000000000b2'),
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'gone comment',
   '00000000-0000-0000-0000-0000000000f5'),
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'review note',
   '00000000-0000-0000-0000-0000000000ad'),
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000004', 'foreign comment',
   '00000000-0000-0000-0000-0000000000d1');

-- Written a day ago, so an edit visibly moves updated_at past created_at (now() is fixed
-- for the whole transaction).
insert into public.kb_article_comments (workspace_id, article_id, body, created_by, created_at, updated_at)
values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'm1 old comment',
        '00000000-0000-0000-0000-0000000000b1', now() - interval '1 day', now() - interval '1 day');

-- Anonymous ---------------------------------------------------------------------
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

select throws_ok('select 1 from public.kb_article_comments', '42501', null,
  'anon cannot read comments');

-- Member (b1) -------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);

-- @policy kb_article_comments "members read comments on readable articles" allow
select results_eq('select body from public.kb_article_comments order by body',
  array['gone comment', 'm1 old comment', 'm2 comment', 'owner comment'],
  'member reads comments on published articles of own workspace');

-- @policy kb_article_comments "members read comments on readable articles" deny
select is((select count(*)::int from public.kb_article_comments where body = 'review note'), 0,
  'member cannot read comments on someone else''s draft');

-- @policy kb_article_comments "members comment on readable articles" allow
select lives_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'm1 comment')$$,
  'member can comment on a published article');

select is((select created_by from public.kb_article_comments where body = 'm1 comment'),
  '00000000-0000-0000-0000-0000000000b1'::uuid, 'author is set from the JWT');

-- @policy kb_article_comments "members comment on readable articles" allow
select lives_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'draft comment')$$,
  'member can comment on own draft');

-- @policy kb_article_comments "members read comments on readable articles" allow
select is((select count(*)::int from public.kb_article_comments where body = 'draft comment'), 1,
  'member reads comments on own draft');

-- @policy kb_article_comments "members comment on readable articles" deny
select throws_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'peek')$$,
  '42501', 'new row violates row-level security policy for table "kb_article_comments"',
  'member cannot comment on a draft they cannot read');

-- @policy kb_article_comments "members comment on readable articles" deny
select throws_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000004', 'spam')$$,
  '42501', 'new row violates row-level security policy for table "kb_article_comments"',
  'member cannot comment in a foreign workspace');

-- @policy kb_article_comments "members comment on readable articles" deny
select throws_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004', 'spam')$$,
  '42501', 'new row violates row-level security policy for table "kb_article_comments"',
  'member cannot attach a comment to a foreign article under own workspace id');

select throws_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body, created_by)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'spoof',
            '00000000-0000-0000-0000-0000000000a1')$$,
  '42501', 'permission denied for table kb_article_comments', 'author cannot be spoofed');

select throws_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body, created_at)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'old',
            now() - interval '2 hours')$$,
  '42501', 'permission denied for table kb_article_comments', 'created_at cannot be set, so comments cannot be backdated out of the quota');

select throws_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', '')$$,
  '23514', null, 'empty body is rejected');

select lives_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005', 'x')$$,
  'body of exactly 1 character is accepted');

select throws_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', E' \n\t ')$$,
  '23514', null, 'whitespace-only body is rejected');

select lives_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', repeat('b', 4000))$$,
  'body of exactly 4000 characters is accepted');

select throws_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', repeat('b', 4001))$$,
  '23514', null, 'body of 4001 characters is rejected');

-- @policy kb_article_comments "authors edit own comments" allow
select results_eq(
  $$with r as (update public.kb_article_comments set body = 'm1 edited'
               where body = 'm1 old comment' returning updated_at > created_at)
    select * from r$$,
  array[true], 'author can edit own comment, and updated_at moves');

-- @policy kb_article_comments "authors edit own comments" deny
select results_eq(
  $$with r as (update public.kb_article_comments set body = 'hacked' where body = 'm2 comment' returning 1)
    select count(*)::int from r$$,
  array[0], 'member cannot edit someone else''s comment');

select throws_ok(
  $$update public.kb_article_comments set article_id = '20000000-0000-0000-0000-000000000003'
    where body = 'm1 edited'$$,
  '42501', 'permission denied for table kb_article_comments', 'a comment cannot be moved to another article');

select throws_ok(
  $$update public.kb_article_comments set workspace_id = '10000000-0000-0000-0000-000000000002'
    where body = 'm1 edited'$$,
  '42501', 'permission denied for table kb_article_comments', 'a comment cannot be moved to another workspace');

-- @policy kb_article_comments "authors and admins delete comments" deny
select results_eq(
  $$with r as (delete from public.kb_article_comments where body = 'm2 comment' returning 1)
    select count(*)::int from r$$,
  array[0], 'member cannot delete someone else''s comment');

-- @policy kb_article_comments "authors and admins delete comments" allow
select results_eq(
  $$with r as (delete from public.kb_article_comments where body = 'm1 comment' returning 1)
    select count(*)::int from r$$,
  array[1], 'author can delete own comment');

-- Outsider (d1, owner of another workspace) -----------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);

-- @policy kb_article_comments "members read comments on readable articles" deny
select results_eq('select body from public.kb_article_comments', array['foreign comment'],
  'outsider sees only comments of own workspace');

-- @policy kb_article_comments "members comment on readable articles" deny
select throws_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'hi')$$,
  '42501', 'new row violates row-level security policy for table "kb_article_comments"',
  'outsider cannot comment on an acme article');

-- Not tagged: the read policy already hides acme comments from an outsider.
select results_eq(
  $$with r as (update public.kb_article_comments set body = 'x'
               where workspace_id = '10000000-0000-0000-0000-000000000001' returning 1)
    select count(*)::int from r$$,
  array[0], 'outsider cannot edit acme comments');

-- Not tagged: the read policy already hides acme comments from an outsider.
select results_eq(
  $$with r as (delete from public.kb_article_comments
               where workspace_id = '10000000-0000-0000-0000-000000000001' returning 1)
    select count(*)::int from r$$,
  array[0], 'outsider cannot delete acme comments');

-- An admin of another workspace who has written no comments anywhere: whatever an
-- unfiltered write reaches is a leak. Unfiltered, so the read policy cannot mask it.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000d2","role":"authenticated"}', true);

-- @policy kb_article_comments "authors edit own comments" deny
select results_eq(
  $$with r as (update public.kb_article_comments set body = 'x' returning 1)
    select count(*)::int from r$$,
  array[0], 'an admin elsewhere cannot edit any comment of another workspace');

-- @policy kb_article_comments "authors and admins delete comments" deny
select results_eq(
  $$with r as (delete from public.kb_article_comments returning 1)
    select count(*)::int from r$$,
  array[0], 'an admin elsewhere cannot delete any comment of another workspace');

-- Admin (ad) --------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000ad","role":"authenticated"}', true);

-- @policy kb_article_comments "members read comments on readable articles" allow
select results_eq(
  $$select body from public.kb_article_comments
    where article_id = '20000000-0000-0000-0000-000000000002'$$,
  array['review note'], 'admin reads comments on any draft');

-- @policy kb_article_comments "members comment on readable articles" allow
select lives_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'admin note')$$,
  'admin can comment on a member''s draft');

-- @policy kb_article_comments "authors edit own comments" allow
select results_eq(
  $$with r as (update public.kb_article_comments set body = 'review note, edited'
               where body = 'review note' returning 1)
    select count(*)::int from r$$,
  array[1], 'admin can edit own comment');

-- @policy kb_article_comments "authors edit own comments" deny
select results_eq(
  $$with r as (update public.kb_article_comments set body = 'moderated' where body = 'm2 comment' returning 1)
    select count(*)::int from r$$,
  array[0], 'admin cannot edit a member''s comment');

-- @policy kb_article_comments "authors and admins delete comments" allow
select results_eq(
  $$with r as (delete from public.kb_article_comments where body = 'm2 comment' returning 1)
    select count(*)::int from r$$,
  array[1], 'admin can delete a member''s comment');

-- @policy kb_article_comments "authors and admins delete comments" allow
select results_eq(
  $$with r as (delete from public.kb_article_comments where body = 'owner comment' returning 1)
    select count(*)::int from r$$,
  array[1], 'admin can delete the owner''s comment');

-- Owner (a1) --------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);

-- @policy kb_article_comments "authors edit own comments" deny
select results_eq(
  $$with r as (update public.kb_article_comments set body = 'moderated' where body = 'm1 edited' returning 1)
    select count(*)::int from r$$,
  array[0], 'owner cannot edit a member''s comment');

-- @policy kb_article_comments "authors and admins delete comments" allow
select results_eq(
  $$with r as (delete from public.kb_article_comments where body = 'draft comment' returning 1)
    select count(*)::int from r$$,
  array[1], 'owner can delete a comment on a member''s draft');

-- The author leaves the workspace ----------------------------------------------
reset role;
delete from public.workspace_members
where workspace_id = '10000000-0000-0000-0000-000000000001'
  and user_id = '00000000-0000-0000-0000-0000000000f5';

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000f5","role":"authenticated"}', true);

-- @policy kb_article_comments "members read comments on readable articles" deny
select is((select count(*)::int from public.kb_article_comments), 0,
  'a former member reads no comments of the workspace, own included');

-- Unfiltered on purpose: a WHERE on a column would bring in the read policy and mask
-- the write policies. f5 is in no workspace now, so nothing may change.
-- @policy kb_article_comments "authors edit own comments" deny
select results_eq(
  $$with r as (update public.kb_article_comments set body = 'x' returning 1)
    select count(*)::int from r$$,
  array[0], 'a former member cannot edit their old comment');

-- @policy kb_article_comments "authors and admins delete comments" deny
select results_eq(
  $$with r as (delete from public.kb_article_comments returning 1)
    select count(*)::int from r$$,
  array[0], 'a former member cannot delete their old comment');

reset role;
select is((select count(*)::int from public.kb_article_comments where body = 'gone comment'), 1,
  'the comment survives the author leaving');

-- The author account is deleted (as postgres) ----------------------------------
delete from auth.users where id = '00000000-0000-0000-0000-0000000000f5';

select ok((select created_by is null from public.kb_article_comments where body = 'gone comment'),
  'the comment survives account deletion, without an author');

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000ad","role":"authenticated"}', true);

-- @policy kb_article_comments "authors and admins delete comments" allow
select results_eq(
  $$with r as (delete from public.kb_article_comments where body = 'gone comment' returning 1)
    select count(*)::int from r$$,
  array[1], 'admin can delete a comment whose author account is gone');

-- Visibility follows the article (b1) ------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);

-- @policy kb_article_comments "members read comments on readable articles" allow
select is(
  (select count(*)::int from public.kb_article_comments
   where article_id = '20000000-0000-0000-0000-000000000001'),
  2, 'member sees the remaining comments while the article is published');

reset role;
update public.kb_articles set published = false where id = '20000000-0000-0000-0000-000000000001';
set local role authenticated;

-- @policy kb_article_comments "members read comments on readable articles" deny
select is(
  (select count(*)::int from public.kb_article_comments
   where article_id = '20000000-0000-0000-0000-000000000001'),
  0, 'once the article is unpublished, the member sees none of its comments, own included');

-- @policy kb_article_comments "members comment on readable articles" deny
select throws_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'late')$$,
  '42501', 'new row violates row-level security policy for table "kb_article_comments"',
  'member cannot comment on an article once it is unpublished');

-- Sets a constant and reads no column, so the read policy does not join in: only the update
-- policy keeps the two comments on art01 out. b1's comment on art05 is the allowed control.
-- @policy kb_article_comments "authors edit own comments" deny
select results_eq(
  $$with r as (update public.kb_article_comments set body = 'edited while hidden' returning 1)
    select count(*)::int from r$$,
  array[1], 'author cannot edit own comments on an article once it is unpublished');

-- Unfiltered for the same reason: only the delete policy keeps the comments on art01.
-- @policy kb_article_comments "authors and admins delete comments" deny
select results_eq(
  $$with r as (delete from public.kb_article_comments returning 1) select count(*)::int from r$$,
  array[1], 'author cannot delete own comments on an article once it is unpublished');

-- Integrity and cascades (as postgres) -----------------------------------------
reset role;

select throws_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body, created_by)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004', 'x',
            '00000000-0000-0000-0000-0000000000a1')$$,
  '23503', null, 'a comment cannot point at an article in another workspace, even without RLS');

delete from public.kb_articles where id = '20000000-0000-0000-0000-000000000001';
select is(
  (select count(*)::int from public.kb_article_comments
   where article_id = '20000000-0000-0000-0000-000000000001'),
  0, 'comments are deleted with their article');

delete from public.workspaces where id = '10000000-0000-0000-0000-000000000002';
select is((select count(*)::int from public.kb_article_comments where body = 'foreign comment'), 0,
  'comments are deleted with their workspace');

-- Quota: 100 comments per user per rolling hour --------------------------------
-- 99 comments inside the window and 51 just outside it: 50 at 61 minutes, one at exactly an
-- hour (the window is `created_at > now() - 1 hour`). A wider window, or `>=`, would count
-- them and refuse the 100th comment below. The author is written out: the JWT claims set
-- above still apply to inserts as postgres.
insert into public.kb_article_comments (workspace_id, article_id, body, created_by, created_at)
select '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005', 'old ' || g,
       '00000000-0000-0000-0000-0000000000b3', now() - interval '61 minutes'
from generate_series(1, 50) g;

insert into public.kb_article_comments (workspace_id, article_id, body, created_by, created_at)
values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005', 'edge',
        '00000000-0000-0000-0000-0000000000b3', now() - interval '1 hour');

insert into public.kb_article_comments (workspace_id, article_id, body, created_by, created_at)
select '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005', 'recent ' || g,
       '00000000-0000-0000-0000-0000000000b3', now() - interval '30 minutes'
from generate_series(1, 99) g;

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b3","role":"authenticated"}', true);

select lives_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005', 'number 100')$$,
  'the 100th comment within an hour is accepted');

select throws_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005', 'number 101')$$,
  'PT429', 'comment rate limit exceeded', 'the 101st comment within an hour is refused');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);

select lives_ok(
  $$insert into public.kb_article_comments (workspace_id, article_id, body)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005', 'b1 here')$$,
  'the quota is per user: another member is not affected');

select * from finish();
rollback;
