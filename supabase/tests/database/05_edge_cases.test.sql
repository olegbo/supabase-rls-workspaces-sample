-- Edge cases: input bounds, missing identity, quotas, revocation, cascades, account
-- deletion order, admin powers over articles, and function privileges.
begin;
create extension if not exists pgtap with schema extensions;
select plan(42);

-- Fixtures --------------------------------------------------------------------
--   acme  (w1): o1 owner, ad admin, m1 member
--   other (w2): out owner
--   duo   (w3): o1 owner, o2 owner
--   succ  (w4): x owner, y member (oldest), z admin (newest)
--   solo1 (w5), solo2 (w6): s sole member and owner of both
insert into auth.users (id, email, email_confirmed_at, is_anonymous) values
  ('00000000-0000-0000-0000-0000000000a1', 'o1@example.test',      now(), false),
  ('00000000-0000-0000-0000-0000000000a2', 'o2@example.test',      now(), false),
  ('00000000-0000-0000-0000-0000000000ad', 'ad@example.test',      now(), false),
  ('00000000-0000-0000-0000-0000000000b1', 'm1@example.test',      now(), false),
  ('00000000-0000-0000-0000-0000000000d1', 'out@example.test',     now(), false),
  ('00000000-0000-0000-0000-0000000000e1', 'joiner@example.test',  now(), false),
  ('00000000-0000-0000-0000-0000000000e2', null,                   null,  true),
  ('00000000-0000-0000-0000-0000000000e3', 'orphan@example.test',  now(), false),
  ('00000000-0000-0000-0000-0000000000f1', 'x@example.test',       now(), false),
  ('00000000-0000-0000-0000-0000000000f2', 'y@example.test',       now(), false),
  ('00000000-0000-0000-0000-0000000000f3', 'z@example.test',       now(), false),
  ('00000000-0000-0000-0000-0000000000f4', 's@example.test',       now(), false),
  ('00000000-0000-0000-0000-0000000000f5', 'gone@example.test',    now(), false);

insert into public.workspaces (id, name, slug, created_by) values
  ('10000000-0000-0000-0000-000000000001', 'Acme',  'acme',  '00000000-0000-0000-0000-0000000000a1'),
  ('10000000-0000-0000-0000-000000000002', 'Other', 'other', '00000000-0000-0000-0000-0000000000d1'),
  ('10000000-0000-0000-0000-000000000003', 'Duo',   'duo',   '00000000-0000-0000-0000-0000000000a1'),
  ('10000000-0000-0000-0000-000000000004', 'Succ',  'succ',  '00000000-0000-0000-0000-0000000000f1'),
  ('10000000-0000-0000-0000-000000000005', 'Solo1', 'solo1', '00000000-0000-0000-0000-0000000000f4'),
  ('10000000-0000-0000-0000-000000000006', 'Solo2', 'solo2', '00000000-0000-0000-0000-0000000000f4');

insert into public.workspace_members (workspace_id, user_id, role, created_at) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 'owner',  now()),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000ad', 'admin',  now()),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000b1', 'member', now()),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000f5', 'admin',  now()),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000d1', 'owner',  now()),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'owner',  now()),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a2', 'owner',  now()),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000ad', 'admin',  now()),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000f1', 'owner',  now() - interval '3 days'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000f2', 'member', now() - interval '2 days'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000f3', 'admin',  now() - interval '1 day'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000f4', 'owner',  now()),
  ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000f4', 'owner',  now());

insert into public.workspace_invites (workspace_id, email, role, token_hash, invited_by, created_at)
select '10000000-0000-0000-0000-000000000001', email, 'member',
       encode(extensions.digest(token, 'sha256'), 'hex'), inviter::uuid, now()
from (values
  ('revoke-me@example.test',  'token-revoke',  '00000000-0000-0000-0000-0000000000a1'),
  ('joiner@example.test',     'token-by-admin', '00000000-0000-0000-0000-0000000000ad'),
  ('orphan@example.test',     'token-orphan',  '00000000-0000-0000-0000-0000000000f5')
) as t (email, token, inviter);

-- 100 pending invites in "other", created long enough ago not to count for the hourly limit.
insert into public.workspace_invites (workspace_id, email, token_hash, invited_by, created_at)
select '10000000-0000-0000-0000-000000000002', 'pending' || g || '@example.test',
       encode(extensions.digest('pending' || g, 'sha256'), 'hex'),
       '00000000-0000-0000-0000-0000000000d1', now() - interval '2 hours'
from generate_series(1, 100) g;

insert into public.kb_articles (workspace_id, title, published, created_by, created_at, updated_at) values
  ('10000000-0000-0000-0000-000000000001', 'Member draft', false,
   '00000000-0000-0000-0000-0000000000b1', now() - interval '1 day', now() - interval '1 day'),
  ('10000000-0000-0000-0000-000000000001', 'Owner article', true,
   '00000000-0000-0000-0000-0000000000a1', now() - interval '1 day', now() - interval '1 day');

