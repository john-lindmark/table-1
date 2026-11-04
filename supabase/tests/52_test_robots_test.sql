-- Google's test robots are kept apart from real players (20261104120000_test_robots, contract/test-robots-2026-11-04.md).
\ir _helpers.sql

insert into auth.users (id, email, created_at) values
  ('00000000-0000-0000-0000-0000000052a1', 'robo@example.com', now()),          -- Test Lab phone, says so
  ('00000000-0000-0000-0000-0000000052b1', 'lab@example.com', now()),           -- Test Lab network, new account
  ('00000000-0000-0000-0000-0000000052c1', 'old@example.com', now() - interval '30 days'),  -- same network, long-standing
  ('00000000-0000-0000-0000-0000000052d1', 'dana@example.com', now()),          -- a real player nearby
  ('00000000-0000-0000-0000-0000000052e1', 'apple@example.com', now());         -- a robot with an Apple sign-in
update public.profiles set display_name = initcap(split_part(u.email, '@', 1))
  from auth.users u where u.id = profiles.id and u.email like '%@example.com';
insert into auth.identities (user_id, provider, provider_id) values ('00000000-0000-0000-0000-0000000052e1', 'apple', 'apple-1');
\set ROBO '''00000000-0000-0000-0000-0000000052a1'''
\set LAB '''00000000-0000-0000-0000-0000000052b1'''
\set OLD '''00000000-0000-0000-0000-0000000052c1'''
\set DANA '''00000000-0000-0000-0000-0000000052d1'''
\set APPLE '''00000000-0000-0000-0000-0000000052e1'''

-- Robo makes an event before the app has said what it is, then the app marks the account.
insert into public.events (id, short_code, name, created_by) values
  ('52000000-0000-0000-0000-000000000001', 'ROBO01', 'Draft · Star Trek', :ROBO);
insert into public.event_members (event_id, user_id, role) values ('52000000-0000-0000-0000-000000000001', :ROBO, 'owner');

set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('signed out cannot mark', 'select public.account_mark_robot()', '42501');
set role authenticated;
select pg_temp.as_user(:ROBO);
select pg_temp.eq('the app marks its own account', public.account_mark_robot()->>'marked', 'true');
select pg_temp.eq('a second call changes nothing', public.account_mark_robot()->>'marked', 'false');
reset role;
select pg_temp.eq('marked once, from the device', (select string_agg(reason, ',') from t1_private.robots where user_id = :ROBO), 'device');
select pg_temp.eq('its profile is demo data', (select is_demo::text from public.profiles where id = :ROBO), 'true');
select pg_temp.eq('its earlier event is demo data it owns',
  (select format('%s:%s', is_demo::text, (demo_owner = :ROBO)::text) from public.events where id = '52000000-0000-0000-0000-000000000001'), 'true:true');
select pg_temp.eq('audited once on the account, once on the event',
  (select count(*)::text from public.account_audit where target_user = :ROBO and action = 'robot.marked')
  || '/' || (select count(*)::text from public.audit_log where event_id = '52000000-0000-0000-0000-000000000001' and action = 'event.robot_quarantined'),
  '1/1');
select pg_temp.eq('nobody else can be marked by it', (select count(*)::text from t1_private.robots), '1');

-- Its next event is demo data from the start; Dana, nearby with alerts on, hears nothing and doesn't see it.
set role authenticated;
select pg_temp.as_user(:DANA);
insert into public.notification_prefs (user_id, nearby_alerts) values (:DANA, true);
select public.update_presence(39.7401, -104.9890);
reset role;
insert into public.events (id, short_code, name, created_by) values
  ('52000000-0000-0000-0000-000000000002', 'ROBO02', 'Draft · Star Trek', :ROBO);
insert into public.event_members (event_id, user_id, role) values ('52000000-0000-0000-0000-000000000002', :ROBO, 'owner');
select pg_temp.eq('a robot''s new event is demo data', (select is_demo::text from public.events where id = '52000000-0000-0000-0000-000000000002'), 'true');
set role authenticated;
select pg_temp.as_user(:ROBO);
select public.set_event_location('52000000-0000-0000-0000-000000000002', 39.7392, -104.9903, null, 150, 'nearby');
select pg_temp.eq('the robot still finds its own event nearby',
  (select count(*)::text from public.nearby_events(39.7397, -104.9903)), '1');
