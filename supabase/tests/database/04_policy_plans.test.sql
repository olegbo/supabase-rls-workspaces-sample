-- Plan regression: RLS predicates must stay index-friendly. An OR of two
-- `col in (select setof_fn())` predicates once forced a sequential scan over every
-- article for unfiltered list queries; `= any (array(select ...))` lets the planner
-- use a BitmapOr over the workspace_id index.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

create schema tests;
create function tests.plan_of(query text)
returns text
language plpgsql
as $$
declare
  line text;
  plan text := '';
begin
  for line in execute 'explain (costs off) ' || query loop
    plan := plan || line || E'\n';
  end loop;
  return plan;
end
$$;
grant usage on schema tests to authenticated;
grant execute on function tests.plan_of to authenticated;

-- 5k workspaces with 20 articles each; the test user belongs to 10 of them.
insert into auth.users (id, email, email_confirmed_at)
values ('00000000-0000-0000-0000-000000000001', 'reader@example.test', now());

insert into public.workspaces (id, name, slug)
select ('10000000-0000-0000-0000-' || lpad(to_hex(g), 12, '0'))::uuid, 'W' || g, 'w' || g
from generate_series(1, 5000) g;

insert into public.workspace_members (workspace_id, user_id, role)
select ('10000000-0000-0000-0000-' || lpad(to_hex(g), 12, '0'))::uuid,
       '00000000-0000-0000-0000-000000000001',
       (case when g <= 3 then 'admin' else 'member' end)::public.workspace_role
from generate_series(1, 10) g;

insert into public.kb_articles (workspace_id, title, published)
select ('10000000-0000-0000-0000-' || lpad(to_hex(1 + g % 5000), 12, '0'))::uuid, 'A' || g, g % 3 = 0
from generate_series(1, 100000) g;

-- One comment per article. Inserted without a JWT, so the quota trigger returns at once.
insert into public.kb_article_comments (workspace_id, article_id, body)
select workspace_id, id, 'C' from public.kb_articles;

analyze public.workspaces, public.workspace_members, public.kb_articles, public.kb_article_comments;

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);

select doesnt_match(
  tests.plan_of('select id from public.kb_articles order by updated_at desc limit 20'),
  'Seq Scan on kb_articles',
  'unfiltered article list does not scan the whole table'
);

select doesnt_match(
  tests.plan_of('select count(*) from public.kb_articles'),
  'Seq Scan on kb_articles',
  'article count does not scan the whole table'
);

select doesnt_match(
  tests.plan_of('select id from public.workspaces'),
  'Seq Scan on workspaces',
  'workspace list does not scan the whole table'
);

-- Comments inherit article visibility through a nested exists on kb_articles, whose own
-- OR-ed policy could tempt the planner into a hash semi-join over a full scan.
select doesnt_match(
  tests.plan_of(format(
    'select id from public.kb_article_comments where article_id = %L order by created_at limit 50',
    (select id from public.kb_articles where published limit 1))),
  'Seq Scan on kb_article_comments',
  'one article''s comments are listed without scanning the whole table'
);

select doesnt_match(
  tests.plan_of('select id from public.kb_article_comments order by created_at desc limit 20'),
  'Seq Scan on kb_article(s|_comments)',
  'unfiltered comment list scans neither comments nor articles in full'
);

-- One comment per article: visible comments must match visible articles, which also
-- proves comments on hidden drafts stay hidden.
select is(
  (select count(*)::int from public.kb_article_comments),
  (select count(*)::int from public.kb_articles),
  'visible comments match visible articles'
);

-- Sanity check that the data is visible, so the plans above are not trivially empty.
select is(
  (select count(*)::int from public.kb_articles),
  (select count(*)::int from public.kb_articles
   where workspace_id = any (array(select private.workspace_ids_with_role('member')))
     and (published or workspace_id = any (array(select private.workspace_ids_with_role('admin'))))),
  'visible rows match the access matrix'
);

select * from finish();
rollback;
