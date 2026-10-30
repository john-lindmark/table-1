-- Android live notifications (20261030040000_live_dispatch_android): an event whose players or organizer have only an
-- Android device (no iOS Live Activity token) still dispatches to live-activity; iOS and web devices alone don't.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000062a1', 'org@example.com'),
  ('00000000-0000-0000-0000-0000000062b1', 'bea@example.com'),
  ('00000000-0000-0000-0000-0000000062c1', 'cal@example.com');
\set A '''00000000-0000-0000-0000-0000000062a1'''
\set B '''00000000-0000-0000-0000-0000000062b1'''
\set C '''00000000-0000-0000-0000-0000000062c1'''
\set EV '''e0000000-0000-0000-0000-000000000062'''
\set R1 '''f0000000-0000-0000-0000-000000000062'''
\set M1 '''f1000000-0000-0000-0000-000000000062'''
\set PB '''f2000000-0000-0000-0000-0000000062bb'''
\set PC '''f2000000-0000-0000-0000-0000000062cc'''

insert into public.events (id, short_code, name, created_by, status, current_round) values
  (:EV, 'ANDR62', 'Android night', :A, 'in_progress', 1);
insert into public.event_members (event_id, user_id, role) values (:EV, :A, 'owner');
insert into public.participants (id, event_id, user_id, display_name, seat) values (:PB, :EV, :B, 'Bea', 1), (:PC, :EV, :C, 'Cal', 2);
insert into public.rounds (id, event_id, number, status) values (:R1, :EV, 1, 'active');
insert into public.matches (id, event_id, round_id, table_number, status) values (:M1, :EV, :R1, 1, 'pending');
insert into public.match_sides (match_id, participant_id, side, game_wins) values (:M1, :PB, 0, 0), (:M1, :PC, 1, 0);

-- No devices, no tokens: nothing.
delete from net.requests;
update public.matches set game_draws = 1, version = version + 1 where id = :M1;
select pg_temp.eq('nobody to tell, no dispatch', (select count(*) from net.requests where url like '%live-activity')::text, '0');

-- A web or iOS alert device alone doesn't count (iOS needs an activity token).
insert into public.devices (user_id, platform, push_token) values (:B, 'web', 'web-b'), (:C, 'ios', 'ios-c');
delete from net.requests;
update public.matches set game_draws = 0, version = version + 1 where id = :M1;
select pg_temp.eq('web and iOS alert devices alone don''t dispatch', (select count(*) from net.requests where url like '%live-activity')::text, '0');

-- A player's Android phone: dispatches.
insert into public.devices (user_id, platform, push_token) values (:B, 'android', 'fcm-b');
delete from net.requests;
update public.matches set status = 'reported', version = version + 1 where id = :M1;
select pg_temp.eq('a player''s Android device dispatches', (select count(*) from net.requests where url like '%live-activity')::text, '1');

-- Only the organizer on Android: dispatches too.
delete from public.devices where push_token = 'fcm-b';
insert into public.devices (user_id, platform, push_token) values (:A, 'android', 'fcm-a');
delete from net.requests;
update public.matches set status = 'confirmed', version = version + 1 where id = :M1;
select pg_temp.eq('an organizer''s Android device dispatches', (select count(*) from net.requests where url like '%live-activity')::text, '1');

-- Demo events never do.
update public.events set is_demo = true where id = :EV;
delete from net.requests;
update public.matches set game_draws = 1, version = version + 1 where id = :M1;
select pg_temp.eq('demo events don''t dispatch', (select count(*) from net.requests where url like '%live-activity')::text, '0');
