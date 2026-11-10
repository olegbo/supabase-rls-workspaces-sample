-- RLS, grants and role hierarchy for workspaces, members and invites.
--
-- Denied UPDATE/DELETE statements do not raise under RLS, they just touch no rows, so
-- those cases assert the affected-row count and are paired with a positive control
-- (the same statement by an authorized role touching exactly one row).
begin;
create extension if not exists pgtap with schema extensions;
select plan(48);

-- Fixtures (run as postgres, RLS does not apply) ------------------------------
--   a owner, b admin, f admin, c member, g member, h member  -> acme
--   d owner                                                  -> other
insert into auth.users (id, email, email_confirmed_at, is_anonymous) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.test',    now(), false),
  ('00000000-0000-0000-0000-00000000000b', 'admin@example.test',    now(), false),
  ('00000000-0000-0000-0000-00000000000f', 'admin2@example.test',   now(), false),
  ('00000000-0000-0000-0000-00000000000c', 'member@example.test',   now(), false),
  ('00000000-0000-0000-0000-0000000000c2', 'member2@example.test',  now(), false),
  ('00000000-0000-0000-0000-0000000000c3', 'member3@example.test',  now(), false),
  ('00000000-0000-0000-0000-00000000000d', 'outsider@example.test', now(), false),
  ('00000000-0000-0000-0000-0000000000e1', 'pending@example.test',  null,  false),
  ('00000000-0000-0000-0000-0000000000e2', null,                    null,  true);

insert into public.workspaces (id, name, slug, created_by) values
  ('10000000-0000-0000-0000-000000000001', 'Acme', 'acme', '00000000-0000-0000-0000-00000000000a'),
  ('10000000-0000-0000-0000-000000000002', 'Other', 'other', '00000000-0000-0000-0000-00000000000d');

-- c already created 9 workspaces (no membership), one below the quota of 10.
insert into public.workspaces (name, slug, created_by)
select 'Q' || g, 'quota-' || g, '00000000-0000-0000-0000-00000000000c'
from generate_series(1, 9) g;

insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'owner'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b', 'admin'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000f', 'admin'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000c', 'member'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000c2', 'member'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000c3', 'member'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000d', 'owner');

insert into public.workspace_invites (workspace_id, email, role, token_hash, invited_by) values
  ('10000000-0000-0000-0000-000000000001', 'first@example.test', 'member', repeat('a', 64),
   '00000000-0000-0000-0000-00000000000a'),
  ('10000000-0000-0000-0000-000000000002', 'x@example.test', 'member', repeat('b', 64),
   '00000000-0000-0000-0000-00000000000d');

-- Schema-level guarantees -----------------------------------------------------
select ok(
  (select bool_and(c.relrowsecurity)
   from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'),
  'RLS is enabled on every public table'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
   where grantee = 'anon' and table_schema = 'public'),
  0, 'anon has no table privileges'
);

select is(
  (select count(*)::int from information_schema.column_privileges
   where grantee = 'anon' and table_schema = 'public'),
  0, 'anon has no column privileges'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
   where grantee = 'authenticated' and table_schema = 'public'
     and privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER')),
  0, 'authenticated has no TRUNCATE, REFERENCES or TRIGGER'
);

select ok(
  not has_schema_privilege('anon', 'private', 'usage')
  and not has_function_privilege('anon',
    'private.workspace_ids_with_role(public.workspace_role)', 'execute'),
  'anon cannot reach the private policy helpers'
);

-- Anonymous -------------------------------------------------------------------
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

select throws_ok('select * from public.workspaces', '42501', null,
  'anon cannot read workspaces');

select throws_ok($$select public.create_workspace('Anon', 'anon-ws')$$, '42501', null,
  'anon cannot call create_workspace');

-- Member ----------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000000c","role":"authenticated"}', true);

select results_eq('select slug from public.workspaces', array['acme'],
  'member sees only own workspace');

select results_eq(
  'select user_id::text from public.workspace_members order by user_id',
  array[
    '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b',
    '00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-00000000000f',
    '00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000c3'
  ],
  'member sees exactly the members of own workspace'
);

select is((select count(*)::int from public.workspace_invites), 0,
  'member cannot see invites (acme has one, checked as admin below)');

