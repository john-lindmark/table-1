-- Leagues you can see without searching (20261114120000_leagues_active.sql; contract/public-events-leagues-2026-11-13.md
-- § 3 "Leagues on the Events home"): leagues_home's `active` lists running leagues you neither run nor follow.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000f3a1', 'ana@example.com', '{"full_name": "Ana Org"}'),
  ('00000000-0000-0000-0000-00000000f3b1', 'bea@example.com', '{"full_name": "Bea"}'),
  ('00000000-0000-0000-0000-00000000f3c1', 'cal@example.com', '{"full_name": "Cal"}');
\set A '''00000000-0000-0000-0000-00000000f3a1'''
\set B '''00000000-0000-0000-0000-00000000f3b1'''
\set C '''00000000-0000-0000-0000-00000000f3c1'''

insert into public.leagues (id, slug, name, created_by, archived_at, is_demo) values
  ('10000000-0000-0000-0000-00000000f301', 'alpine-series', 'Alpine Series', :A, null, false),   -- season now
  ('10000000-0000-0000-0000-00000000f302', 'bygone-league', 'Bygone League', :A, null, false),   -- season over, nothing to play
  ('10000000-0000-0000-0000-00000000f303', 'coming-cup', 'Coming Cup', :A, null, false),         -- season over, an event to play
  ('10000000-0000-0000-0000-00000000f304', 'dusty-league', 'Dusty League', :A, now(), false),    -- archived
  ('10000000-0000-0000-0000-00000000f305', 'demo-league', 'Demo League', :A, null, true),        -- demo
  ('10000000-0000-0000-0000-00000000f306', 'zephyr-series', 'Zephyr Series', :A, null, false);   -- season to come
insert into public.league_members (league_id, user_id, role)
select id, :A, 'owner' from public.leagues where created_by = :A;
insert into public.league_seasons (id, league_id, name, starts_on, ends_on, points) values
  ('20000000-0000-0000-0000-00000000f301', '10000000-0000-0000-0000-00000000f301', '2026', current_date - 30, current_date + 30, '{"places": []}'),
  ('20000000-0000-0000-0000-00000000f302', '10000000-0000-0000-0000-00000000f302', '2025', current_date - 400, current_date - 35, '{"places": []}'),
  ('20000000-0000-0000-0000-00000000f303', '10000000-0000-0000-0000-00000000f303', '2025', current_date - 400, current_date - 35, '{"places": []}'),
  ('20000000-0000-0000-0000-00000000f304', '10000000-0000-0000-0000-00000000f304', '2026', current_date - 30, current_date + 30, '{"places": []}'),
  ('20000000-0000-0000-0000-00000000f305', '10000000-0000-0000-0000-00000000f305', '2026', current_date - 30, current_date + 30, '{"places": []}'),
  ('20000000-0000-0000-0000-00000000f306', '10000000-0000-0000-0000-00000000f306', '2027', current_date + 30, current_date + 300, '{"places": []}');
insert into public.events (id, short_code, name, created_by, status, current_round, number_of_rounds, visibility, starts_at, format_name, format) values
  ('e0000000-0000-0000-0000-00000000f301', 'ACTCUP', 'Cup Qualifier', :A, 'setup', 0, 4, 'public', now() + interval '3 days', 'modern', 'constructed');
insert into public.league_events (event_id, season_id, league_id)
values ('e0000000-0000-0000-0000-00000000f301', '20000000-0000-0000-0000-00000000f303', '10000000-0000-0000-0000-00000000f303');
insert into public.league_follows (user_id, league_id) values (:B, '10000000-0000-0000-0000-00000000f301');

create function pg_temp.active(q text default null) returns text language sql as $$
  select coalesce(string_agg(c->>'slug', ',' order by o), '') from jsonb_array_elements(public.leagues_home(q)->'active') with ordinality a(c, o);
$$;

set role authenticated;
select pg_temp.as_user(:C);
select pg_temp.eq('a stranger sees running leagues, soonest event first',
  pg_temp.active(), 'coming-cup,alpine-series,zephyr-series');
select pg_temp.eq('each row is a league card',
  (select (c->>'name') || ' / ' || (c->'next_event'->>'name') from jsonb_array_elements(public.leagues_home()->'active') c limit 1),
  'Coming Cup / Cup Qualifier');
select pg_temp.eq('searching leaves it empty', pg_temp.active('alpine'), '');
select pg_temp.eq('found still needs a search', (public.leagues_home()->'found')::text, '[]');
select pg_temp.as_user(:B);
select pg_temp.eq('leagues you follow are under following, not here', pg_temp.active(), 'coming-cup,zephyr-series');
select pg_temp.as_user(:A);
select pg_temp.eq('leagues you run are under mine, not here', pg_temp.active(), '');
reset role;
set role anon;
select pg_temp.as_user(null);
select pg_temp.eq('signed out sees them too', pg_temp.active(), 'coming-cup,alpine-series,zephyr-series');
reset role;
