-- Insights picks on user_settings (20261030030000_insights_picks): the owner reads and writes their own picks, an
-- older client's tracker_mode upsert keeps them, nobody else sees or changes them, and the shape is checked.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000069a1', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000069b1', 'ben@example.com');
\set A '''00000000-0000-0000-0000-0000000069a1'''
\set B '''00000000-0000-0000-0000-0000000069b1'''

set role authenticated;

select pg_temp.as_user(:A);
insert into public.user_settings (user_id, insights)
values (:A, '{"section": "limited", "format": "pauper", "days": 14, "hidden_sets": ["CUBE"]}')
on conflict (user_id) do update set insights = excluded.insights;
select pg_temp.eq('the owner reads their picks',
  (select insights->>'format' from public.user_settings where user_id = :A), 'pauper');
select pg_temp.eq('tracker_mode defaults when only picks are written',
  (select tracker_mode from public.user_settings where user_id = :A), 'elsewhere');

-- An older client upserts tracker_mode only: the picks stay.
insert into public.user_settings (user_id, tracker_mode) values (:A, 'tracker')
on conflict (user_id) do update set tracker_mode = excluded.tracker_mode;
select pg_temp.eq('a tracker_mode upsert keeps the picks',
  (select insights->'hidden_sets'->>0 from public.user_settings where user_id = :A), 'CUBE');

-- Retrying the same write is harmless.
update public.user_settings set insights = '{"format": "modern"}' where user_id = :A;
update public.user_settings set insights = '{"format": "modern"}' where user_id = :A;
select pg_temp.eq('retrying a write is idempotent',
  (select insights::text from public.user_settings where user_id = :A), '{"format": "modern"}');

select pg_temp.throws('picks must be an object',
  $$update public.user_settings set insights = '[1]' where user_id = '00000000-0000-0000-0000-0000000069a1'$$, '23514');
select pg_temp.throws('picks are capped in size',
  $$update public.user_settings set insights = jsonb_build_object('x', repeat('a', 5000)) where user_id = '00000000-0000-0000-0000-0000000069a1'$$, '23514');

-- Another account sees nothing and can't change them.
select pg_temp.as_user(:B);
select pg_temp.eq('another account reads none of them',
  (select count(*) from public.user_settings where user_id = :A)::text, '0');
update public.user_settings set insights = '{"format": "standard"}' where user_id = :A;
select pg_temp.throws('another account can''t write them',
  $$insert into public.user_settings (user_id, insights) values ('00000000-0000-0000-0000-0000000069a1', '{}')$$, '42501');

select pg_temp.as_user(:A);
select pg_temp.eq('the owner''s picks are untouched',
  (select insights->>'format' from public.user_settings where user_id = :A), 'modern');

-- Signed out: nothing.
reset role;
set role anon;
select pg_temp.eq('signed out reads no settings', (select count(*) from public.user_settings)::text, '0');
reset role;