select throws_ok(
  $$insert into public.workspace_invites (workspace_id, email, token_hash)
    values ('10000000-0000-0000-0000-000000000001', 'new@example.test', repeat('c', 64))$$,
  '42501', null, 'member cannot invite');

select results_eq(
  $$with r as (update public.workspaces set name = 'Hacked' where slug = 'acme' returning 1)
    select count(*)::int from r$$,
  array[0], 'member cannot rename workspace');

select results_eq(
  $$with r as (update public.workspace_members set role = 'admin'
               where user_id = '00000000-0000-0000-0000-00000000000c' returning 1)
    select count(*)::int from r$$,
  array[0], 'member cannot promote self');

select results_eq(
  $$with r as (delete from public.workspace_members
               where user_id = '00000000-0000-0000-0000-0000000000c2' returning 1)
    select count(*)::int from r$$,
  array[0], 'member cannot remove another member');

select throws_ok($$insert into public.workspaces (name, slug) values ('Direct', 'direct')$$,
  '42501', null, 'direct workspace insert is not allowed');

-- Member h leaves.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000c3","role":"authenticated"}', true);
select results_eq(
  $$with r as (delete from public.workspace_members
               where user_id = '00000000-0000-0000-0000-0000000000c3' returning 1)
    select count(*)::int from r$$,
  array[1], 'member can leave');

-- Admin -----------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);

select lives_ok(
  $$insert into public.workspace_invites (workspace_id, email, token_hash)
    values ('10000000-0000-0000-0000-000000000001', 'new@example.test', repeat('c', 64))$$,
  'admin can invite a member');

select throws_ok(
  $$insert into public.workspace_invites (workspace_id, email, role, token_hash)
    values ('10000000-0000-0000-0000-000000000001', 'boss@example.test', 'admin', repeat('d', 64))$$,
  '42501', null, 'admin cannot invite an admin');

select throws_ok(
  $$insert into public.workspace_invites (workspace_id, email, token_hash)
    values ('10000000-0000-0000-0000-000000000002', 'new@example.test', repeat('e', 64))$$,
  '42501', null, 'admin cannot invite to a foreign workspace');

select throws_ok(
  $$insert into public.workspace_invites (workspace_id, email, token_hash, invited_by)
    values ('10000000-0000-0000-0000-000000000001', 'spoof@example.test', repeat('f', 64),
            '00000000-0000-0000-0000-00000000000a')$$,
  '42501', null, 'inviter cannot be spoofed');

select throws_ok('select token_hash from public.workspace_invites', '42501', null,
  'token_hash is not readable by clients');

select results_eq(
  'select email::text from public.workspace_invites order by email',
  array['first@example.test', 'new@example.test'],
  'admin sees exactly the invites of own workspace');

select results_eq(
  $$with r as (update public.workspace_members set role = 'admin'
               where user_id = '00000000-0000-0000-0000-00000000000c' returning 1)
    select count(*)::int from r$$,
  array[0], 'admin cannot change roles');

select results_eq(
  $$with r as (delete from public.workspace_members
               where user_id = '00000000-0000-0000-0000-00000000000f' returning 1)
    select count(*)::int from r$$,
  array[0], 'admin cannot remove another admin');

select results_eq(
  $$with r as (delete from public.workspace_members
               where user_id = '00000000-0000-0000-0000-00000000000a' returning 1)
    select count(*)::int from r$$,
  array[0], 'admin cannot remove the owner');

select results_eq(
  $$with r as (delete from public.workspace_members
               where user_id = '00000000-0000-0000-0000-0000000000c2' returning 1)
    select count(*)::int from r$$,
  array[1], 'admin can remove a member');

select results_eq(
  $$with r as (update public.workspaces set name = 'Acme Inc' where slug = 'acme' returning 1)
    select count(*)::int from r$$,
  array[1], 'admin can rename workspace');

select throws_ok($$update public.workspaces set slug = 'renamed' where slug = 'acme'$$,
  '42501', null, 'slug is not updatable by clients');

select results_eq(
  $$with r as (delete from public.workspaces where slug = 'acme' returning 1)
    select count(*)::int from r$$,
  array[0], 'admin cannot delete workspace');

