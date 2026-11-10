-- Multi-tenant core: workspaces, role-based membership and email invites.
--
-- Security model:
--   * Every table has RLS enabled; nothing is reachable without a policy.
--   * Table privileges are granted explicitly per column/command (least privilege);
--     `anon` gets nothing.
--   * Policy helpers live in the non-exposed `private` schema, run as SECURITY DEFINER
--     with an empty search_path, and are wrapped in `array(select ...)` so they run once
--     per statement and the planner can still use an index on workspace_id.
--   * Role hierarchy is strict: an actor manages only roles below their own.
--     Owners manage everyone; admins manage members; members manage themselves.
--   * Multi-row invariants (create workspace + owner, accept invite, last owner, account
--     deletion) are enforced in the database, not in the client.
--
-- Custom SQLSTATEs follow PostgREST's PTxxx convention, so RPC errors map to HTTP codes:
--   PT400 invalid or expired invite, PT401 not signed in, PT403 email not confirmed,
--   PT409 last owner, PT429 quota exceeded.

create extension if not exists citext with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- Declaration order matters: enum comparison (`>=`) follows it.
create type public.workspace_role as enum ('member', 'admin', 'owner');

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.workspaces (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 1 and 200),
  slug       text not null unique check (
    char_length(slug) between 2 and 63
    and slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
    and slug not in ('admin', 'api', 'app', 'auth', 'invites', 'settings', 'support', 'www')
  ),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

create index workspaces_created_by_idx on public.workspaces (created_by);

create table public.workspace_members (
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  user_id      uuid not null references auth.users (id) on delete cascade,
  role         public.workspace_role not null default 'member',
  created_at   timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

-- Serves the policy helper as an index-only scan; the PK covers lookups by workspace_id.
create index workspace_members_user_id_idx
  on public.workspace_members (user_id, workspace_id) include (role);

create table public.workspace_invites (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  email        extensions.citext not null check (
    char_length(email::text) <= 320 and email::text ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
  ),
  role         public.workspace_role not null default 'member' check (role <> 'owner'),
  -- Only the SHA-256 of the invite token is stored; the raw token lives in the email link.
  token_hash   text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  -- Kept as an audit trail when the inviter's account is deleted.
  invited_by   uuid default auth.uid() references auth.users (id) on delete set null,
  expires_at   timestamptz not null default now() + interval '7 days',
  accepted_at  timestamptz,
  created_at   timestamptz not null default now()
);

create index workspace_invites_workspace_id_idx on public.workspace_invites (workspace_id);
create index workspace_invites_invited_by_idx
  on public.workspace_invites (invited_by, created_at);

-- At most one pending invite per email and workspace. Expired ones are purged on insert.
create unique index workspace_invites_pending_email_idx
  on public.workspace_invites (workspace_id, email)
  where accepted_at is null;

-- Drop whatever the platform's default privileges granted (on hosted projects that is
-- everything, including TRUNCATE, which bypasses RLS). Explicit grants follow below.
revoke all on public.workspaces, public.workspace_members, public.workspace_invites
  from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Policy helpers
-- ---------------------------------------------------------------------------

-- Workspaces where the current user holds at least `min_role`.
-- SECURITY DEFINER avoids recursive RLS evaluation on workspace_members.
create function private.workspace_ids_with_role(min_role public.workspace_role)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.workspace_id
  from public.workspace_members m
  where m.user_id = (select auth.uid())
    and m.role >= min_role
$$;

revoke all on function private.workspace_ids_with_role from public;
grant execute on function private.workspace_ids_with_role to authenticated;

-- ---------------------------------------------------------------------------
-- RLS: workspaces
-- ---------------------------------------------------------------------------

alter table public.workspaces enable row level security;

create policy "members read their workspaces"
  on public.workspaces for select to authenticated
  using (id = any (array(select private.workspace_ids_with_role('member'))));

create policy "admins rename workspaces"
  on public.workspaces for update to authenticated
  using (id = any (array(select private.workspace_ids_with_role('admin'))))
  with check (id = any (array(select private.workspace_ids_with_role('admin'))));

create policy "owners delete workspaces"
  on public.workspaces for delete to authenticated
  using (id = any (array(select private.workspace_ids_with_role('owner'))));

-- INSERT goes through create_workspace() so the owner membership is created atomically.
grant select, delete on public.workspaces to authenticated;
grant update (name) on public.workspaces to authenticated;

-- ---------------------------------------------------------------------------
-- RLS: workspace_members
-- ---------------------------------------------------------------------------

alter table public.workspace_members enable row level security;

create policy "members read co-members"
  on public.workspace_members for select to authenticated
  using (workspace_id = any (array(select private.workspace_ids_with_role('member'))));

