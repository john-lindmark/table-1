-- End-to-end checks for 20261006120000_events_v1_accounts_records.sql against the local baseline.
\set ON_ERROR_STOP 1
\set QUIET 1

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce(p::text, ''), false); end $$;
-- Records are server-only (20261018170000_privacy_lockdown): these helpers read them as the test owner.
create or replace function pg_temp.rec(p uuid) returns text language sql security definer as $$
  select coalesce((select format('%s-%s-%s b%s g%s-%s-%s', match_wins, match_losses, match_draws, byes, game_wins, game_losses, game_draws)
                     from public.player_records where user_id = p), 'none') $$;
create or replace function pg_temp.h2h(a uuid, b uuid) returns text language sql security definer as $$
  select coalesce((select format('%s-%s-%s g%s-%s-%s', match_wins, match_losses, match_draws, game_wins, game_losses, game_draws)
                     from public.head_to_head where user_id = a and opponent_id = b), 'none') $$;
create or replace function pg_temp.h2h_rows(a uuid) returns text language sql security definer as $$
  select count(*)::text from public.head_to_head where user_id = a $$;
create or replace function pg_temp.eq(label text, got text, want text) returns void language plpgsql as $$
begin
  if got is distinct from want then raise exception 'FAIL %: got %, want %', label, got, want; end if;
  raise notice 'ok  %', label;
end $$;

-- Accounts --------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'alice@example.com', '{"full_name":"Alice Owner"}'),
  ('00000000-0000-0000-0000-00000000000b', 'bob@example.com',   '{"name":"Bob"}'),
  ('00000000-0000-0000-0000-00000000000c', 'cara@example.com',  '{}'),
  ('00000000-0000-0000-0000-00000000000d', 'dan@example.com',   '{}'),
  ('00000000-0000-0000-0000-00000000000e', 'wes@example.com',   '{}');
select pg_temp.eq('profiles bootstrapped from auth', (select string_agg(display_name, ',' order by id) from public.profiles),
                  'Alice Owner,Bob,cara,dan,wes');

\set A '''00000000-0000-0000-0000-00000000000a'''
\set B '''00000000-0000-0000-0000-00000000000b'''
\set C '''00000000-0000-0000-0000-00000000000c'''
\set D '''00000000-0000-0000-0000-00000000000d'''
\set W '''00000000-0000-0000-0000-00000000000e'''

-- Event at a Denver game store, owned by Alice ---------------------------------
insert into public.events (id, short_code, name, created_by) values
  ('10000000-0000-0000-0000-000000000001', 'CUBE01', 'Tuesday Cube', :A);
insert into public.event_members (event_id, user_id, role) values ('10000000-0000-0000-0000-000000000001', :A, 'owner');
insert into public.pods (id, event_id) values ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');

set role authenticated;
-- Bob, Cara, Dan opted in to nearby alerts and opened the app near the store; Wes is across town.
select pg_temp.as_user(:B); insert into public.notification_prefs (user_id, nearby_alerts) values (:B, true); select public.update_presence(39.7401, -104.9890);
select pg_temp.as_user(:C); insert into public.notification_prefs (user_id, nearby_alerts) values (:C, true); select public.update_presence(39.7385, -104.9920);
select pg_temp.as_user(:D); insert into public.notification_prefs (user_id, nearby_alerts) values (:D, true); select public.update_presence(39.7395, -104.9900);
select pg_temp.as_user(:W); insert into public.notification_prefs (user_id, nearby_alerts) values (:W, true); select public.update_presence(39.6500, -104.9000);
select pg_temp.as_user(:A);
select public.set_event_location('10000000-0000-0000-0000-000000000001', 39.7392, -104.9903, 'Denver Card Shop', 150, 'nearby');
reset role;
select pg_temp.eq('presence stores a cell, not coordinates', (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_name = 'presence_cells'), 'user_id,geohash6,seen_at');
select pg_temp.eq('opening the event alerts nearby opted-in players only',
  (select string_agg(p.display_name, ',' order by p.display_name) from public.event_invites i join public.profiles p on p.id = i.user_id where i.source = 'nearby_alert'), 'Bob,cara,dan');
