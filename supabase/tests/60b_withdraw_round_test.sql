-- Re-pair a round (20261109120000_withdraw_round, contract/repair-round-2026-11-09.md): withdraw_round takes back
-- the latest active round so events-engine can pair it again. Organizer only, latest round only, results cleared
-- only when asked, earlier disputes block, lifetime records follow, audited.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'org@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'bea@example.com'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com'),
  ('00000000-0000-0000-0000-0000000000d1', 'dee@example.com');
\set A '''00000000-0000-0000-0000-0000000000a1'''
\set B '''00000000-0000-0000-0000-0000000000b1'''
\set C '''00000000-0000-0000-0000-0000000000c1'''
\set D '''00000000-0000-0000-0000-0000000000d1'''
\set EV '''e0000000-0000-0000-0000-000000000001'''
\set R1 '''f0000000-0000-0000-0000-000000000001'''
\set R2 '''f0000000-0000-0000-0000-000000000002'''
\set M11 '''f1000000-0000-0000-0000-000000000011'''
\set M12 '''f1000000-0000-0000-0000-000000000012'''
\set M21 '''f1000000-0000-0000-0000-000000000021'''
\set M22 '''f1000000-0000-0000-0000-000000000022'''
\set PA '''f2000000-0000-0000-0000-00000000000a'''
\set PB '''f2000000-0000-0000-0000-00000000000b'''
\set PC '''f2000000-0000-0000-0000-00000000000c'''
\set PD '''f2000000-0000-0000-0000-00000000000d'''

-- Alice runs a four-player event. Round 1 is recorded (Alice beat Bea, Cal beat Dee); round 2 is paired and
-- Alice v Cal has a result in already.
insert into public.events (id, short_code, name, created_by, status, current_round, number_of_rounds) values
  (:EV, 'REPAIR', 'Re-pair night', :A, 'in_progress', 2, 3);
insert into public.event_members (event_id, user_id, role) values (:EV, :A, 'owner');
insert into public.participants (id, event_id, user_id, display_name, seat) values
  (:PA, :EV, :A, 'Alice', 1), (:PB, :EV, :B, 'Bea', 2), (:PC, :EV, :C, 'Cal', 3), (:PD, :EV, :D, 'Dee', 4);
insert into public.rounds (id, event_id, number, status) values (:R1, :EV, 1, 'recorded'), (:R2, :EV, 2, 'active');
insert into public.matches (id, event_id, round_id, table_number, status) values
  (:M11, :EV, :R1, 1, 'confirmed'), (:M12, :EV, :R1, 2, 'confirmed'),
  (:M21, :EV, :R2, 1, 'reported'), (:M22, :EV, :R2, 2, 'pending');
insert into public.match_sides (match_id, participant_id, side, game_wins) values
  (:M11, :PA, 0, 2), (:M11, :PB, 1, 0), (:M12, :PC, 0, 2), (:M12, :PD, 1, 1),
  (:M21, :PA, 0, 2), (:M21, :PC, 1, 1), (:M22, :PB, 0, 0), (:M22, :PD, 1, 0);
update public.matches set status = 'reported' where id = :M21;  -- the records trigger counts the reported result
insert into public.tracker_sessions (id, match_id, event_id, starting_life)
values ('f3000000-0000-0000-0000-000000000001', :M22, :EV, 20);
insert into public.tracker_ops (session_id, client_op_id, game_no, side, counter, delta, tapped_at)
values ('f3000000-0000-0000-0000-000000000001', gen_random_uuid(), 1, 0, 'life', -3, now());

select pg_temp.eq('Alice has two match wins on her record before',
  (select match_wins::text from public.player_records where user_id = :A), '2');

set role authenticated;

-- Refusals ---------------------------------------------------------------------------------------------
select pg_temp.as_user(null);
select pg_temp.throws('signed out is refused',
  $$select public.withdraw_round('f0000000-0000-0000-0000-000000000002')$$, '42501');
