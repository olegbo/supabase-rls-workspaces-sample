-- kb_articles access matrix.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-00000000000b', 'owner@example.test',    now()),
  ('00000000-0000-0000-0000-00000000000c', 'member@example.test',   now()),
  ('00000000-0000-0000-0000-0000000000c2', 'member2@example.test',  now()),
  ('00000000-0000-0000-0000-00000000000d', 'outsider@example.test', now());

insert into public.workspaces (id, name, slug) values
  ('10000000-0000-0000-0000-000000000001', 'Acme', 'acme'),
  ('10000000-0000-0000-0000-000000000002', 'Other', 'other');

insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b', 'owner'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000c', 'member'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000c2', 'member'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000d', 'owner');

insert into public.kb_articles (id, workspace_id, title, published, created_by) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Published', true,
   '00000000-0000-0000-0000-00000000000b'),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Owner draft', false,
   '00000000-0000-0000-0000-00000000000b'),
  ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002', 'Foreign', true,
   '00000000-0000-0000-0000-00000000000d');

set local role authenticated;

-- Member ----------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000000c","role":"authenticated"}', true);

select results_eq('select title from public.kb_articles order by title', array['Published'],
  'member sees published articles of own workspace only');

select lives_ok(
  $$insert into public.kb_articles (workspace_id, title)
    values ('10000000-0000-0000-0000-000000000001', 'My draft')$$,
  'member can create an article');

select is((select created_by from public.kb_articles where title = 'My draft'),
  '00000000-0000-0000-0000-00000000000c'::uuid, 'author is set from the JWT');

select throws_ok(
  $$insert into public.kb_articles (workspace_id, title)
    values ('10000000-0000-0000-0000-000000000002', 'Spam')$$,
  '42501', null, 'member cannot write into a foreign workspace');

select throws_ok(
  $$insert into public.kb_articles (workspace_id, title, created_by)
    values ('10000000-0000-0000-0000-000000000001', 'Spoofed', '00000000-0000-0000-0000-00000000000b')$$,
  '42501', null, 'author cannot be spoofed');

select results_eq(
  $$with r as (update public.kb_articles set body = 'edited' where title = 'My draft' returning 1)
    select count(*)::int from r$$,
  array[1], 'author can edit own article');

select results_eq(
  $$with r as (update public.kb_articles set title = 'Edited' where title = 'Published' returning 1)
    select count(*)::int from r$$,
  array[0], 'member cannot edit articles of others');

select throws_ok(
  $$update public.kb_articles set workspace_id = '10000000-0000-0000-0000-000000000002'
    where title = 'My draft'$$,
  '42501', null, 'articles cannot be moved between workspaces');

select results_eq(
  $$with r as (delete from public.kb_articles where title = 'My draft' returning 1)
    select count(*)::int from r$$,
  array[0], 'member cannot delete articles');

-- Another member does not see the draft.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000c2","role":"authenticated"}', true);
select is((select count(*)::int from public.kb_articles where title = 'My draft'), 0,
  'drafts are private to the author');

-- Outsider sees nothing of acme.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000000d","role":"authenticated"}', true);
select results_eq('select title from public.kb_articles', array['Foreign'],
  'outsider sees only own workspace articles');

-- Owner -----------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);

select results_eq('select title from public.kb_articles order by title',
  array['My draft', 'Owner draft', 'Published'],
  'owner sees all articles of own workspace, including drafts');

select results_eq(
  $$with r as (update public.kb_articles set published = true where title = 'My draft' returning 1)
    select count(*)::int from r$$,
  array[1], 'owner can publish a member draft');

select results_eq(
  $$with r as (delete from public.kb_articles where title = 'My draft' returning 1)
    select count(*)::int from r$$,
  array[1], 'owner can delete articles');

select * from finish();
rollback;
