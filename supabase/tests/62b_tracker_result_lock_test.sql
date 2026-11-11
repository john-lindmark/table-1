-- The life tracker records no more games once the match's result is in (20261111150000_tracker_result_lock,
-- contract/life-tracker-options-2026-10-20.md § After the result is in).
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a2', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000000b2', 'ben@example.com'),
  ('00000000-0000-0000-0000-0000000000c2', 'cat@example.com');
\set A '''00000000-0000-0000-0000-0000000000a2'''
\set B '''00000000-0000-0000-0000-0000000000b2'''
\set C '''00000000-0000-0000-0000-0000000000c2'''
\set EV '''e0000000-0000-0000-0000-0000000000c1'''
\set R1 '''f0000000-0000-0000-0000-0000000000c1'''
\set M '''f1000000-0000-0000-0000-0000000000c1'''
\set PA '''f2000000-0000-0000-0000-0000000000ca'''
\set PB '''f2000000-0000-0000-0000-0000000000cb'''
\set S '''f3000000-0000-0000-0000-0000000000c1'''

-- Cat runs the event; Ana plays Ben in round 1 with a synced tracker.
insert into public.events (id, short_code, name, created_by, status, current_round, number_of_rounds) values
  (:EV, 'TRKLCK', 'Tracker lock night', :C, 'in_progress', 1, 3);
insert into public.event_members (event_id, user_id, role) values (:EV, :C, 'owner');
insert into public.participants (id, event_id, user_id, display_name, seat) values
  (:PA, :EV, :A, 'Ana', 1), (:PB, :EV, :B, 'Ben', 2);
insert into public.rounds (id, event_id, number, status) values (:R1, :EV, 1, 'active');
insert into public.matches (id, event_id, round_id, table_number, status) values (:M, :EV, :R1, 1, 'pending');
insert into public.match_sides (match_id, participant_id, side, game_wins) values (:M, :PA, 0, 0), (:M, :PB, 1, 0);
insert into public.tracker_sessions (id, match_id, event_id, starting_life, user0, user1)
values (:S, :M, :EV, 20, :A, :B);

set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.eq('no result yet: the state says so', (public.tracker_state(:S)->>'result_in'), 'false');
select public.tracker_record_game(:S, 1, 0, false);
select public.tracker_record_game(:S, 2, 0, false);
select pg_temp.eq('games record while the result is pending',
  jsonb_array_length(public.tracker_state(:S)->'games')::text, '2');

-- Ana reports 2–0 for the match.
reset role;
update public.match_sides set game_wins = 2 where match_id = :M and side = 0;
update public.matches set status = 'reported', reported_by_user = :A, reported_at = now() where id = :M;
set role authenticated;

select pg_temp.as_user(:A);
select pg_temp.eq('the state says the result is in', (public.tracker_state(:S)->>'result_in'), 'true');
select pg_temp.throws('a third game is refused once reported',
  $$select public.tracker_record_game('f3000000-0000-0000-0000-0000000000c1', 3, 1, false)$$, 'PT409');
select pg_temp.as_user(:B);
select pg_temp.throws('the opponent cannot add a game either',
  $$select public.tracker_record_game('f3000000-0000-0000-0000-0000000000c1', 3, 1, false)$$, 'PT409');
select pg_temp.throws('nor a draw',
  $$select public.tracker_record_game('f3000000-0000-0000-0000-0000000000c1', 3, null, true)$$, 'PT409');
select pg_temp.as_user(:A);
select pg_temp.eq('a resend of a game already recorded still answers the state',
  (public.tracker_record_game(:S, 2, 0, false)->>'session_id'), 'f3000000-0000-0000-0000-0000000000c1');
select pg_temp.throws('a different answer for a recorded game is still a conflict',
  $$select public.tracker_record_game('f3000000-0000-0000-0000-0000000000c1', 2, 1, false)$$, '23505');

-- Confirmed and disputed results lock it too.
reset role;
update public.matches set status = 'confirmed' where id = :M;
set role authenticated;
select pg_temp.throws('confirmed: refused',
  $$select public.tracker_record_game('f3000000-0000-0000-0000-0000000000c1', 3, 1, false)$$, 'PT409');
reset role;
update public.matches set status = 'reported', disputed = true where id = :M;
set role authenticated;
select pg_temp.throws('disputed: refused',
  $$select public.tracker_record_game('f3000000-0000-0000-0000-0000000000c1', 3, 1, false)$$, 'PT409');

-- The result cleared (back to pending) opens it again.
reset role;
update public.matches set status = 'pending', disputed = false where id = :M;
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.eq('cleared: the state says no result', (public.tracker_state(:S)->>'result_in'), 'false');
select public.tracker_record_game(:S, 3, 1, false);
select pg_temp.eq('cleared: a game records again',
  jsonb_array_length(public.tracker_state(:S)->'games')::text, '3');

-- Clients can't call the helper.
select pg_temp.throws('the helper is closed to clients',
  $$select public.tracker_result_in('f1000000-0000-0000-0000-0000000000c1')$$, '42501');
reset role;