select pg_temp.eq('one nearby push message for the audience',
  (select jsonb_array_length(msg->'user_ids')::text from pgmq.messages where msg->>'kind' = 'event.nearby'), '3');
set role authenticated;
select pg_temp.as_user(:A);
select public.set_event_location('10000000-0000-0000-0000-000000000001', 39.7392, -104.9903, 'Denver Card Shop', 150, 'nearby');
reset role;
select pg_temp.eq('alerts go out once per event', (select count(*)::text from pgmq.messages where msg->>'kind' = 'event.nearby'), '1');
set role authenticated;

-- Nearby discovery and join ---------------------------------------------------
select pg_temp.as_user(:B);
select pg_temp.eq('nearby finds event ~60 m away',
  (select format('%s@%sm', name, distance_m) from public.nearby_events(39.7397, -104.9903)), 'Tuesday Cube@50m');
select pg_temp.eq('nearby hides event 2 km away',
  (select count(*)::text from public.nearby_events(39.7572, -104.9903)), '0');
select (public.join_event_nearby('10000000-0000-0000-0000-000000000001', 39.7397, -104.9903))->>'seat' as bob_seat \gset
select pg_temp.eq('bob seated', :'bob_seat', '1');
select pg_temp.eq('join is idempotent',
  (public.join_event_nearby('10000000-0000-0000-0000-000000000001', 39.7397, -104.9903))->>'already_joined', 'true');
select pg_temp.eq('nearby join accepts the pending invite',
  (select status from public.event_invites where user_id = :B), 'accepted');
select pg_temp.as_user(:C);
select pg_temp.eq('cara joins from the notification',
  (public.respond_to_invite('10000000-0000-0000-0000-000000000001', true))->>'status', 'accepted');
select pg_temp.as_user(:D);
select pg_temp.eq('dan declines from the notification',
  (public.respond_to_invite('10000000-0000-0000-0000-000000000001', false))->>'status', 'declined');
do $$ begin
  perform public.join_event_nearby('10000000-0000-0000-0000-000000000001', 39.7572, -104.9903);
  raise exception 'FAIL far join accepted';
exception when insufficient_privilege then raise notice 'ok  far-away join refused';
end $$;
do $$ begin
  perform public.get_join_qr('10000000-0000-0000-0000-000000000001');
  raise exception 'FAIL player read the QR secret';
exception when insufficient_privilege then raise notice 'ok  only organizers can show the QR';
end $$;

-- QR join: works from anywhere, any visibility; rotating kills old codes
select pg_temp.as_user(:A);
select (public.get_join_qr('10000000-0000-0000-0000-000000000001'))->>'secret' as qr1 \gset
select pg_temp.eq('QR url shape', (public.get_join_qr('10000000-0000-0000-0000-000000000001'))->>'url',
  'https://table-1.site/j/CUBE01?s=' || :'qr1');
select (public.get_join_qr('10000000-0000-0000-0000-000000000001', true))->>'secret' as qr2 \gset
select pg_temp.as_user(:D);
select set_config('t.qr1', :'qr1', false);
do $$ begin
  perform public.join_event_qr('cube01', current_setting('t.qr1'));
  raise exception 'FAIL rotated QR accepted';
exception when no_data_found then raise notice 'ok  rotated QR code refused';
end $$;
select pg_temp.eq('dan joins by scanning the current QR',
  (public.join_event_qr('cube01', :'qr2'))->>'already_joined', 'false');
reset role;
select pg_temp.eq('join path audited', (select string_agg(after->>'via', ',' order by at) from public.audit_log where action = 'participant.joined'), 'nearby,nearby_alert,qr');

-- Exact event location is not readable by clients, and events select * still works
set role anon;
select pg_temp.eq('event_locations hidden from clients', (select count(*)::text from public.event_locations), '0');
select pg_temp.eq('anon still reads events', (select name from public.events), 'Tuesday Cube');
reset role;

