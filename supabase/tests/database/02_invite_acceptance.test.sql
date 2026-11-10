-- accept_workspace_invite(): single use, expiry, email binding, inviter authority,
-- plus the invite insert trigger (re-invite after expiry, quotas).
begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.test',      now()),
  ('00000000-0000-0000-0000-00000000000b', 'admin@example.test',      now()),
  ('00000000-0000-0000-0000-0000000000e1', 'invitee@example.test',    now()),
  ('00000000-0000-0000-0000-0000000000e2', 'intruder@example.test',   now()),
  ('00000000-0000-0000-0000-0000000000e3', 'late@example.test',       now()),
  ('00000000-0000-0000-0000-0000000000e4', 'unverified@example.test', null),
  ('00000000-0000-0000-0000-0000000000e5', 'orphan@example.test',     now()),
  ('00000000-0000-0000-0000-0000000000e6', 'existing@example.test',   now());

insert into public.workspaces (id, name, slug, created_by) values
  ('10000000-0000-0000-0000-000000000001', 'Acme', 'acme', '00000000-0000-0000-0000-00000000000a');
insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'owner'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b', 'admin'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000e6', 'member');

insert into public.workspace_invites (workspace_id, email, role, token_hash, invited_by, expires_at)
select '10000000-0000-0000-0000-000000000001', email, role::public.workspace_role,
       encode(extensions.digest(token, 'sha256'), 'hex'), inviter::uuid, expires_at
from (values
  ('INVITEE@example.test',    'token-valid',      'admin',  '00000000-0000-0000-0000-00000000000a', now() + interval '1 day'),
  ('late@example.test',       'token-expired',    'member', '00000000-0000-0000-0000-00000000000a', now() - interval '1 minute'),
  ('unverified@example.test', 'token-unverified', 'member', '00000000-0000-0000-0000-00000000000a', now() + interval '1 day'),
  ('orphan@example.test',     'token-orphan',     'member', '00000000-0000-0000-0000-00000000000b', now() + interval '1 day'),
  ('existing@example.test',   'token-existing',   'member', '00000000-0000-0000-0000-00000000000a', now() + interval '1 day')
) as t (email, token, role, inviter, expires_at);

set local role authenticated;

-- Wrong user cannot use someone else's token.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000e2","role":"authenticated"}', true);
select throws_ok($$select public.accept_workspace_invite('token-valid')$$,
  'PT400', 'invite is invalid or expired', 'invite is bound to the invited email');

select throws_ok($$select public.accept_workspace_invite('no-such-token')$$,
  'PT400', 'invite is invalid or expired', 'unknown token gives the same generic error');

-- Expired.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000e3","role":"authenticated"}', true);
select throws_ok($$select public.accept_workspace_invite('token-expired')$$,
  'PT400', 'invite is invalid or expired', 'expired invite is rejected');

-- Unconfirmed email.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000e4","role":"authenticated"}', true);
select throws_ok($$select public.accept_workspace_invite('token-unverified')$$,
  'PT403', 'email is not confirmed', 'unconfirmed email cannot accept');

-- Inviter lost authority: the admin who invited is demoted before acceptance.
reset role;
update public.workspace_members set role = 'member'
  where user_id = '00000000-0000-0000-0000-00000000000b';
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000e5","role":"authenticated"}', true);
select throws_ok($$select public.accept_workspace_invite('token-orphan')$$,
  'PT400', 'invite is invalid or expired', 'invite dies with the inviter''s authority');

-- Happy path (stored email differs in case from the account email).
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000e1","role":"authenticated"}', true);
select is(public.accept_workspace_invite('token-valid'),
  '10000000-0000-0000-0000-000000000001'::uuid, 'invitee joins the workspace');

select is(
  (select role::text from public.workspace_members
   where user_id = '00000000-0000-0000-0000-0000000000e1'),
  'admin', 'invitee gets the invited role');

select results_eq('select slug from public.workspaces', array['acme'],
  'new member can read the workspace');

select throws_ok($$select public.accept_workspace_invite('token-valid')$$,
  'PT400', 'invite is invalid or expired', 'invite is single use');

-- Existing member accepting a lower-role invite keeps their role.
reset role;
update public.workspace_members set role = 'admin'
  where user_id = '00000000-0000-0000-0000-0000000000e6';
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000e6","role":"authenticated"}', true);
select lives_ok($$select public.accept_workspace_invite('token-existing')$$,
  'existing member can accept an invite');
select is(
  (select role::text from public.workspace_members
   where user_id = '00000000-0000-0000-0000-0000000000e6'),
  'admin', 'accepting never downgrades an existing role');

-- Insert trigger: duplicates, re-invite after expiry, rate limit -----------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);

select throws_ok(
  $$insert into public.workspace_invites (workspace_id, email, token_hash)
    values ('10000000-0000-0000-0000-000000000001', 'Unverified@example.test', repeat('c', 64))$$,
  '23505', null, 'a second pending invite for the same email is rejected (case-insensitive)');

select lives_ok(
  $$insert into public.workspace_invites (workspace_id, email, token_hash)
    values ('10000000-0000-0000-0000-000000000001', 'LATE@example.test', repeat('d', 64))$$,
  'an expired invite does not block re-inviting');

select is(
  (select count(*)::int from public.workspace_invites where email = 'late@example.test'),
  1, 'the expired invite was replaced');

select throws_ok(
  $$insert into public.workspace_invites (workspace_id, email, token_hash)
    values ('10000000-0000-0000-0000-000000000001', 'not-an-email', repeat('e', 64))$$,
  '23514', null, 'invite email must look like an address');

-- Fill the owner's hourly quota of 20 invites and expect the next one to be refused.
select lives_ok(
  $$insert into public.workspace_invites (workspace_id, email, token_hash)
    select '10000000-0000-0000-0000-000000000001', 'bulk' || g || '@example.test',
           encode(extensions.digest('bulk' || g, 'sha256'), 'hex')
    from generate_series(1, 20 - (select count(*)::int from public.workspace_invites
                                  where invited_by = '00000000-0000-0000-0000-00000000000a'
                                    and created_at > now() - interval '1 hour')) g$$,
  'invites up to the hourly limit are accepted');

select throws_ok(
  $$insert into public.workspace_invites (workspace_id, email, token_hash)
    values ('10000000-0000-0000-0000-000000000001', 'one-too-many@example.test', repeat('f', 64))$$,
  'PT429', 'invite rate limit exceeded', 'hourly invite limit is enforced');

-- Anonymous callers cannot execute the RPCs at all.
reset role;
set local role anon;
select throws_ok($$select public.accept_workspace_invite('token-valid')$$, '42501', null,
  'anon cannot call accept_workspace_invite');

reset role;
select is(
  (select count(*)::int from public.workspace_invites where email = 'one-too-many@example.test'),
  0, 'rejected invite left no row');

select * from finish();
rollback;
