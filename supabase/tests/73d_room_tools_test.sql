-- Room tools (20261113150000_room_tools.sql; contract/room-tools-2026-11-13.md): the display remote, extra time for
-- a table, judge calls.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000075a1', 'ana@example.com', '{"full_name": "Ana Org"}'),
  ('00000000-0000-0000-0000-0000000075b1', 'bea@example.com', '{"full_name": "Bea"}'),
  ('00000000-0000-0000-0000-0000000075c1', 'cal@example.com', '{"full_name": "Cal"}'),
  ('00000000-0000-0000-0000-0000000075d1', 'dee@example.com', '{"full_name": "Dee"}'),
  ('00000000-0000-0000-0000-000000007501', 'sam@example.com', '{"full_name": "Sam Stranger"}');
\set A '''00000000-0000-0000-0000-0000000075a1'''
\set B '''00000000-0000-0000-0000-0000000075b1'''
\set C '''00000000-0000-0000-0000-0000000075c1'''
\set D '''00000000-0000-0000-0000-0000000075d1'''
\set S '''00000000-0000-0000-0000-000000007501'''
\set EV '''e0000000-0000-0000-0000-000000007501'''
\set EP '''e0000000-0000-0000-0000-000000007502'''
\set R1 '''f1000000-0000-0000-0000-000000007501'''
\set M1 '''f2000000-0000-0000-0000-000000007501'''
\set M2 '''f2000000-0000-0000-0000-000000007502'''
\set PG '''a0000000-0000-0000-0000-000000007504'''

insert into public.events (id, short_code, name, created_by, status, current_round, number_of_rounds, visibility) values
  (:EV, 'ROOM01', 'Friday Modern', :A, 'in_progress', 1, 3, 'link_only'),
  (:EP, 'ROOM02', 'Private night', :A, 'in_progress', 0, 3, 'private');
insert into public.event_members (event_id, user_id, role) values (:EV, :A, 'owner'), (:EP, :A, 'owner');
insert into public.participants (id, event_id, user_id, display_name, seat) values
  ('a0000000-0000-0000-0000-000000007501', :EV, :B, 'Bea', 1), ('a0000000-0000-0000-0000-000000007502', :EV, :C, 'Cal', 2),
  ('a0000000-0000-0000-0000-000000007503', :EV, :D, 'Dee', 3), (:PG, :EV, null, 'Gus Guest', 4);
insert into public.participant_tokens (participant_id, token) values (:PG, 'guesttoken75');
insert into public.rounds (id, event_id, number, status) values (:R1, :EV, 1, 'active');
insert into public.matches (id, event_id, round_id, table_number) values (:M1, :EV, :R1, 1), (:M2, :EV, :R1, 2);
insert into public.match_sides (match_id, event_id, participant_id, user_id, side) values
  (:M1, :EV, 'a0000000-0000-0000-0000-000000007501', :B, 0), (:M1, :EV, 'a0000000-0000-0000-0000-000000007502', :C, 1),
  (:M2, :EV, 'a0000000-0000-0000-0000-000000007503', :D, 0), (:M2, :EV, :PG, null, 1);

create or replace function pg_temp.pushes(p_kind text) returns text language sql security definer as $$
  select coalesce(string_agg(x, ',' order by x), '-') from (
    select (select string_agg(right(u, 2), '+' order by u) from jsonb_array_elements_text(m.msg->'user_ids') u) x
      from pgmq.messages m where m.msg->>'kind' = p_kind) s $$;
create or replace function pg_temp.pings() returns text language sql security definer as $$ select count(*)::text from realtime.sent $$;
grant execute on function pg_temp.pushes(text), pg_temp.pings() to anon, authenticated;

-- ==================================================================== the display remote
set role anon;
select pg_temp.as_user(null);
select pg_temp.eq('a display reads auto with no message until told otherwise', (public.event_room(:EV)->'display')::text, '{"show": "auto", "message": null}');
select pg_temp.throws('a private event''s room stays closed', format('select public.event_room(%L)', :EP), '42501');
select pg_temp.throws('signed out can''t steer displays', format('select public.event_display_set(%L, %L)', :EV, '{"show": "clock"}'), '42501');
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.throws('players can''t either', format('select public.event_display_set(%L, %L)', :EV, '{"show": "clock"}'), '42501');
select pg_temp.as_user(:A);
select pg_temp.eq('the organizer pins standings and an announcement',
  public.event_display_set(:EV, '{"show": "standings", "message": "  Round 2 starts   at 2:15 "}')::text,
  '{"show": "standings", "message": "Round 2 starts at 2:15"}');