-- Walk-in without an account (V0 token flow)
insert into public.participants (id, event_id, pod_id, display_name, seat)
values ('30000000-0000-0000-0000-0000000000f1', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'Walker', 3);
insert into public.participant_tokens (participant_id, token) values ('30000000-0000-0000-0000-0000000000f1', 'walker-token');

select id as pb from public.participants where user_id = :B \gset
select id as pc from public.participants where user_id = :C \gset

-- Round 1: Bob vs Cara, Walker bye ---------------------------------------------
insert into public.rounds (id, event_id, number) values ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 1);
insert into public.matches (id, event_id, round_id, table_number) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 1);
insert into public.match_sides (match_id, participant_id, side) values
  ('50000000-0000-0000-0000-000000000001', :'pb', 0), ('50000000-0000-0000-0000-000000000001', :'pc', 1);
select pg_temp.eq('sides carry event_id and user_id',
  (select count(*)::text from public.match_sides where event_id is not null and user_id is not null), '2');

set role authenticated;
select pg_temp.as_user(:B);
select public.report_match('50000000-0000-0000-0000-000000000001', 2, 1, 0, 0, '60000000-0000-0000-0000-000000000001') as r1 \gset
select pg_temp.eq('bob reports 2-1', (:'r1'::jsonb)->>'status', 'reported');
select pg_temp.eq('bob record after report', pg_temp.rec(:B), '1-0-0 b0 g2-1-0');
select pg_temp.eq('cara record after report', pg_temp.rec(:C), '0-1-0 b0 g1-2-0');
select pg_temp.eq('h2h bob vs cara', pg_temp.h2h(:B, :C), '1-0-0 g2-1-0');
select pg_temp.eq('h2h cara vs bob', pg_temp.h2h(:C, :B), '0-1-0 g1-2-0');
select public.report_match('50000000-0000-0000-0000-000000000001', 2, 1, 0, 0, '60000000-0000-0000-0000-000000000001') as r1b \gset
select pg_temp.eq('idempotent retry returns same result', :'r1b', :'r1');
select pg_temp.eq('retry did not double count', pg_temp.rec(:B), '1-0-0 b0 g2-1-0');

select pg_temp.as_user(:C);
select pg_temp.eq('cara enters same score = confirm',
  (public.report_match('50000000-0000-0000-0000-000000000001', 2, 1, 0, 1))->>'status', 'confirmed');
select pg_temp.eq('confirm leaves records unchanged', pg_temp.rec(:C), '0-1-0 b0 g1-2-0');
do $$ begin
  perform public.report_match('50000000-0000-0000-0000-000000000001', 0, 2, 0, 2);
  raise exception 'FAIL player changed a confirmed result';
exception when insufficient_privilege then raise notice 'ok  confirmed result is final for players';
end $$;

-- Owner corrects the result: records move by exactly the difference
select pg_temp.as_user(:A);
select public.set_match_result('50000000-0000-0000-0000-000000000001', 1, 2, 0, 'Slip was filled in backwards');
select pg_temp.eq('bob after owner edit', pg_temp.rec(:B), '0-1-0 b0 g1-2-0');
select pg_temp.eq('cara after owner edit', pg_temp.rec(:C), '1-0-0 b0 g2-1-0');
select pg_temp.eq('h2h flipped', pg_temp.h2h(:B, :C) || ' / ' || pg_temp.h2h(:C, :B), '0-1-0 g1-2-0 / 1-0-0 g2-1-0');
select pg_temp.as_user(:B);
do $$ begin
  perform public.set_match_result('50000000-0000-0000-0000-000000000001', 2, 0, 0, 'mine');
  raise exception 'FAIL player used organizer edit';
exception when insufficient_privilege then raise notice 'ok  only organizers can set results';
end $$;
reset role;
select pg_temp.eq('owner edit audited with reason',
  (select reason from public.audit_log where action = 'result.set_by_organizer'), 'Slip was filled in backwards');
