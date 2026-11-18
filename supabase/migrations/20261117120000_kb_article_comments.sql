-- Flat, plain-text comments on articles.
-- Plan: docs/plans/2026-11-17-article-comments.md
--
-- Access matrix:
--   a comment is visible exactly when its article is visible to the reader (the policy
--   reuses kb_articles RLS through a nested exists instead of copying the article rule)
--   member+: comments on articles they can read, edits and deletes own comments
--   admin+:  deletes any comment in the workspace (moderation), edits none
-- Quota: 100 comments per user per rolling hour.

-- Target of the composite FK below: a comment's workspace must be its article's workspace.
create unique index kb_articles_id_workspace_id_key on public.kb_articles (id, workspace_id);

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

-- Covers the composite FK (cascade from articles) and ordered per-article lists.
create index kb_article_comments_article_id_idx
  on public.kb_article_comments (article_id, workspace_id, created_at);
-- Policy filter on workspace_id; serves the unfiltered "recent comments" list.
create index kb_article_comments_workspace_id_idx
  on public.kb_article_comments (workspace_id, created_at desc);
-- FK to auth.users (set null on account deletion), author policies, the quota count.
create index kb_article_comments_created_by_idx
  on public.kb_article_comments (created_by, created_at);

create trigger kb_article_comments_touch_updated_at
  before update on public.kb_article_comments
  for each row execute function private.touch_updated_at();

-- Quota: PostgREST exposes inserts to every signed-in user and Supabase rate limits cover
-- only auth endpoints. SECURITY DEFINER so the count includes the user's comments that RLS
-- hides from them (hidden articles, workspaces they left).
create function private.before_comment_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Clients always have an author (grants and policy). A null author is the service role
  -- or a fixture, which the quota does not limit.
  if new.created_by is null then
    return new;
  end if;

  -- Serialize inserts per author, so a concurrent session cannot count before this one
  -- commits. The count below then takes a fresh snapshot (READ COMMITTED, as PostgREST
  -- uses) and sees every committed comment. Bulk inserts in one statement are already
  -- counted row by row.
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

revoke all on public.kb_article_comments from anon, authenticated;

alter table public.kb_article_comments enable row level security;

-- Inside the exists, unqualified names resolve to kb_articles (it also has id, workspace_id,
-- body and created_by), so outer columns are always written kb_article_comments.<col>.
-- The workspace_id predicate is implied by the FK but lets the planner use the index.
create policy "members read comments on readable articles"
  on public.kb_article_comments for select to authenticated
  using (
    workspace_id = any (array(select private.workspace_ids_with_role('member')))
    and exists (select 1 from public.kb_articles a where a.id = kb_article_comments.article_id)
  );

create policy "members comment on readable articles"
  on public.kb_article_comments for insert to authenticated
  with check (
    created_by = (select auth.uid())
    and workspace_id = any (array(select private.workspace_ids_with_role('member')))
    and exists (select 1 from public.kb_articles a where a.id = kb_article_comments.article_id)
  );

-- Admins moderate by deleting, never by rewriting someone else's words. An author's edit and
-- delete both need the article to be readable, so comments on a hidden article are frozen
-- for their author; admins can still delete them. The policies say so themselves: a
-- statement that reads no column (no WHERE) does not bring in the read policy.
create policy "authors edit own comments"
  on public.kb_article_comments for update to authenticated
  using (
    created_by = (select auth.uid())
    and workspace_id = any (array(select private.workspace_ids_with_role('member')))
    and exists (select 1 from public.kb_articles a where a.id = kb_article_comments.article_id)
  )
  with check (
    created_by = (select auth.uid())
    and workspace_id = any (array(select private.workspace_ids_with_role('member')))
  );

create policy "authors and admins delete comments"
  on public.kb_article_comments for delete to authenticated
  using (
    workspace_id = any (array(select private.workspace_ids_with_role('admin')))
    or (
      workspace_id = any (array(select private.workspace_ids_with_role('member')))
      and created_by = (select auth.uid())
      and exists (select 1 from public.kb_articles a where a.id = kb_article_comments.article_id)
    )
  );

-- Clients never set ids, authors or timestamps (no backdating out of the quota window);
-- workspace_id and article_id are fixed at insert.
grant select, delete on public.kb_article_comments to authenticated;
grant insert (workspace_id, article_id, body) on public.kb_article_comments to authenticated;
grant update (body) on public.kb_article_comments to authenticated;
