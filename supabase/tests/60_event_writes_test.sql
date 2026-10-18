-- Event tables are RPC-only (20261017120000_rpc_only_event_writes): record_round, set_participant_status,
-- the account-link guard, and proof that an organizer can no longer write event tables directly.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'org@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'bea@example.com'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com'),
  ('00000000-0000-0000-0000-0000000000d1', 'dee@example.com'),
  ('00000000-0000-0000-0000-0000000000e1', 'eli@example.com');
\set A '''00000000-0000-0000-0000-0000000000a1'''
\set B '''00000000-0000-0000-0000-0000000000b1'''
\set C '''00000000-0000-0000-0000-0000000000c1'''
\set D '''00000000-0000-0000-0000-0000000000d1'''
\set E '''00000000-0000-0000-0000-0000000000e1'''
\set EV '''e0000000-0000-0000-0000-000000000001'''
\set EV2 '''e0000000-0000-0000-0000-000000000002'''
\set R1 '''f0000000-0000-0000-0000-000000000001'''
\set M1 '''f1000000-0000-0000-0000-000000000001'''
\set M2 '''f1000000-0000-0000-0000-000000000002'''
\set PA '''f2000000-0000-0000-0000-00000000000a'''
\set PB '''f2000000-0000-0000-0000-00000000000b'''
\set PC '''f2000000-0000-0000-0000-00000000000c'''
\set PG '''f2000000-0000-0000-0000-00000000000f'''

-- Alice runs an event with Bea, Cal and a walk-in guest; round 1 has two matches.
insert into public.events (id, short_code, name, created_by, status, current_round) values
  (:EV, 'LOCK01', 'Lock night', :A, 'in_progress', 1),
  (:EV2, 'LOCK02', 'Short night', :A, 'in_progress', 0);
insert into public.event_members (event_id, user_id, role) values (:EV, :A, 'owner'), (:EV2, :A, 'owner');
insert into public.participants (id, event_id, user_id, display_name, seat) values
  (:PA, :EV, :A, 'Alice', 1), (:PB, :EV, :B, 'Bea', 2), (:PC, :EV, :C, 'Cal', 3), (:PG, :EV, null, 'Guest', 4);
insert into public.participant_tokens (participant_id, token) values (:PG, 'guest-token');
insert into public.rounds (id, event_id, number, status) values (:R1, :EV, 1, 'active');
insert into public.matches (id, event_id, round_id, table_number, status) values
  (:M1, :EV, :R1, 1, 'reported'), (:M2, :EV, :R1, 2, 'reported');
insert into public.match_sides (match_id, participant_id, side, game_wins) values
  (:M1, :PA, 0, 2), (:M1, :PB, 1, 0), (:M2, :PC, 0, 2), (:M2, :PG, 1, 1);
update public.matches set disputed = true where id = :M2;

set role authenticated;

-- Direct writes are refused, even for the organizer --------------------------------------------------
select pg_temp.as_user(:A);
select pg_temp.throws('organizer cannot PATCH a match result directly',
  $$update public.matches set status = 'confirmed' where id = 'f1000000-0000-0000-0000-000000000001'$$, '42501');
select pg_temp.throws('organizer cannot change game wins directly',
  $$update public.match_sides set game_wins = 2 where match_id = 'f1000000-0000-0000-0000-000000000001'$$, '42501');
select pg_temp.throws('organizer cannot seat another account directly',
  $$insert into public.participants (event_id, user_id, display_name) values ('e0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000d1', 'Dee')$$, '42501');
select pg_temp.throws('organizer cannot add matches directly',
  $$insert into public.matches (event_id, round_id, status) values ('e0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001', 'confirmed')$$, '42501');
select pg_temp.throws('organizer cannot write audit rows',
  $$insert into public.audit_log (event_id, action) values ('e0000000-0000-0000-0000-000000000001', 'forged')$$, '42501');
select pg_temp.throws('no direct event inserts',
  $$insert into public.events (name, created_by) values ('x', '00000000-0000-0000-0000-0000000000a1')$$, '42501');
select pg_temp.throws('organizer cannot update a participant directly',
  $$update public.participants set status = 'dropped' where id = 'f2000000-0000-0000-0000-00000000000b'$$, '42501');
select pg_temp.throws('organizer cannot complete the event directly',
  $$update public.events set status = 'completed' where id = 'e0000000-0000-0000-0000-000000000001'$$, '42501');
select pg_temp.throws('organizer cannot record a round directly',
  $$update public.rounds set status = 'recorded' where id = 'f0000000-0000-0000-0000-000000000001'$$, '42501');

-- set_participant_status ------------------------------------------------------------------------------
select pg_temp.as_user(:C);
select pg_temp.throws('a player cannot drop others',
  $$select public.set_participant_status('f2000000-0000-0000-0000-00000000000b', 'dropped', 1)$$, '42501');
select pg_temp.as_user(:A);
select pg_temp.throws('status must be active or dropped',
  $$select public.set_participant_status('f2000000-0000-0000-0000-00000000000b', 'gone', 1)$$, '22023');