-- Only owners change roles (including granting or transferring ownership).
create policy "owners change roles"
  on public.workspace_members for update to authenticated
  using (workspace_id = any (array(select private.workspace_ids_with_role('owner'))))
  with check (workspace_id = any (array(select private.workspace_ids_with_role('owner'))));

-- Owners remove anyone, admins remove members, everyone can leave.
create policy "members leave, managers remove lower roles"
  on public.workspace_members for delete to authenticated
  using (
    user_id = (select auth.uid())
    or workspace_id = any (array(select private.workspace_ids_with_role('owner')))
    or (
      role = 'member'
      and workspace_id = any (array(select private.workspace_ids_with_role('admin')))
    )
  );

-- INSERT happens only via create_workspace() / accept_workspace_invite().
grant select, delete on public.workspace_members to authenticated;
grant update (role) on public.workspace_members to authenticated;

-- A workspace must always keep at least one owner.
create function private.ensure_workspace_has_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.role <> 'owner' or (tg_op = 'UPDATE' and new.role = 'owner') then
    return coalesce(new, old);
  end if;

  -- The lock below serializes owner changes per workspace, and the check after it relies
  -- on a fresh snapshot. REPEATABLE READ would reuse the old one (write skew), so refuse it;
  -- READ COMMITTED (the PostgREST default) and SERIALIZABLE are both safe.
  if current_setting('transaction_isolation') = 'repeatable read' then
    raise exception 'owner changes require read committed or serializable isolation'
      using errcode = '25001';
  end if;

  -- NO KEY UPDATE serializes concurrent owner changes without blocking FK checks from
  -- inserts into child tables. A missing row means ON DELETE CASCADE of the workspace.
  perform 1 from public.workspaces w where w.id = old.workspace_id for no key update;
  if not found then
    return old;
  end if;

  if not exists (
    select 1
    from public.workspace_members m
    where m.workspace_id = old.workspace_id
      and m.role = 'owner'
      and m.user_id <> old.user_id
  ) then
    raise exception 'workspace must keep at least one owner'
      using errcode = 'PT409', hint = 'Transfer ownership before leaving or demoting.';
  end if;

  return coalesce(new, old);
end
$$;

-- Functions are executable by PUBLIC by default; trigger functions need no grant.
revoke all on function private.ensure_workspace_has_owner from public;

create trigger workspace_members_keep_owner
  before update of role or delete on public.workspace_members
  for each row execute function private.ensure_workspace_has_owner();

-- Account deletion: before a user row goes, hand each workspace they solely own to the
-- longest-standing admin (or member, if there is no admin). A workspace with no one
-- else in it is deleted. Without this, the last-owner guard would block the deletion.
create function private.hand_over_owned_workspaces()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  ws uuid;
  successor uuid;
begin
  for ws in
    select m.workspace_id
    from public.workspace_members m
    where m.user_id = old.id
      and m.role = 'owner'
      and not exists (
        select 1 from public.workspace_members o
        where o.workspace_id = m.workspace_id and o.role = 'owner' and o.user_id <> old.id
      )
  loop
    select m.user_id into successor
    from public.workspace_members m
    where m.workspace_id = ws and m.user_id <> old.id
    order by m.role desc, m.created_at, m.user_id
    limit 1;

    if successor is null then
      delete from public.workspaces where id = ws;
    else
      update public.workspace_members
      set role = 'owner'
      where workspace_id = ws and user_id = successor;
    end if;
  end loop;

  return old;
end
$$;

-- Functions are executable by PUBLIC by default; trigger functions need no grant.
revoke all on function private.hand_over_owned_workspaces from public;

create trigger on_auth_user_deleted_hand_over_workspaces
  before delete on auth.users
  for each row execute function private.hand_over_owned_workspaces();

-- ---------------------------------------------------------------------------
-- RLS: workspace_invites
-- ---------------------------------------------------------------------------

alter table public.workspace_invites enable row level security;

create policy "admins read invites"
  on public.workspace_invites for select to authenticated
  using (workspace_id = any (array(select private.workspace_ids_with_role('admin'))));

-- Admins invite members; inviting an admin takes an owner.
create policy "admins invite lower roles"
  on public.workspace_invites for insert to authenticated
  with check (
    invited_by = (select auth.uid())
    and (
      workspace_id = any (array(select private.workspace_ids_with_role('owner')))
      or (
        role = 'member'
        and workspace_id = any (array(select private.workspace_ids_with_role('admin')))
      )
    )
  );

create policy "admins revoke invites"
  on public.workspace_invites for delete to authenticated
  using (workspace_id = any (array(select private.workspace_ids_with_role('admin'))));