select pg_temp.eq('version bumped on every change',
  (select version::text from public.matches where id = '50000000-0000-0000-0000-000000000001'), '3');

-- Bye: counts as a bye, never a lifetime win or head-to-head
insert into public.matches (id, event_id, round_id, is_bye, status) values
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', true, 'confirmed');
insert into public.match_sides (match_id, participant_id, side, game_wins) values ('50000000-0000-0000-0000-000000000002', :'pc', 0, 2);
select pg_temp.eq('bye recorded as bye only', pg_temp.rec(:C), '1-0-0 b1 g2-1-0');

-- Round 2: Bob vs walk-in Walker; Walker later signs in as Wes and claims the seat
insert into public.rounds (id, event_id, number) values ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 2);
insert into public.matches (id, event_id, round_id) values
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002');
insert into public.match_sides (match_id, participant_id, side) values
  ('50000000-0000-0000-0000-000000000003', :'pb', 0), ('50000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-0000000000f1', 1);
set role authenticated;
select pg_temp.as_user(:B);
select public.report_match('50000000-0000-0000-0000-000000000003', 2, 0, 0, 0);
select pg_temp.eq('win over walk-in counts for bob', pg_temp.rec(:B), '1-1-0 b0 g3-2-0');
select pg_temp.eq('no h2h against a walk-in', pg_temp.h2h_rows(:B), '1');
select pg_temp.as_user(:W);
select public.claim_participant('walker-token');
select pg_temp.eq('claimed history backfills wes', pg_temp.rec(:W), '0-1-0 b0 g0-2-0');
select pg_temp.eq('claimed history backfills h2h', pg_temp.h2h(:B, :W) || ' / ' || pg_temp.h2h(:W, :B), '1-0-0 g2-0-0 / 0-1-0 g0-2-0');
select pg_temp.eq('bob unchanged by claim', pg_temp.rec(:B), '1-1-0 b0 g3-2-0');

