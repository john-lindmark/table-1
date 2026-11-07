-- Event read RPCs (20261018170000_privacy_lockdown) on a big night: 64 players, 6 rounds of 32 matches.
-- Run with `T1_PERF=1 supabase/tests/run.sh perf_`. Budgets are ~5x local (live runs about 5x slower), as in
-- perf_10_library.sql.
\ir _helpers.sql
set client_min_messages = notice;

insert into auth.users (id, email)
select md5('u' || g)::uuid, 'p' || g || '@example.com' from generate_series(1, 64) g;
\set ORG '''00000000-0000-0000-0000-0000000000f2'''
insert into auth.users (id, email) values (:ORG, 'org@example.com');
\set EV '''e0000000-0000-0000-0000-0000000000f2'''
insert into public.events (id, short_code, name, created_by, status, visibility, current_round, number_of_rounds)
values (:EV, 'BIG1', 'Big Night', :ORG, 'in_progress', 'link_only', 6, 6);
insert into public.event_members (event_id, user_id, role) values (:EV, :ORG, 'owner');
insert into public.pods (id, event_id) values ('f0000000-0000-0000-0000-0000000000f2', :EV);
insert into public.participants (id, event_id, pod_id, user_id, display_name, seat)
select md5('pt' || g)::uuid, :EV, 'f0000000-0000-0000-0000-0000000000f2', md5('u' || g)::uuid, 'Player ' || g, g
  from generate_series(1, 64) g;
insert into public.rounds (id, event_id, number, status)
select md5('r' || r)::uuid, :EV, r, case when r = 6 then 'active' else 'recorded' end from generate_series(1, 6) r;
insert into public.matches (id, event_id, round_id, table_number)
select md5('m' || r || '-' || t)::uuid, :EV, md5('r' || r)::uuid, t from generate_series(1, 6) r, generate_series(1, 32) t;
insert into public.match_sides (match_id, participant_id, side, game_wins)
select md5('m' || r || '-' || t)::uuid, md5('pt' || (((t - 1) * 2 + s + r) % 64 + 1))::uuid, s, 2 - s
  from generate_series(1, 6) r, generate_series(1, 32) t, generate_series(0, 1) s;
analyze;

set role authenticated;
select pg_temp.as_user(:ORG);
select pg_temp.eq('bundle has every match',
  (select sum(jsonb_array_length(r->'matches'))::text from jsonb_array_elements(public.event_bundle(:EV)->'rounds') r), '192');
select pg_temp.ms('event_bundle, 64 players x 6 rounds', $$select public.event_bundle('e0000000-0000-0000-0000-0000000000f2')$$, 60);
select pg_temp.ms('people, 64 co-players',
  $$select public.people(array(select md5('u' || g)::uuid from generate_series(1, 64) g))$$, 25);
reset role;
set role anon;
select pg_temp.as_user(null);
select pg_temp.ms('event_public, 32 live tables', $$select public.event_public('e0000000-0000-0000-0000-0000000000f2')$$, 25);
reset role;
-- Pings: one statement that touches every match of a round sends one ping, not 32.
truncate realtime.sent;
select pg_temp.ms('round result write with pings (32 matches)',
  $$update public.matches set game_draws = game_draws where round_id = md5('r6')::uuid$$, 25, 1);
select pg_temp.eq('one event ping for 32 rows', (select count(*)::text from realtime.sent where topic like 'event:%'), '1');

-- Your deck photos on your account (20261106170000_my_deck_photos): a regular with 300 events, two photos each, among
-- 20,000 other players' photos.
reset role;
insert into public.events (id, short_code, name, created_by, status)
select md5('pe' || g)::uuid, 'PH' || g, 'Night ' || g, :ORG, 'completed' from generate_series(1, 300) g;
insert into public.participants (id, event_id, user_id, display_name, seat)
select md5('pp' || g)::uuid, md5('pe' || g)::uuid, md5('u1')::uuid, 'Player 1', 1 from generate_series(1, 300) g;
insert into public.participants (id, event_id, display_name, seat)
select md5('po' || g || '-' || s)::uuid, md5('pe' || g)::uuid, 'Guest ' || s, s + 1
  from generate_series(1, 300) g, generate_series(1, 33) s;
insert into public.event_deck_photos (id, event_id, participant_id, uploaded_by, path)
select md5('ph' || g || '-' || k)::uuid, md5('pe' || g)::uuid, md5('pp' || g)::uuid, md5('u1')::uuid, 'p/' || g || '-' || k
  from generate_series(1, 300) g, generate_series(1, 2) k;
insert into public.event_deck_photos (id, event_id, participant_id, uploaded_by, path)
select md5('pg' || g || '-' || s)::uuid, md5('pe' || g)::uuid, md5('po' || g || '-' || s)::uuid, :ORG, 'g/' || g || '-' || s
  from generate_series(1, 300) g, generate_series(1, 33) s;
analyze;
set role authenticated;
select pg_temp.as_user(md5('u1')::uuid);
select pg_temp.eq('her 200 newest photos', jsonb_array_length(public.my_deck_photos()->'photos')::text, '200');
select pg_temp.ms('my_deck_photos, 600 of 10,500 photos', $$select public.my_deck_photos()$$, 25);
reset role;