select pg_temp.eq('changing one keeps the other', public.event_display_set(:EV, '{"show": "auto"}')::text, '{"show": "auto", "message": "Round 2 starts at 2:15"}');
select pg_temp.throws('an unknown view', format('select public.event_display_set(%L, %L)', :EV, '{"show": "ads"}'), '22023');
select pg_temp.throws('a long announcement', format('select public.event_display_set(%L, jsonb_build_object(''message'', repeat(''x'', 141)))', :EV), '22023');
select pg_temp.eq('clear the announcement', (public.event_display_set(:EV, '{"message": ""}')->>'message' is null)::text, 'true');
set role anon;
select pg_temp.as_user(null);
select pg_temp.eq('displays follow', public.event_room(:EV)->'display'->>'show', 'auto');

-- ==================================================================== extra time
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.throws('a player can''t give extra time', format('select public.match_time_extend(%L, 300)', :M1), '42501');
select pg_temp.as_user(:A);
select pg_temp.eq('five minutes for table 1', public.match_time_extend(:M1, 300, 'Deck check')::text, '{"match_id": "f2000000-0000-0000-0000-000000007501", "table_number": 1, "extra_seconds": 300}');
select pg_temp.eq('three more adds up', public.match_time_extend(:M1, 180)->>'extra_seconds', '480');
select pg_temp.eq('some can be taken back', public.match_time_extend(:M1, -180)->>'extra_seconds', '300');
select pg_temp.throws('never below zero', format('select public.match_time_extend(%L, -600)', :M1), '22023');
select pg_temp.throws('never over an hour', format('select public.match_time_extend(%L, 3400)', :M1), '22023');
select pg_temp.eq('the organizer sees it in the room', (public.event_room(:EV)->'extensions')::text, '[{"match_id": "f2000000-0000-0000-0000-000000007501", "table_number": 1, "extra_seconds": 300}]');
select pg_temp.as_user(:B);
select pg_temp.eq('the table''s players see their own extra time', public.event_room(:EV)->'my_match'->>'extra_seconds', '300');
select pg_temp.as_user(:D);
select pg_temp.eq('another table has none', public.event_room(:EV)->'my_match'->>'extra_seconds', '0');

-- ==================================================================== judge calls
select pg_temp.as_user(:S);
select pg_temp.throws('only the table''s players can call a judge to it', format('select public.judge_call(%L)', :M1), '42501');
select pg_temp.as_user(:B);
select public.judge_call(:M1)->>'call_id' as "CALL" \gset
select pg_temp.eq('calling again is the same call', public.judge_call(:M1)->>'call_id', :'CALL');
select pg_temp.eq('the organizers get one push', pg_temp.pushes('judge.call'), 'a1');
select pg_temp.eq('the caller''s screen knows a call is open', public.event_room(:EV)->'my_match'->>'call_open', 'true');
select pg_temp.eq('players don''t get the list', ((public.event_room(:EV)->>'calls') is null)::text, 'true');
select pg_temp.as_user(:C);
select pg_temp.eq('the opponent sees it too', public.event_room(:EV)->'my_match'->>'call_open', 'true');
set role anon;
select pg_temp.as_user(null);
select pg_temp.eq('a guest calls with their claim token', ((public.judge_call(:M2, 'guesttoken75')->>'call_id') is not null)::text, 'true');
select pg_temp.throws('a wrong token calls nobody', format('select public.judge_call(%L, %L)', :M1, 'nope'), '42501');
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.eq('the organizer sees both tables, oldest first',
  (select string_agg((c->>'table_number') || ' ' || (c->>'by'), ', ') from jsonb_array_elements(public.event_room(:EV)->'calls') c), '1 Bea, 2 Gus Guest');
select pg_temp.as_user(:B);
select pg_temp.throws('a player can''t close a call', format('select public.judge_call_resolve(%L)', :'CALL'), '42501');
select pg_temp.as_user(:A);
select pg_temp.eq('handled', public.judge_call_resolve(:'CALL')->>'resolved', 'true');
select pg_temp.as_user(:D);
select pg_temp.eq('a table takes its call back', public.judge_call_cancel(:M2)->>'cancelled', 'true');
select pg_temp.as_user(:A);
select pg_temp.eq('no calls left', (public.event_room(:EV)->'calls')::text, '[]');
select pg_temp.as_user(:B);
select pg_temp.eq('a new call after the first was handled is a new call', ((public.judge_call(:M1)->>'call_id') <> :'CALL')::text, 'true');
reset role;
update public.rounds set status = 'recorded' where id = :R1;
set role authenticated;
select pg_temp.as_user(:D);
select pg_temp.throws('no calls once the round is over', format('select public.judge_call(%L)', :M2), '22023');
select pg_temp.as_user(:A);
select pg_temp.throws('or extra time', format('select public.match_time_extend(%L, 60)', :M2), '22023');
reset role;
select pg_temp.eq('audited', (select string_agg(action, ',' order by action) from (select distinct action from public.audit_log where event_id = :EV) x),
  'display.set,judge.called,judge.resolved,match.time_extended');
select pg_temp.eq('every change pinged the event', (pg_temp.pings()::int > 8)::text, 'true');