-- Round 3: conflicting reports -> disputed, first result stands
reset role;
insert into public.rounds (id, event_id, number) values ('40000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 3);
insert into public.matches (id, event_id, round_id) values
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000003');
insert into public.match_sides (match_id, participant_id, side) values
  ('50000000-0000-0000-0000-000000000004', :'pb', 0), ('50000000-0000-0000-0000-000000000004', :'pc', 1);
set role authenticated;
select pg_temp.as_user(:B);
select public.report_match('50000000-0000-0000-0000-000000000004', 2, 0, 0, 0);
select pg_temp.as_user(:C);
select public.report_match('50000000-0000-0000-0000-000000000004', 0, 2, 0, 0) as r4 \gset
select pg_temp.eq('conflicting score flags dispute', (:'r4'::jsonb)->>'conflict', 'true');
reset role;
select pg_temp.eq('first result stands',
  (select format('%s disputed=%s', status, disputed) from public.matches where id = '50000000-0000-0000-0000-000000000004'), 'reported disputed=t');
select pg_temp.eq('bob record includes standing result', pg_temp.rec(:B), '2-1-0 b0 g5-2-0');
select pg_temp.eq('organizers notified of dispute',
  (select count(*)::text from pgmq.messages where msg->>'kind' = 'result.disputed'), '1');

-- A write outside the RPCs (service role / SQL console) still keeps records right
update public.match_sides set game_wins = 0 where match_id = '50000000-0000-0000-0000-000000000004' and side = 0;
select pg_temp.eq('direct side edit applied', pg_temp.rec(:B), '1-1-1 b0 g3-2-0');
-- Deleting a match reverses it
delete from public.matches where id = '50000000-0000-0000-0000-000000000004';
select pg_temp.eq('match row actually deleted', (select count(*)::text from public.matches where id = '50000000-0000-0000-0000-000000000004'), '0');
select pg_temp.eq('deleted match reversed (bob)', pg_temp.rec(:B), '1-1-0 b0 g3-2-0');
select pg_temp.eq('deleted match reversed (cara)', pg_temp.rec(:C), '1-0-0 b1 g2-1-0');

-- Records are a cache: drift check is empty and a full rebuild reproduces them exactly
select pg_temp.eq('no drift', (select count(*)::text from public.records_drift()), '0');
create temp table before_pr as select * from public.player_records;
create temp table before_h as select * from public.head_to_head;
select public.rebuild_all_records();
select pg_temp.eq('rebuild reproduces player_records', (select count(*)::text from (
  select user_id, match_wins, match_losses, match_draws, byes, game_wins, game_losses, game_draws from before_pr
  except select user_id, match_wins, match_losses, match_draws, byes, game_wins, game_losses, game_draws from public.player_records) x), '0');
select pg_temp.eq('rebuild reproduces head_to_head', (select count(*)::text from (
  select user_id, opponent_id, match_wins, match_losses, match_draws, game_wins, game_losses, game_draws from before_h
  except select user_id, opponent_id, match_wins, match_losses, match_draws, game_wins, game_losses, game_draws from public.head_to_head) x), '0');

-- Auto-confirm at round end: a new round confirms earlier open reports; ending a round confirms its own
select pg_temp.eq('starting round 3 confirmed the round 2 report', (select status from public.matches where id = '50000000-0000-0000-0000-000000000003'), 'confirmed');
insert into public.rounds (id, event_id, number) values ('40000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 4);
select pg_temp.eq('confirm keeps records', pg_temp.rec(:B), '1-1-0 b0 g3-2-0');
insert into public.matches (id, event_id, round_id, status, reported_at) values
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000004', 'reported', now());
insert into public.matches (id, event_id, round_id, status, reported_at, disputed) values
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000004', 'reported', now(), true);
update public.rounds set status = 'recorded' where id = '40000000-0000-0000-0000-000000000004';
select pg_temp.eq('ending a round confirms undisputed, leaves disputed',
  (select string_agg(status, ',' order by id) from public.matches where round_id = '40000000-0000-0000-0000-000000000004'), 'confirmed,reported');

-- Realtime + notifications
select pg_temp.eq('broadcasts go to per-match topics',
  (select count(distinct topic)::text from realtime.sent where topic like 'match:%'), '4');
select pg_temp.eq('opponent notified of reports',
  (select count(*)::text from pgmq.messages where msg->>'kind' = 'result.reported'), '2');

-- RLS and privacy
set role authenticated;
select pg_temp.as_user(:C);
do $$ begin
  insert into public.player_records (user_id, match_wins) values ('00000000-0000-0000-0000-00000000000c', 99)
  on conflict (user_id) do update set match_wins = 99;
  raise exception 'FAIL client wrote player_records';
exception when insufficient_privilege then raise notice 'ok  clients cannot write records';
end $$;
select pg_temp.as_user(:D);
do $$ begin
  perform count(*) from public.head_to_head;
  raise exception 'FAIL clients read head_to_head';
exception when insufficient_privilege then raise notice 'ok  h2h is not readable by clients';
end $$;
do $$ begin
  perform count(*) from public.player_records;
  raise exception 'FAIL clients read player_records';
exception when insufficient_privilege then raise notice 'ok  lifetime records are not readable by clients';
end $$;
select pg_temp.as_user(:B);
select public.register_device('ios', 'apns-token-bob', 'la-token-bob', '1.0.0');
select pg_temp.as_user(:C);
select pg_temp.eq('devices are private', (select count(*)::text from public.devices), '0');

-- Account deletion keeps history for opponents
reset role;
-- what the delete-account edge function does with the service role
update public.profiles set handle = null, display_name = 'Deleted player', avatar_url = null, deleted_at = now() where id = :W;
update public.participants set display_name = 'Deleted player' where user_id = :W;
select pg_temp.eq('deleted player keeps rows', (select display_name from public.profiles where id = :W), 'Deleted player');
select pg_temp.eq('opponent h2h intact after deletion', pg_temp.h2h(:B, :W), '1-0-0 g2-0-0');
select pg_temp.eq('no drift at end', (select count(*)::text from public.records_drift()), '0');
\echo ALL TESTS PASSED