-- token_hash is write-only for clients; invited_by and expires_at are server-set.
grant select (id, workspace_id, email, role, invited_by, expires_at, accepted_at, created_at)
  on public.workspace_invites to authenticated;
grant insert (workspace_id, email, role, token_hash)
  on public.workspace_invites to authenticated;
grant delete on public.workspace_invites to authenticated;

-- Quotas and housekeeping for new invites. Runs before the RLS check, so it does nothing
-- for callers who are not admins of the workspace and leaves the rejection to RLS.
create function private.before_invite_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not new.workspace_id = any (array(select private.workspace_ids_with_role('admin'))) then
    return new;
  end if;

  if (
    select count(*) from public.workspace_invites i
    where i.invited_by = new.invited_by and i.created_at > now() - interval '1 hour'
  ) >= 20 then
    raise exception 'invite rate limit exceeded' using errcode = 'PT429';
  end if;

  -- An expired pending invite would otherwise block re-inviting the same address.
  -- The citext operator is named explicitly: with an empty search_path a bare `=`
  -- resolves to case-sensitive text equality.
  delete from public.workspace_invites i
  where i.workspace_id = new.workspace_id
    and i.email operator(extensions.=) new.email
    and i.accepted_at is null
    and i.expires_at < now();

  if (
    select count(*) from public.workspace_invites i
    where i.workspace_id = new.workspace_id and i.accepted_at is null
  ) >= 100 then
    raise exception 'too many pending invites' using errcode = 'PT429';
  end if;

  return new;
end
$$;

-- Functions are executable by PUBLIC by default; trigger functions need no grant.
revoke all on function private.before_invite_insert from public;

create trigger workspace_invites_before_insert
  before insert on public.workspace_invites
  for each row execute function private.before_invite_insert();

-- ---------------------------------------------------------------------------
-- RPC
-- ---------------------------------------------------------------------------

-- Confirmed, non-anonymous users only; at most 10 workspaces per creator.
create function public.create_workspace(workspace_name text, workspace_slug text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  new_id uuid;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = 'PT401';
  end if;

  if not exists (
    select 1 from auth.users u
    where u.id = uid and u.email_confirmed_at is not null and not u.is_anonymous
  ) then
    raise exception 'email is not confirmed' using errcode = 'PT403';
  end if;

  if (select count(*) from public.workspaces w where w.created_by = uid) >= 10 then
    raise exception 'workspace limit reached' using errcode = 'PT429';
  end if;

  insert into public.workspaces (name, slug, created_by)
  values (workspace_name, workspace_slug, uid)
  returning id into new_id;

  insert into public.workspace_members (workspace_id, user_id, role)
  values (new_id, uid, 'owner');

  return new_id;
end
$$;

revoke all on function public.create_workspace from public, anon;
grant execute on function public.create_workspace to authenticated;

-- Accepts an invite for the caller's confirmed email. Single use and expiring; the
-- inviter must still hold the authority to grant the role. Idempotent for existing
-- members (keeps the higher role).
create function public.accept_workspace_invite(invite_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  caller_email text;
  inv public.workspace_invites%rowtype;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = 'PT401';
  end if;

  select u.email into caller_email
  from auth.users u
  where u.id = uid and u.email_confirmed_at is not null and not u.is_anonymous;

  if caller_email is null then
    raise exception 'email is not confirmed' using errcode = 'PT403';
  end if;

  select * into inv
  from public.workspace_invites i
  where i.token_hash = encode(extensions.digest(invite_token, 'sha256'), 'hex')
  for update;

  -- One generic error for unknown, foreign, used, expired and orphaned tokens: no oracle.
  -- With an empty search_path, `<>` on citext resolves to the case-sensitive text
  -- operator, so the comparison is spelled out.
  if not found
     or lower(inv.email::text) <> lower(caller_email)
     or inv.accepted_at is not null
     or inv.expires_at < now()
     or not exists (
       select 1 from public.workspace_members m
       where m.workspace_id = inv.workspace_id
         and m.user_id = inv.invited_by
         and m.role > inv.role
     ) then
    raise exception 'invite is invalid or expired' using errcode = 'PT400';
  end if;

  insert into public.workspace_members (workspace_id, user_id, role)
  values (inv.workspace_id, uid, inv.role)
  on conflict (workspace_id, user_id) do update
    set role = greatest(public.workspace_members.role, excluded.role);

  update public.workspace_invites set accepted_at = now() where id = inv.id;

  return inv.workspace_id;
end
$$;

revoke all on function public.accept_workspace_invite from public, anon;
grant execute on function public.accept_workspace_invite to authenticated;

grant usage on type public.workspace_role to authenticated;