select pg_temp.as_user(:B);
select pg_temp.throws('a player cannot re-pair',
  $$select public.withdraw_round('f0000000-0000-0000-0000-000000000002')$$, '42501');
select pg_temp.as_user(:A);
select pg_temp.throws('an earlier round cannot be re-paired',
  $$select public.withdraw_round('f0000000-0000-0000-0000-000000000001')$$, '22023');
select pg_temp.throws('results in the round need clearing first',
  $$select public.withdraw_round('f0000000-0000-0000-0000-000000000002')$$, 'PT409');
select pg_temp.throws('an unknown round is not found',
  $$select public.withdraw_round('f0000000-0000-0000-0000-0000000000ff', true)$$, 'P0002');

-- An unresolved dispute in round 1 blocks it; the organizer's correction resolves it.
reset role;
update public.matches set disputed = true, status = 'reported' where id = 'f1000000-0000-0000-0000-000000000012';
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.throws('an earlier dispute blocks re-pairing',
  $$select public.withdraw_round('f0000000-0000-0000-0000-000000000002', true)$$, '22023');
-- The organizer corrects round 1: Dee actually beat Cal 2–1.
select public.set_match_result(:M12, 1, 2, 0, 'Scores were swapped');
select pg_temp.eq('the corrected result is confirmed and undisputed',
  (select status || ':' || disputed from public.matches where id = :M12), 'confirmed:false');

-- Re-pair --------------------------------------------------------------------------------------------
select pg_temp.eq('withdraw answers the round and how many results it cleared',
  (select r->>'round_number' || ':' || (r->>'cleared_results') || ':' || (r->>'stage')
     from (select public.withdraw_round(:R2, true, 'Round 1 result was wrong') r) x), '2:1:swiss');
reset role;
select pg_temp.eq('round 2 is gone', (select count(*)::text from public.rounds where event_id = :EV), '1');
select pg_temp.eq('its matches are gone',
  (select count(*)::text from public.matches where id in (:M21, :M22)), '0');
select pg_temp.eq('its sides are gone',
  (select count(*)::text from public.match_sides where match_id in (:M21, :M22)), '0');
select pg_temp.eq('its life trackers are gone',
  (select count(*)::text from public.tracker_sessions where match_id = :M22), '0');
select pg_temp.eq('round 1 is untouched',
  (select status from public.rounds where id = :R1), 'recorded');
select pg_temp.eq('the event is back at round 1, still running',
  (select current_round || ':' || status from public.events where id = :EV), '1:in_progress');
select pg_temp.eq('the cleared round 2 win leaves Alice''s record',
  (select match_wins::text from public.player_records where user_id = :A), '1');
select pg_temp.eq('the corrected round 1 counts for Dee',
  (select match_wins::text from public.player_records where user_id = :D), '1');
select pg_temp.eq('withdrawn is audited with the old pairings and the reason',
  (select reason || ':' || jsonb_array_length(before->'matches') || ':' || (after->>'cleared_results')
     from public.audit_log where action = 'round.withdrawn'), 'Round 1 result was wrong:2:1');

-- Nothing to re-pair now: round 1 is recorded.
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.throws('a recorded round cannot be re-paired',
  $$select public.withdraw_round('f0000000-0000-0000-0000-000000000001', true)$$, '22023');

-- A finished event cannot be re-paired.
reset role;
insert into public.rounds (id, event_id, number, status) values (:R2, :EV, 2, 'active');
update public.events set status = 'completed' where id = :EV;
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.throws('a finished event cannot be re-paired',
  $$select public.withdraw_round('f0000000-0000-0000-0000-000000000002', true)$$, '22023');

-- With no results in, no clearing is needed.
reset role;
update public.events set status = 'in_progress', current_round = 2 where id = :EV;
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.eq('an empty round re-pairs without clearing',
  (public.withdraw_round(:R2)->>'cleared_results'), '0');
select pg_temp.as_user(null);
reset role;
select pg_temp.eq('anon has no execute',
  has_function_privilege('anon', 'public.withdraw_round(uuid, boolean, text)', 'execute')::text, 'false');