-- Function privileges ---------------------------------------------------------
select is(
  (select array_agg(p.proname::text order by p.proname)
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private')
     and has_function_privilege('authenticated', p.oid, 'execute')
     and p.proname not like 'pg\_%'),
  array['accept_workspace_invite', 'create_workspace', 'workspace_ids_with_role'],
  'authenticated can execute only the two RPCs and the policy helper'
);

select is(
  (select count(*)::int
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private')
     and has_function_privilege('anon', p.oid, 'execute')),
  0, 'anon can execute none of our functions'
);

set local role authenticated;

-- Missing identity ------------------------------------------------------------
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok($$select public.create_workspace('No sub', 'no-sub')$$,
  'PT401', 'not authenticated', 'create_workspace needs a user id');
select throws_ok($$select public.accept_workspace_invite('token-revoke')$$,
  'PT401', 'not authenticated', 'accept_workspace_invite needs a user id');
select is((select count(*)::int from public.workspaces), 0,
  'a JWT without sub sees no workspaces');

-- Input bounds (as o1) --------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);

select throws_ok($$select public.create_workspace('Dup', 'acme')$$, '23505', null,
  'slug must be unique');
select throws_ok($$select public.create_workspace('', 'empty-name')$$, '23514', null,
  'empty name is rejected');
select throws_ok($$select public.create_workspace(repeat('n', 201), 'long-name')$$, '23514', null,
  'name longer than 200 is rejected');
select lives_ok($$select public.create_workspace(repeat('n', 200), 'max-name')$$,
  'name of exactly 200 is accepted');
select throws_ok($$select public.create_workspace('Upper', 'Upper')$$, '23514', null,
  'uppercase slug is rejected');
select throws_ok($$select public.create_workspace('Short', 'a')$$, '23514', null,
  'one-character slug is rejected');
select throws_ok($$select public.create_workspace('Long', repeat('s', 64))$$, '23514', null,
  'slug longer than 63 is rejected');
select lives_ok($$select public.create_workspace('Max', repeat('s', 63))$$,
  'slug of exactly 63 is accepted');
select throws_ok($$select public.create_workspace('Edge', '-lead')$$, '23514', null,
  'slug cannot start with a hyphen');

select throws_ok(
  $$insert into public.workspace_invites (workspace_id, email, token_hash)
    values ('10000000-0000-0000-0000-000000000001', repeat('a', 310) || '@example.test',
            repeat('1', 64))$$,
  '23514', null, 'email longer than 320 is rejected');
select throws_ok(
  $$insert into public.workspace_invites (workspace_id, email, token_hash)
    values ('10000000-0000-0000-0000-000000000001', 'hash@example.test', 'not-a-hash')$$,
  '23514', null, 'token_hash must be 64 hex characters');
select throws_ok(
  $$update public.workspace_members set workspace_id = '10000000-0000-0000-0000-000000000002'
    where user_id = '00000000-0000-0000-0000-0000000000b1'$$,
  '42501', null, 'membership cannot be moved to another workspace');

-- Invite revocation -----------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
select results_eq(
  $$with r as (delete from public.workspace_invites where email = 'revoke-me@example.test' returning 1)
    select count(*)::int from r$$,
  array[0], 'member cannot revoke an invite');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);
select results_eq(
  $$with r as (delete from public.workspace_invites where email = 'revoke-me@example.test' returning 1)
    select count(*)::int from r$$,
  array[0], 'owner of another workspace cannot revoke it');

select throws_ok(
  $$insert into public.workspace_invites (workspace_id, email, token_hash)
    values ('10000000-0000-0000-0000-000000000002', 'pending101@example.test', repeat('2', 64))$$,
  'PT429', 'too many pending invites', 'pending invites per workspace are capped at 100');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000ad","role":"authenticated"}', true);
select results_eq(
  $$with r as (delete from public.workspace_invites where email = 'revoke-me@example.test' returning 1)
    select count(*)::int from r$$,
  array[1], 'admin can revoke an invite');

-- Invite acceptance edge cases ------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000e1","role":"authenticated"}', true);
select throws_ok($$select public.accept_workspace_invite(null)$$,
  'PT400', 'invite is invalid or expired', 'null token is rejected');
select throws_ok($$select public.accept_workspace_invite('')$$,
  'PT400', 'invite is invalid or expired', 'empty token is rejected');
select is(public.accept_workspace_invite('token-by-admin'),
  '10000000-0000-0000-0000-000000000001'::uuid,
  'a member invite from a current admin can be accepted');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000e2","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.accept_workspace_invite('token-orphan')$$,
  'PT403', 'email is not confirmed', 'anonymous user cannot accept');

