-- A player's life tracker follows them into the next round (20261111130000_tracker_next): tracker_next answers a
-- match's player with their match in the event's newest later round; organizers watching stay put; a re-paired
-- (gone) match is found by its event.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'org@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'bea@example.com'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com'),
  ('00000000-0000-0000-0000-0000000000d1', 'dee@example.com'),
  ('00000000-0000-0000-0000-0000000000e1', 'eve@example.com');
\set A '''00000000-0000-0000-0000-0000000000a1'''
\set B '''00000000-0000-0000-0000-0000000000b1'''
\set C '''00000000-0000-0000-0000-0000000000c1'''
\set D '''00000000-0000-0000-0000-0000000000d1'''
\set E '''00000000-0000-0000-0000-0000000000e1'''
\set EV '''e0000000-0000-0000-0000-000000000c01'''
\set R1 '''f0000000-0000-0000-0000-000000000c01'''
\set R2 '''f0000000-0000-0000-0000-000000000c02'''
\set M11 '''f1000000-0000-0000-0000-000000000c11'''
\set M12 '''f1000000-0000-0000-0000-000000000c12'''
\set M21 '''f1000000-0000-0000-0000-000000000c21'''
\set M22 '''f1000000-0000-0000-0000-000000000c22'''
\set PB '''f2000000-0000-0000-0000-000000000c0b'''
\set PC '''f2000000-0000-0000-0000-000000000c0c'''
\set PD '''f2000000-0000-0000-0000-000000000c0d'''
\set PE '''f2000000-0000-0000-0000-000000000c0e'''

-- Alice runs it; Bea v Cal and Dee v Eve in round 1.
insert into public.events (id, short_code, name, created_by, status, current_round, number_of_rounds) values
  (:EV, 'TRNEXT', 'Next round night', :A, 'in_progress', 1, 3);
insert into public.event_members (event_id, user_id, role) values (:EV, :A, 'owner');
insert into public.participants (id, event_id, user_id, display_name, seat) values
  (:PB, :EV, :B, 'Bea', 1), (:PC, :EV, :C, 'Cal', 2), (:PD, :EV, :D, 'Dee', 3), (:PE, :EV, :E, 'Eve', 4);
insert into public.rounds (id, event_id, number, status) values (:R1, :EV, 1, 'active');
insert into public.matches (id, event_id, round_id, table_number, status) values
  (:M11, :EV, :R1, 1, 'confirmed'), (:M12, :EV, :R1, 2, 'pending');
insert into public.match_sides (match_id, participant_id, side) values
  (:M11, :PB, 0), (:M11, :PC, 1), (:M12, :PD, 0), (:M12, :PE, 1);

set role authenticated;

select pg_temp.as_user(null);
select pg_temp.throws('signed out is refused', $$select public.tracker_next('f1000000-0000-0000-0000-000000000c11')$$, '42501');

select pg_temp.as_user(:B);
select pg_temp.eq('nothing newer while round 1 runs', coalesce(public.tracker_next(:M11)::text, 'null'), 'null');

-- Round 2 is created before its matches are written (events-engine inserts the round, then the matches).
reset role;
insert into public.rounds (id, event_id, number, status) values (:R2, :EV, 2, 'active');
update public.rounds set status = 'recorded' where id = :R1;
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.eq('round 2 without its matches yet names the round only',
  public.tracker_next(:M11)::text, '{"bye": false, "round": 2, "match_id": null}');

reset role;
insert into public.matches (id, event_id, round_id, table_number, status, is_bye) values
  (:M21, :EV, :R2, 1, 'pending', false), (:M22, :EV, :R2, null, 'confirmed', true);
insert into public.match_sides (match_id, participant_id, side) values
  (:M21, :PB, 0), (:M21, :PD, 1), (:M22, :PC, 0);
set role authenticated;

select pg_temp.as_user(:B);
select pg_temp.eq('Bea''s round 1 tracker finds her round 2 match',
  public.tracker_next(:M11)->>'match_id', 'f1000000-0000-0000-0000-000000000c21');
select pg_temp.as_user(:D);
select pg_temp.eq('Dee''s unfinished round 1 match still moves on once round 2 is paired',
  public.tracker_next(:M12)->>'match_id', 'f1000000-0000-0000-0000-000000000c21');
select pg_temp.as_user(:C);
select pg_temp.eq('Cal has a bye in round 2',
  public.tracker_next(:M11)::text, '{"bye": true, "round": 2, "match_id": null}');
select pg_temp.as_user(:E);
select pg_temp.eq('Eve has no match in round 2 (dropped)',
  public.tracker_next(:M12)::text, '{"bye": false, "round": 2, "match_id": null}');
select pg_temp.as_user(:B);
select pg_temp.eq('the newest match has nothing newer', coalesce(public.tracker_next(:M21)::text, 'null'), 'null');

select pg_temp.as_user(:A);
select pg_temp.eq('the organizer watching a match stays on it', coalesce(public.tracker_next(:M11)::text, 'null'), 'null');
select pg_temp.as_user(:E);
select pg_temp.eq('someone else''s match answers nothing', coalesce(public.tracker_next(:M11)::text, 'null'), 'null');

-- Round 2 is re-paired: its matches go and come back with new ids.
reset role;
delete from public.matches where round_id = :R2;
insert into public.matches (id, event_id, round_id, table_number, status) values
  ('f1000000-0000-0000-0000-000000000c31', :EV, :R2, 1, 'pending');
insert into public.match_sides (match_id, participant_id, side) values
  ('f1000000-0000-0000-0000-000000000c31', :PB, 0), ('f1000000-0000-0000-0000-000000000c31', :PC, 1);
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.eq('a gone match with its event finds the re-paired match',
  public.tracker_next(:M21, :EV)->>'match_id', 'f1000000-0000-0000-0000-000000000c31');
select pg_temp.eq('a gone match without its event answers nothing',
  coalesce(public.tracker_next(:M21)::text, 'null'), 'null');
select pg_temp.as_user(:A);
select pg_temp.eq('a gone match looked up by someone not playing answers nothing',
  coalesce(public.tracker_next(:M21, :EV)::text, 'null'), 'null');
select pg_temp.as_user(:B);
select pg_temp.eq('an existing match never borrows the event lookup',
  coalesce(public.tracker_next('f1000000-0000-0000-0000-000000000c31', :EV)::text, 'null'), 'null');

select pg_temp.as_user(null);
reset role;
select pg_temp.eq('anon has no execute',
  has_function_privilege('anon', 'public.tracker_next(uuid, uuid)', 'execute')::text, 'false');