-- Owner -----------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);

select throws_ok(
  $$insert into public.workspace_invites (workspace_id, email, role, token_hash)
    values ('10000000-0000-0000-0000-000000000001', 'boss@example.test', 'owner', repeat('1', 64))$$,
  '23514', null, 'invites cannot grant ownership');

select lives_ok(
  $$insert into public.workspace_invites (workspace_id, email, role, token_hash)
    values ('10000000-0000-0000-0000-000000000001', 'boss@example.test', 'admin', repeat('2', 64))$$,
  'owner can invite an admin');

select results_eq(
  $$with r as (update public.workspace_members set role = 'member'
               where user_id = '00000000-0000-0000-0000-00000000000f' returning 1)
    select count(*)::int from r$$,
  array[1], 'owner can demote an admin');

select throws_ok(
  $$delete from public.workspace_members where user_id = '00000000-0000-0000-0000-00000000000a'$$,
  'PT409', 'workspace must keep at least one owner', 'last owner cannot leave');

select throws_ok(
  $$update public.workspace_members set role = 'admin'
    where user_id = '00000000-0000-0000-0000-00000000000a'$$,
  'PT409', 'workspace must keep at least one owner', 'last owner cannot demote self');

select results_eq(
  $$with r as (update public.workspace_members set role = 'owner'
               where user_id = '00000000-0000-0000-0000-00000000000b' returning 1)
    select count(*)::int from r$$,
  array[1], 'owner can transfer ownership');

select results_eq(
  $$with r as (delete from public.workspace_members
               where user_id = '00000000-0000-0000-0000-00000000000a' returning 1)
    select count(*)::int from r$$,
  array[1], 'former owner can leave once another owner exists');

-- RPC: create_workspace -------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000000c","role":"authenticated"}', true);

select throws_ok($$select public.create_workspace('Bad', 'a--')$$, '23514', null,
  'malformed slug is rejected');

select throws_ok($$select public.create_workspace('Bad', 'admin')$$, '23514', null,
  'reserved slug is rejected');

select isnt(public.create_workspace('Side Project', 'side-project'), null,
  'confirmed user can create a workspace');

select is(
  (select m.role::text from public.workspace_members m
   join public.workspaces w on w.id = m.workspace_id
   where w.slug = 'side-project' and m.user_id = '00000000-0000-0000-0000-00000000000c'),
  'owner', 'creator becomes owner atomically');

select throws_ok($$select public.create_workspace('One more', 'one-more')$$,
  'PT429', 'workspace limit reached', 'workspace quota is enforced');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000e1","role":"authenticated"}', true);
select throws_ok($$select public.create_workspace('Pending', 'pending-ws')$$,
  'PT403', 'email is not confirmed', 'unconfirmed user cannot create a workspace');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000e2","role":"authenticated","is_anonymous":true}', true);
select throws_ok($$select public.create_workspace('Anon', 'anon-ws')$$,
  'PT403', 'email is not confirmed', 'anonymous user cannot create a workspace');

-- Account deletion (as postgres) ----------------------------------------------
-- acme now: b owner, f member, c member. b is the sole owner.
reset role;

select lives_ok($$delete from auth.users where id = '00000000-0000-0000-0000-00000000000b'$$,
  'sole owner account can be deleted');

select results_eq(
  $$select m.user_id::text from public.workspace_members m
    where m.workspace_id = '10000000-0000-0000-0000-000000000001' and m.role = 'owner'$$,
  array['00000000-0000-0000-0000-00000000000c'],
  'ownership passes to the longest-standing remaining member');

select lives_ok($$delete from auth.users where id = '00000000-0000-0000-0000-00000000000d'$$,
  'owner of a single-person workspace can be deleted');

select is(
  (select count(*)::int from public.workspaces
   where id = '10000000-0000-0000-0000-000000000002'),
  0, 'a workspace left with no members is deleted');

select results_eq(
  $$select email::text from public.workspace_invites
    where workspace_id = '10000000-0000-0000-0000-000000000001' and invited_by is null$$,
  array['new@example.test'],
  'invite rows stay as audit trail when the inviter account is deleted');

select * from finish();
rollback;