-- Inviter's account is deleted: the invite row stays, but can no longer be used.
reset role;
delete from auth.users where id = '00000000-0000-0000-0000-0000000000f5';
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000e3","role":"authenticated"}', true);
select throws_ok($$select public.accept_workspace_invite('token-orphan')$$,
  'PT400', 'invite is invalid or expired', 'invite from a deleted inviter is rejected');

-- Owner guard: bulk demotion in one statement ---------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select throws_ok(
  $$update public.workspace_members set role = 'admin'
    where workspace_id = '10000000-0000-0000-0000-000000000003' and role = 'owner'$$,
  'PT409', 'workspace must keep at least one owner',
  'demoting every owner in one statement is refused');
select results_eq(
  $$with r as (update public.workspace_members set role = 'owner'
               where workspace_id = '10000000-0000-0000-0000-000000000003'
                 and user_id = '00000000-0000-0000-0000-0000000000a1' returning 1)
    select count(*)::int from r$$,
  array[1], 'a no-op owner-to-owner update passes the guard');

-- Articles: admin powers and bounds -------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
select results_eq(
  $$with r as (update public.kb_articles set published = false where title = 'Owner article' returning 1)
    select count(*)::int from r$$,
  array[0], 'member cannot unpublish an article of someone else');
select throws_ok(
  $$insert into public.kb_articles (workspace_id, title) values ('10000000-0000-0000-0000-000000000001', '')$$,
  '23514', null, 'empty title is rejected');
select throws_ok(
  $$insert into public.kb_articles (workspace_id, title, body)
    values ('10000000-0000-0000-0000-000000000001', 'Huge', repeat('b', 100001))$$,
  '23514', null, 'body over 100000 characters is rejected');
select results_eq(
  $$with r as (update public.kb_articles set body = 'v2' where title = 'Member draft'
               returning updated_at > now() - interval '1 minute')
    select * from r$$,
  array[true], 'updated_at is refreshed on update');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000ad","role":"authenticated"}', true);
select results_eq('select title from public.kb_articles order by title',
  array['Member draft', 'Owner article'], 'admin sees drafts of members');
select results_eq(
  $$with r as (update public.kb_articles set title = 'Edited by admin' where title = 'Owner article' returning 1)
    select count(*)::int from r$$,
  array[1], 'admin can edit an article of the owner');
select results_eq(
  $$with r as (delete from public.kb_articles where title = 'Member draft' returning 1)
    select count(*)::int from r$$,
  array[1], 'admin can delete an article of a member');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);
select throws_ok(
  $$insert into public.kb_articles (workspace_id, title) values ('10000000-0000-0000-0000-000000000001', 'Spam')$$,
  '42501', null, 'outsider cannot write articles');

-- Workspace deletion cascades -------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select results_eq(
  $$with r as (delete from public.workspace_members
               where workspace_id = '10000000-0000-0000-0000-000000000001'
                 and user_id = '00000000-0000-0000-0000-0000000000ad' returning 1)
    select count(*)::int from r$$,
  array[1], 'owner can remove an admin');
select results_eq(
  $$with r as (delete from public.workspaces where slug = 'acme' returning 1)
    select count(*)::int from r$$,
  array[1], 'owner can delete the workspace');

reset role;
select is(
  (select count(*)::int from public.workspace_members where workspace_id = '10000000-0000-0000-0000-000000000001')
  + (select count(*)::int from public.workspace_invites where workspace_id = '10000000-0000-0000-0000-000000000001')
  + (select count(*)::int from public.kb_articles where workspace_id = '10000000-0000-0000-0000-000000000001'),
  0, 'members, invites and articles go with the workspace');

-- Account deletion order ------------------------------------------------------
delete from auth.users where id = '00000000-0000-0000-0000-0000000000a1';
select results_eq(
  $$select user_id::text || ':' || role from public.workspace_members
    where workspace_id = '10000000-0000-0000-0000-000000000003' order by user_id$$,
  array['00000000-0000-0000-0000-0000000000a2:owner', '00000000-0000-0000-0000-0000000000ad:admin'],
  'with a co-owner left, nobody is promoted');

delete from auth.users where id = '00000000-0000-0000-0000-0000000000f1';
select results_eq(
  $$select user_id::text || ':' || role from public.workspace_members
    where workspace_id = '10000000-0000-0000-0000-000000000004' order by user_id$$,
  array['00000000-0000-0000-0000-0000000000f2:member', '00000000-0000-0000-0000-0000000000f3:owner'],
  'an admin is preferred over a longer-standing member');

delete from auth.users where id = '00000000-0000-0000-0000-0000000000f4';
select is(
  (select count(*)::int from public.workspaces where slug in ('solo1', 'solo2')),
  0, 'every workspace the user was the only member of is deleted');

select * from finish();
rollback;
