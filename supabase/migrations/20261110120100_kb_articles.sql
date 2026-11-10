-- Workspace-scoped knowledge base articles.
--
-- Access matrix:
--   member: reads published articles and own drafts, writes own articles
--   admin+: reads, edits and deletes everything in the workspace

create table public.kb_articles (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  title        text not null check (char_length(title) between 1 and 500),
  body         text not null default '' check (char_length(body) <= 100000),
  published    boolean not null default false,
  created_by   uuid default auth.uid() references auth.users (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index kb_articles_workspace_id_idx on public.kb_articles (workspace_id, updated_at desc);
create index kb_articles_created_by_idx on public.kb_articles (created_by);

create function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

create trigger kb_articles_touch_updated_at
  before update on public.kb_articles
  for each row execute function private.touch_updated_at();

revoke all on public.kb_articles from anon, authenticated;

alter table public.kb_articles enable row level security;

create policy "members read published articles and own drafts"
  on public.kb_articles for select to authenticated
  using (
    workspace_id = any (array(select private.workspace_ids_with_role('admin')))
    or (
      workspace_id = any (array(select private.workspace_ids_with_role('member')))
      and (published or created_by = (select auth.uid()))
    )
  );

create policy "members create own articles"
  on public.kb_articles for insert to authenticated
  with check (
    workspace_id = any (array(select private.workspace_ids_with_role('member')))
    and created_by = (select auth.uid())
  );

create policy "authors and admins edit articles"
  on public.kb_articles for update to authenticated
  using (
    workspace_id = any (array(select private.workspace_ids_with_role('admin')))
    or (
      workspace_id = any (array(select private.workspace_ids_with_role('member')))
      and created_by = (select auth.uid())
    )
  )
  with check (
    workspace_id = any (array(select private.workspace_ids_with_role('admin')))
    or (
      workspace_id = any (array(select private.workspace_ids_with_role('member')))
      and created_by = (select auth.uid())
    )
  );

create policy "admins delete articles"
  on public.kb_articles for delete to authenticated
  using (workspace_id = any (array(select private.workspace_ids_with_role('admin'))));

grant select, delete on public.kb_articles to authenticated;
grant insert (workspace_id, title, body, published) on public.kb_articles to authenticated;
grant update (title, body, published) on public.kb_articles to authenticated;
