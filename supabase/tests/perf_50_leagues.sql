-- Leagues and format boards at size (20261113120000_public_events_leagues.sql): a season of 12 events with 200 players
-- each (2,400 kept places), and a board rebuilt from 12,000 rated matches. Run with `T1_PERF=1 supabase/tests/run.sh
-- perf_50`. Budgets are ~5x local, as in perf_10_library.sql.
\ir _helpers.sql
set client_min_messages = notice;

insert into auth.users (id, email)
select md5('lu' || g)::uuid, 'l' || g || '@example.com' from generate_series(1, 300) g;
\set ORG '''00000000-0000-0000-0000-0000000050a1'''
insert into auth.users (id, email) values (:ORG, 'org50@example.com');
insert into public.events (id, short_code, name, created_by, status, visibility, current_round, number_of_rounds, format_name, format, starts_at)
select md5('le' || e)::uuid, 'LG' || e, 'Open ' || e, :ORG, 'completed', 'public', 8, 8, 'modern', 'constructed', now() - e * interval '30 days'
  from generate_series(1, 12) e;
insert into public.event_members (event_id, user_id, role) select md5('le' || e)::uuid, :ORG, 'owner' from generate_series(1, 12) e;
insert into public.participants (id, event_id, user_id, display_name, seat)
select md5('lp' || e || '-' || g)::uuid, md5('le' || e)::uuid, md5('lu' || ((g * 7 + e * 13) % 300 + 1))::uuid, 'Player ' || g, g
  from generate_series(1, 12) e, generate_series(1, 200) g;
insert into public.leagues (id, slug, name, created_by) values ('10000000-0000-0000-0000-0000000050a1', 'perf-league', 'Perf League', :ORG);
insert into public.league_members (league_id, user_id, role) values ('10000000-0000-0000-0000-0000000050a1', :ORG, 'owner');
insert into public.league_seasons (id, league_id, name, starts_on, ends_on, points, qualify)
values ('20000000-0000-0000-0000-0000000050a1', '10000000-0000-0000-0000-0000000050a1', '2026', current_date - 400, current_date + 30,
        '{"places": [{"through": 1, "points": 12}, {"through": 2, "points": 10}, {"through": 4, "points": 8}, {"through": 8, "points": 6}, {"through": 16, "points": 3}], "participation": 1, "match_win": 0}',
        '{"winners": true, "pass_down": true, "top": 10}');
insert into public.league_events (event_id, season_id, league_id)
select md5('le' || e)::uuid, '20000000-0000-0000-0000-0000000050a1', '10000000-0000-0000-0000-0000000050a1' from generate_series(1, 12) e;
insert into public.event_placements (event_id, participant_id, user_id, name, place, match_wins)
select p.event_id, p.id, p.user_id, p.display_name, p.seat, greatest(0, 8 - p.seat / 25) from public.participants p;

-- 12,000 rated matches: 1,000 an event, each between two of its players.
set session_replication_role = replica;
insert into public.rounds (id, event_id, number, status) select md5('lr' || e)::uuid, md5('le' || e)::uuid, 1, 'recorded' from generate_series(1, 12) e;
insert into public.matches (id, event_id, round_id, table_number)
select md5('lm' || e || '-' || m)::uuid, md5('le' || e)::uuid, md5('lr' || e)::uuid, m from generate_series(1, 12) e, generate_series(1, 1000) m;
insert into public.match_outcomes (match_id, user_id, opponent_id, event_id, mw, ml, md, played_at)
select md5('lm' || e || '-' || m)::uuid, x.a, x.b, md5('le' || e)::uuid, x.w, 1 - x.w, 0, now() - e * interval '30 days' + m * interval '1 second'
  from generate_series(1, 12) e, generate_series(1, 1000) m,
       lateral (select md5('lu' || ((m * 7 + e * 13) % 300 + 1))::uuid a, md5('lu' || ((m * 11 + e * 13 + 5) % 300 + 1))::uuid b, (m % 3 > 0)::int w) x
 where x.a <> x.b;
insert into public.match_outcomes (match_id, user_id, opponent_id, event_id, mw, ml, md, played_at)
select mo.match_id, mo.opponent_id, mo.user_id, mo.event_id, mo.ml, mo.mw, 0, mo.played_at from public.match_outcomes mo;
set session_replication_role = origin;
analyze;

select pg_temp.eq('the season has its players', (select count(*)::text from t1_private.league_table('20000000-0000-0000-0000-0000000050a1')), '300');
select pg_temp.ms('league page (12 events, 2,400 places)', $$select public.league_view('perf-league')$$, 100);
select pg_temp.ms('league standings page', $$select public.league_standings('20000000-0000-0000-0000-0000000050a1', 100, 100)$$, 100);
select pg_temp.ms('one player''s season', $$select public.league_player('20000000-0000-0000-0000-0000000050a1', (select md5('lu1')::uuid::text))$$, 120);
select pg_temp.ms('find events', $$select public.find_events('{"formats": ["modern"], "lat": 39.7, "lng": -104.9, "km": 100, "q": "open"}')$$, 20);
select pg_temp.ms('board rebuild (12,000 matches)', $$select t1_private.ratings_rebuild('modern')$$, 1500, 2);
select pg_temp.eq('everyone is rated', (select count(*)::text from t1_private.format_ratings where board = 'modern'), '300');
select pg_temp.ms('a board page', $$select public.format_leaderboard('modern', 0, 100)$$, 20);
select pg_temp.ms('the boards', $$select public.format_boards()$$, 20);