select pg_temp.eq('and on its home', (select jsonb_array_length(public.events_home(true)->'events')::text), '2');
select pg_temp.as_user(:DANA);
select pg_temp.eq('Dana doesn''t see it nearby', (select count(*)::text from public.nearby_events(39.7397, -104.9903)), '0');
select pg_temp.eq('Dana can''t find the robot', jsonb_array_length(public.friend_search('Robo'))::text, '0');
reset role;
select pg_temp.eq('no nearby alert, no invite',
  (select count(*)::text from pgmq.messages where msg->>'kind' = 'event.nearby')
  || '/' || (select count(*)::text from public.event_invites where event_id = '52000000-0000-0000-0000-000000000002'), '0/0');

-- Real events still alert (the is_demo check only skips demo ones).
insert into public.events (id, short_code, name, created_by) values
  ('52000000-0000-0000-0000-000000000003', 'REAL03', 'Tuesday Cube', :OLD);
insert into public.event_members (event_id, user_id, role) values ('52000000-0000-0000-0000-000000000003', :OLD, 'owner');
set role authenticated;
select pg_temp.as_user(:OLD);
select public.set_event_location('52000000-0000-0000-0000-000000000003', 39.7392, -104.9903, null, 150, 'nearby');
select pg_temp.as_user(:DANA);
select pg_temp.eq('a real event nearby still shows', (select string_agg(name, ',') from public.nearby_events(39.7397, -104.9903)), 'Tuesday Cube');
reset role;
select pg_temp.eq('and still alerts', (select count(*)::text from pgmq.messages where msg->>'kind' = 'event.nearby'), '1');

-- Sign-ins from a Test Lab network: a new account is marked, a long-standing one and other networks aren't.
insert into auth.sessions (user_id, ip, user_agent) values (:DANA, '73.169.74.214', 'ktor-client');
insert into auth.sessions (user_id, ip, user_agent) values (:OLD, '108.177.24.175', 'ktor-client');
insert into auth.sessions (user_id, ip, user_agent) values (:LAB, '108.177.24.175', 'ktor-client');
insert into auth.sessions (user_id, ip, user_agent) values (:LAB, '66.102.8.1', 'ktor-client');
select pg_temp.eq('only the new account on a Test Lab network',
  (select string_agg(p.display_name || ':' || r.reason, ',' order by p.display_name) from t1_private.robots r join public.profiles p on p.id = r.user_id),
  'Lab:network,Robo:device');
select pg_temp.eq('IPv6 blocks match too', (select count(*)::text from t1_private.robot_networks where '2001:4860:1008::1'::inet <<= net), '1');

-- A false positive comes back out.
select pg_temp.eq('release', t1_private.robot_release(:LAB)::text, 'true');
select pg_temp.eq('released profile is real again', (select is_demo::text from public.profiles where id = :LAB), 'false');

-- The sweep: only robots marked a week ago, never one with an Apple sign-in.
select pg_temp.as_user(null);
select t1_private.robot_quarantine(:APPLE, 'manual');
select pg_temp.eq('nothing is a week old yet', t1_private.robot_sweep()::text, '0');
update t1_private.robots set marked_at = now() - interval '8 days';
select pg_temp.eq('the sweep removes Robo only', t1_private.robot_sweep()::text, '1');
select pg_temp.eq('Robo''s account and events are gone',
  (select count(*)::text from auth.users where id = :ROBO) || '/' || (select count(*)::text from public.events where created_by = :ROBO or demo_owner = :ROBO),
  '0/0');
select pg_temp.eq('Robo''s profile reads as deleted', (select display_name from public.profiles where id = :ROBO), 'Deleted player');
select pg_temp.eq('the Apple robot stays for delete-account', (select count(*)::text from t1_private.robots where user_id = :APPLE), '1');
select pg_temp.eq('the sweep left no one acting as Robo', coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''), 'none'), 'none');
select pg_temp.eq('the real event is untouched', (select is_demo::text from public.events where id = '52000000-0000-0000-0000-000000000003'), 'false');