select pg_temp.eq('organizer drops Bea after round 1',
  public.set_participant_status(:PB, 'dropped', 1)::text, '{"status": "dropped", "participant_id": "f2000000-0000-0000-0000-00000000000b", "dropped_in_round": 1}');
select public.set_participant_status(:PB, 'dropped', 1);
select pg_temp.eq('dropping twice writes one audit row',
  (select count(*)::text from public.audit_log where action = 'participant.dropped' and target_id = :PB), '1');
select pg_temp.eq('the drop is audited with before and after',
  (select before->>'status' || '>' || (after->>'status') from public.audit_log where action = 'participant.dropped'), 'active>dropped');
select pg_temp.eq('dropped defaults to the current round',
  (public.set_participant_status(:PC, 'dropped')->>'dropped_in_round'), '1');
select public.set_participant_status(:PC, 'active');
select pg_temp.eq('reinstating clears the round',
  (select status || ':' || coalesce(dropped_in_round::text, '-') from public.participants where id = :PC), 'active:-');
select pg_temp.eq('reinstating is audited',
  (select count(*)::text from public.audit_log where action = 'participant.reinstated' and target_id = :PC), '1');
select public.set_participant_status(:PB, 'active');

-- record_round ----------------------------------------------------------------------------------------
select pg_temp.as_user(:C);
select pg_temp.throws('a player cannot record rounds',
  $$select public.record_round('e0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001', false)$$, '42501');
select pg_temp.as_user(:A);
select pg_temp.throws('a round from another event is not found',
  $$select public.record_round('e0000000-0000-0000-0000-000000000002', 'f0000000-0000-0000-0000-000000000001', false)$$, 'P0002');
select pg_temp.throws('no round and not final is refused',
  $$select public.record_round('e0000000-0000-0000-0000-000000000001', null, false)$$, '22023');
select pg_temp.eq('recording round 1',
  (public.record_round(:EV, :R1, false)->>'round_status'), 'recorded');
select pg_temp.eq('recording confirms undisputed reports only',
  (select string_agg(table_number || ':' || status, ',' order by table_number) from public.matches where round_id = :R1),
  '1:confirmed,2:reported');
select public.record_round(:EV, :R1, false);
select pg_temp.eq('recording twice writes one audit row',
  (select count(*)::text from public.audit_log where action = 'round.recorded' and target_id = :R1), '1');
select pg_temp.throws('a final round with an open dispute is refused',
  $$select public.record_round('e0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001', true)$$, '22023');
select pg_temp.eq('the refused finish left the event running',
  (select status from public.events where id = :EV), 'in_progress');
select public.set_match_result(:M2, 2, 1, 0, 'checked with both players');
select pg_temp.eq('final round completes the event in the same call',
  (public.record_round(:EV, :R1, true)->>'event_status'), 'completed');
select public.record_round(:EV, :R1, true);
select pg_temp.eq('completing twice writes one audit row',
  (select count(*)::text from public.audit_log where action = 'event.completed' and target_id = :EV), '1');
select pg_temp.eq('finishing an event with no open round',
  (public.record_round(:EV2, null, true)->>'event_status'), 'completed');
select pg_temp.throws('no drops once the event is over',
  $$select public.set_participant_status('f2000000-0000-0000-0000-00000000000b', 'dropped', 1)$$, '22023');

-- Account links ---------------------------------------------------------------------------------------
-- A future RPC that tried to seat someone else's account from a client request is refused.
reset role;
create function public.t_link(p_participant uuid, p_user uuid) returns void
language sql security definer set search_path = '' as $$
  update public.participants set user_id = p_user where id = p_participant $$;
grant execute on function public.t_link(uuid, uuid) to authenticated;
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.throws('a definer RPC cannot link another account for a client',
  $$select public.t_link('f2000000-0000-0000-0000-00000000000f', '00000000-0000-0000-0000-0000000000d1')$$, '42501');
select pg_temp.eq('Dee has no record from the refused link',
  (select count(*)::text from public.player_records where user_id = :D), '0');
select pg_temp.as_user(:D);
select public.claim_participant('guest-token');
select pg_temp.eq('claiming a seat links the claimer',
  (select user_id::text from public.participants where id = :PG), '00000000-0000-0000-0000-0000000000d1');
select pg_temp.eq('the claimed side carries the account',
  (select user_id::text from public.match_sides where participant_id = :PG), '00000000-0000-0000-0000-0000000000d1');
reset role;
select public.t_link(:PG, :E);
select pg_temp.eq('trusted roles (service, cron, migrations) can still relink',
  (select user_id::text from public.participants where id = :PG), '00000000-0000-0000-0000-0000000000e1');
drop function public.t_link(uuid, uuid);

-- Signed out -------------------------------------------------------------------------------------------
set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('anon cannot record rounds',
  $$select public.record_round('e0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001', true)$$, '42501');
select pg_temp.throws('anon cannot drop players',
  $$select public.set_participant_status('f2000000-0000-0000-0000-00000000000b', 'dropped', 1)$$, '42501');
reset role;
