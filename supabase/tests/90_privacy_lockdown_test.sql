-- Privacy lockdown, step 1 (contract/privacy-lockdown-2026-10-18.md): who can read an event, codes, people,
-- pings, records.
\ir _helpers.sql

-- Ola organizes. Pia plays (and organizes nothing). Ivo is invited to the private event. Sam is a stranger.
-- Fay is Pia's friend, Rex asked Pia, Pub has a public profile. Bea blocked Pia (and plays in Ola's event);
-- Pia blocked Bo (public). Del is deleted (a friend), Dem is a demo account (public).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000aa01', 'ola@example.com', '{"full_name": "Ola Org"}'),
  ('00000000-0000-0000-0000-00000000aa02', 'pia@example.com', '{"full_name": "Pia Play"}'),
  ('00000000-0000-0000-0000-00000000aa03', 'ivo@example.com', '{"full_name": "Ivo Invite"}'),
  ('00000000-0000-0000-0000-00000000aa04', 'sam@example.com', '{"full_name": "Sam Stranger"}'),
  ('00000000-0000-0000-0000-00000000aa05', 'fay@example.com', '{"full_name": "Fay Friend"}'),
  ('00000000-0000-0000-0000-00000000aa06', 'rex@example.com', '{"full_name": "Rex Request"}'),
  ('00000000-0000-0000-0000-00000000aa07', 'pub@example.com', '{"full_name": "Pub Lic"}'),
  ('00000000-0000-0000-0000-00000000aa08', 'bea@example.com', '{"full_name": "Bea Blocker"}'),
  ('00000000-0000-0000-0000-00000000aa09', 'bo@example.com',  '{"full_name": "Bo Blocked"}'),
  ('00000000-0000-0000-0000-00000000aa0a', 'del@example.com', '{"full_name": "Del Gone"}');
insert into public.profiles (id, display_name, is_demo, demo_owner) values
  ('00000000-0000-0000-0000-00000000aa0b', 'Dem Demo', true, '00000000-0000-0000-0000-00000000aa02');
update public.profiles set deleted_at = now(), display_name = 'Deleted player' where id = '00000000-0000-0000-0000-00000000aa0a';
\set OLA '''00000000-0000-0000-0000-00000000aa01'''
\set PIA '''00000000-0000-0000-0000-00000000aa02'''
\set IVO '''00000000-0000-0000-0000-00000000aa03'''
\set SAM '''00000000-0000-0000-0000-00000000aa04'''
\set FAY '''00000000-0000-0000-0000-00000000aa05'''
\set REX '''00000000-0000-0000-0000-00000000aa06'''
\set PUB '''00000000-0000-0000-0000-00000000aa07'''
\set BEA '''00000000-0000-0000-0000-00000000aa08'''
\set BO  '''00000000-0000-0000-0000-00000000aa09'''
\set DEL '''00000000-0000-0000-0000-00000000aa0a'''
\set DEM '''00000000-0000-0000-0000-00000000aa0b'''

insert into public.friendships (user_lo, user_hi, requested_by, status) values
  (least(:PIA::uuid, :FAY::uuid), greatest(:PIA::uuid, :FAY::uuid), :PIA, 'accepted'),
  (least(:PIA::uuid, :REX::uuid), greatest(:PIA::uuid, :REX::uuid), :REX, 'pending'),
  (least(:PIA::uuid, :DEL::uuid), greatest(:PIA::uuid, :DEL::uuid), :PIA, 'accepted');
insert into public.share_settings (user_id, profile) values (:PUB, 'public'), (:BO, 'public'), (:DEM, 'public');
insert into public.user_blocks (user_id, blocked_id) values (:BEA, :PIA), (:PIA, :BO);

-- Events: LINK (link_only, live), PRIV (private, setup), OTHER (another event with a guest), DONE (completed),
-- GONE (cancelled), DEMO (demo).
\set LINK  '''e0000000-0000-0000-0000-000000000001'''
\set PRIV  '''e0000000-0000-0000-0000-000000000002'''
\set OTHER '''e0000000-0000-0000-0000-000000000003'''
\set DONE  '''e0000000-0000-0000-0000-000000000004'''
\set GONE  '''e0000000-0000-0000-0000-000000000005'''
\set DEMO  '''e0000000-0000-0000-0000-000000000006'''
insert into public.events (id, short_code, name, created_by, status, visibility, venue_name, format_name, is_demo) values
  (:LINK,  'LNK1', 'Tuesday Modern', :OLA, 'in_progress', 'link_only', 'Card Shop', 'modern', false),
  (:PRIV,  'PRV1', 'Kitchen Cube',   :OLA, 'setup',       'private',   null,        null,     false),
  (:OTHER, 'OTH1', 'Other Night',    :SAM, 'setup',       'link_only', null,        null,     false),
  (:DONE,  'DNE1', 'Last Week',      :OLA, 'completed',   'link_only', null,        null,     false),
  (:GONE,  'GNE1', 'Called Off',     :OLA, 'cancelled',   'link_only', null,        null,     false),
  (:DEMO,  'DMO1', 'Demo Night',     :PIA, 'setup',       'nearby',    null,        null,     true);
insert into public.event_members (event_id, user_id, role) values
  (:LINK, :OLA, 'owner'), (:PRIV, :OLA, 'owner'), (:OTHER, :SAM, 'owner'), (:DONE, :OLA, 'owner'),
  (:GONE, :OLA, 'owner'), (:DEMO, :PIA, 'owner');
insert into public.pods (id, event_id) values
  ('f0000000-0000-0000-0000-000000000001', :LINK), ('f0000000-0000-0000-0000-000000000002', :PRIV),
  ('f0000000-0000-0000-0000-000000000003', :OTHER);
insert into public.participants (id, event_id, pod_id, user_id, display_name, seat) values
  ('a0000000-0000-0000-0000-000000000001', :LINK, 'f0000000-0000-0000-0000-000000000001', :PIA, 'Pia Play', 2),
  ('a0000000-0000-0000-0000-000000000002', :LINK, 'f0000000-0000-0000-0000-000000000001', null, 'Walk In', 1),
  ('a0000000-0000-0000-0000-000000000003', :LINK, 'f0000000-0000-0000-0000-000000000001', :BEA, 'Bea Blocker', 3),
  ('a0000000-0000-0000-0000-000000000004', :PRIV, 'f0000000-0000-0000-0000-000000000002', :PIA, 'Pia Play', 1),
  ('a0000000-0000-0000-0000-000000000005', :OTHER, 'f0000000-0000-0000-0000-000000000003', null, 'Other Guest', 1),
  ('a0000000-0000-0000-0000-000000000006', :DEMO, null, :DEM, 'Dem Demo', 1);
insert into public.participant_tokens (participant_id, token) values
  ('a0000000-0000-0000-0000-000000000002', 'link-guest-token'),
  ('a0000000-0000-0000-0000-000000000005', 'other-guest-token');
insert into public.event_invites (event_id, user_id, source, status, invited_by) values
  (:PRIV, :IVO, 'owner_invite', 'pending', :OLA);
insert into public.rounds (id, event_id, number, status) values
  ('b0000000-0000-0000-0000-000000000001', :LINK, 1, 'active');
insert into public.matches (id, event_id, round_id, table_number) values
  ('c0000000-0000-0000-0000-000000000002', :LINK, 'b0000000-0000-0000-0000-000000000001', 2),
  ('c0000000-0000-0000-0000-000000000001', :LINK, 'b0000000-0000-0000-0000-000000000001', 1);
insert into public.match_sides (match_id, participant_id, side, game_wins) values
  ('c0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 1, 0),
  ('c0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 0, 2),
  ('c0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000003', 0, 0);

-- ==================================================================== event_bundle
set role authenticated;
select pg_temp.as_user(:OLA);
select pg_temp.eq('organizer: bundle access', public.event_bundle(:LINK)->>'access', 'organizer');
select pg_temp.eq('organizer: is_organizer', public.event_bundle(:LINK)->>'is_organizer', 'true');
select pg_temp.eq('bundle: participants by seat',
  (select string_agg(p->>'display_name', ',') from jsonb_array_elements(public.event_bundle(:LINK)->'participants') p),
  'Walk In,Pia Play,Bea Blocker');
select pg_temp.eq('bundle: matches by table, sides by side',
  (select string_agg((m->>'table_number') || ':' || (select string_agg(s->>'side', '') from jsonb_array_elements(m->'match_sides') s), ',')
     from jsonb_array_elements(public.event_bundle(:LINK)->'rounds'->0->'matches') m), '1:01,2:0');
select pg_temp.eq('bundle: rows carry every column clients decode',
  (select (b->'event' ? 'visibility') and (b->'participants'->0 ? 'team_slot') and (b->'rounds'->0 ? 'timer_ends_at')
          and (b->'rounds'->0->'matches'->0 ? 'disputed') and (b->'rounds'->0->'matches'->0->'match_sides'->0 ? 'user_id')
     from public.event_bundle(:LINK) b)::text, 'true');
select pg_temp.eq('bundle: teams', public.event_bundle(:LINK)->>'teams', '[]');
select pg_temp.as_user(:PIA);
select pg_temp.eq('player: bundle access', public.event_bundle(:LINK)->>'access', 'player');
select pg_temp.eq('player: not organizer', public.event_bundle(:LINK)->>'is_organizer', 'false');
select pg_temp.eq('player of a private event sees it', public.event_bundle(:PRIV)->>'access', 'player');
select pg_temp.as_user(:IVO);
select pg_temp.throws('invited: no bundle before joining', $$select public.event_bundle('e0000000-0000-0000-0000-000000000002')$$, '42501');
select pg_temp.as_user(:SAM);
select pg_temp.throws('stranger: no bundle', $$select public.event_bundle('e0000000-0000-0000-0000-000000000001')$$, '42501');
select pg_temp.throws('stranger: missing event reads the same', $$select public.event_bundle(gen_random_uuid())$$, '42501');
select pg_temp.throws('stranger holding another event''s token: no bundle',
  $$select public.event_bundle('e0000000-0000-0000-0000-000000000001', 'other-guest-token')$$, '42501');
reset role;
set role anon;
select pg_temp.as_user(null);
select pg_temp.eq('guest with token: bundle', public.event_bundle(:LINK, 'link-guest-token')->>'access', 'guest');
select pg_temp.throws('anon without token: no bundle', $$select public.event_bundle('e0000000-0000-0000-0000-000000000001')$$, '42501');
select pg_temp.throws('anon with a wrong-event token: no bundle',
  $$select public.event_bundle('e0000000-0000-0000-0000-000000000001', 'other-guest-token')$$, '42501');
select pg_temp.throws('anon with a made-up token: no bundle',
  $$select public.event_bundle('e0000000-0000-0000-0000-000000000001', 'nope')$$, '42501');

-- ==================================================================== get_event_teams
select pg_temp.eq('teams: guest with token', public.get_event_teams(:LINK, 'link-guest-token')::text, '[]');
select pg_temp.throws('teams: anon without token refused', $$select public.get_event_teams('e0000000-0000-0000-0000-000000000001')$$, '42501');
reset role;
set role authenticated;
select pg_temp.as_user(:OLA);
select pg_temp.eq('teams: organizer, old one-argument call', public.get_event_teams(:LINK)::text, '[]');
select pg_temp.as_user(:SAM);
select pg_temp.throws('teams: stranger refused', $$select public.get_event_teams('e0000000-0000-0000-0000-000000000001')$$, '42501');

-- ==================================================================== event_preview
select pg_temp.eq('preview by code: link', public.event_preview('lnk1')->>'access', 'link');
select pg_temp.eq('preview: header only',
  (select string_agg(k, ',' order by k) from jsonb_object_keys(public.event_preview('LNK1')) k),
  'access,capacity,cube_name,event_id,format_label,name,organizer_name,players,set_name,short_code,starts_at,status,venue_name');
select pg_temp.eq('preview: counts and organizer',
  (select format('%s/%s/%s', p->>'players', p->>'organizer_name', p->>'venue_name') from public.event_preview('LNK1') p),
  '3/Ola Org/Card Shop');
select pg_temp.eq('preview by id: link', public.event_preview(null, :LINK)->>'access', 'link');
select pg_temp.eq('preview: private event by code is none for a stranger', public.event_preview('PRV1')::text,
  '{"access": "none", "event_id": null}');
select pg_temp.eq('preview: private event by id is none for a stranger', public.event_preview(null, :PRIV)->>'access', 'none');
select pg_temp.eq('preview: finished event''s code no longer resolves', public.event_preview('DNE1')->>'access', 'none');
select pg_temp.eq('preview: cancelled event is none', public.event_preview(null, :GONE)->>'access', 'none');
select pg_temp.eq('preview: demo event is none', public.event_preview(null, :DEMO)->>'access', 'none');
select pg_temp.eq('preview: unknown code is none', public.event_preview('ZZZZ')->>'access', 'none');
select pg_temp.as_user(:IVO);
select pg_temp.eq('preview: invited sees the private event', public.event_preview('PRV1')->>'access', 'invited');
select pg_temp.as_user(:OLA);
select pg_temp.eq('preview: organizer sees a finished event by id', public.event_preview(null, :DONE)->>'access', 'organizer');
select pg_temp.as_user(:PIA);
select pg_temp.eq('preview: demo owner sees the demo event', public.event_preview(null, :DEMO)->>'access', 'organizer');
reset role;
set role anon;
select pg_temp.as_user(null);
select pg_temp.eq('preview: anon by code', public.event_preview('LNK1')->>'access', 'link');

-- ==================================================================== event_public
select pg_temp.eq('public: anon with the link', public.event_public(:LINK)->>'access', 'link');
select pg_temp.eq('public: pairings by name, by table',
  (select string_agg((m->>'table_number') || ':' ||
            (select string_agg(s->>'display_name', ' v ' order by (s->>'side')::int) from jsonb_array_elements(m->'sides') s), ',')
     from jsonb_array_elements(public.event_public(:LINK)->'pairings') m),
  '1:Pia Play v Walk In,2:Bea Blocker');
select pg_temp.eq('public: no account ids',
  (select count(*)::text from jsonb_path_query(public.event_public(:LINK), 'strict $.**.user_id')), '0');
select pg_temp.eq('public: the active round', public.event_public(:LINK)->'round'->>'number', '1');
select pg_temp.throws('public: private event refused', $$select public.event_public('e0000000-0000-0000-0000-000000000002')$$, '42501');
select pg_temp.throws('public: cancelled event refused', $$select public.event_public('e0000000-0000-0000-0000-000000000005')$$, '42501');
select pg_temp.eq('public: finished non-private event still shows (final standings)', public.event_public(:DONE)->>'access', 'link');
reset role;
set role authenticated;
select pg_temp.as_user(:PIA);
select pg_temp.eq('public: player of the private event', public.event_public(:PRIV)->>'access', 'player');

-- ==================================================================== rate limits
reset role;
set role anon;
select pg_temp.as_user(null);
select set_config('request.headers', '{"x-forwarded-for": "203.0.113.7, 10.0.0.1"}', false);
do $$ begin
  for i in 1..60 loop perform public.event_preview('Q' || lpad(i::text, 3, '0')); end loop;
end $$;
select pg_temp.throws('60 misses from one address: code lookups stop', $$select public.event_preview('LNK1')$$, '53400');
select pg_temp.eq('lookups by id are not limited', public.event_preview(null, 'e0000000-0000-0000-0000-000000000001')->>'access', 'link');
select set_config('request.headers', '{"x-forwarded-for": "198.51.100.9"}', false);
select pg_temp.eq('another address is unaffected', public.event_preview('LNK1')->>'access', 'link');
select set_config('request.headers', '', false);
reset role;
delete from t1_private.rate_hits;   -- Sam's earlier misses (private, finished, unknown codes) count too
set role authenticated;
select pg_temp.as_user(:SAM);
do $$ begin
  for i in 1..20 loop perform public.join_event('W' || lpad(i::text, 3, '0'), 'Sam'); end loop;
end $$;
select pg_temp.throws('20 misses from one account: joins by code stop', $$select public.join_event('LNK1', 'Sam')$$, '53400');
select pg_temp.throws('and previews by code too', $$select public.event_preview('LNK1')$$, '53400');
reset role;
delete from t1_private.rate_hits;

-- ==================================================================== join_event
set role authenticated;
select pg_temp.as_user(:SAM);
select pg_temp.eq('join: private event needs an invite', public.join_event('PRV1', 'Sam')->>'error', 'private');
select pg_temp.eq('join: finished event', public.join_event('DNE1', 'Sam')->>'message', 'That event has already finished');
select pg_temp.eq('join: cancelled event', public.join_event('GNE1', 'Sam')->>'error', 'cancelled');
select pg_temp.eq('join: unknown code', public.join_event('ZZZZ', 'Sam')->>'message', 'No event found with that code');
select pg_temp.throws('join: a name is required', $$select public.join_event('LNK1', ' ')$$);
select pg_temp.as_user(:IVO);
select pg_temp.eq('join: invited account joins the private event by code',
  (select (j->>'event_id') || '/' || coalesce(j->>'already_joined', 'new') from public.join_event('prv1', 'Ivo') j),
  'e0000000-0000-0000-0000-000000000002/new');
select pg_temp.as_user(:PIA);
select pg_temp.eq('join: an account already in the event gets its seat back',
  (select (j->>'participant_id') || '/' || (j->>'already_joined') from public.join_event('LNK1', 'Pia again') j),
  'a0000000-0000-0000-0000-000000000001/true');
reset role;
select pg_temp.eq('join: no second seat for Pia',
  (select count(*)::text from public.participants where event_id = :LINK and user_id = :PIA), '1');
select pg_temp.eq('join: a refused code wrote nothing',
  (select count(*)::text from public.participants where display_name = 'Sam'), '0');
set role anon;
select pg_temp.as_user(null);
select pg_temp.eq('join: a signed-out guest gets a seat and a token',
  (select (length(j->>'token') = 32)::text from public.join_event('LNK1', 'New Guest') j), 'true');
reset role;

-- ==================================================================== people
set role authenticated;
select pg_temp.as_user(:PIA);
select pg_temp.eq('people: self, shared event, friend, request, public',
  (select string_agg(p->>'display_name', ',' order by p->>'display_name')
     from jsonb_array_elements(public.people(array[:PIA, :OLA, :FAY, :REX, :PUB, :SAM, :BEA, :BO, :DEL, :DEM, gen_random_uuid()]::uuid[])) p),
  'Dem Demo,Fay Friend,Ola Org,Pia Play,Pub Lic,Rex Request');
select pg_temp.eq('people: rows carry name, handle, avatar',
  (select string_agg(k, ',' order by k) from jsonb_object_keys(public.people(array[:OLA]::uuid[])->0) k),
  'avatar_url,display_name,handle,user_id');
select pg_temp.as_user(:SAM);
select pg_temp.eq('people: a stranger sees only public profiles',
  (select string_agg(p->>'display_name', ',' order by p->>'display_name')
     from jsonb_array_elements(public.people(array[:PIA, :OLA, :PUB, :BO, :DEM]::uuid[])) p), 'Bo Blocked,Pub Lic');
select pg_temp.as_user(:BEA);
select pg_temp.eq('people: a blocker doesn''t see the one they blocked, even in a shared event',
  (select string_agg(p->>'display_name', ',' order by p->>'display_name')
     from jsonb_array_elements(public.people(array[:PIA, :OLA]::uuid[])) p), 'Ola Org');
reset role;
insert into public.event_invites (event_id, user_id, source, status, invited_by) values (:LINK, :FAY, 'owner_invite', 'pending', :OLA);
set role authenticated;
select pg_temp.as_user(:FAY);
select pg_temp.eq('people: an invite links the invited account to the organizers, not the players',
  (select string_agg(p->>'display_name', ',' order by p->>'display_name')
     from jsonb_array_elements(public.people(array[:OLA, :BEA]::uuid[])) p), 'Ola Org');
select pg_temp.eq('people: empty and null lists', public.people('{}')::text || public.people(null)::text, '[][]');
select pg_temp.throws('people: at most 500 ids',
  $$select public.people(array(select gen_random_uuid() from generate_series(1, 501)))$$, '22023');
reset role;
set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('people: anon refused', $$select public.people(array[gen_random_uuid()])$$, '42501');
reset role;

-- ==================================================================== pings
truncate realtime.sent;
update public.rounds set timer_status = 'running' where event_id = :LINK;
select pg_temp.eq('one write, one ping, public, no data',
  (select string_agg(format('%s/%s/%s/%s', topic, event, payload, private), ',') from realtime.sent),
  'event:e0000000-0000-0000-0000-000000000001/changed/{}/f');
truncate realtime.sent;
update public.participants set status = status where event_id in (:LINK, :OTHER);
select pg_temp.eq('one statement over two events: one ping each',
  (select string_agg(topic, ',' order by topic) from realtime.sent),
  'event:e0000000-0000-0000-0000-000000000001,event:e0000000-0000-0000-0000-000000000003');
truncate realtime.sent;
insert into public.match_sides (match_id, participant_id, side) values
  ('c0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 1);
delete from public.match_sides where match_id = 'c0000000-0000-0000-0000-000000000002' and side = 1;
update public.events set name = 'Tuesday Modern II' where id = :LINK;
select pg_temp.eq('insert, delete and events rows ping too', (select count(*)::text from realtime.sent), '3');

-- ==================================================================== records
set role authenticated;
select pg_temp.as_user(:PIA);
select pg_temp.throws('match_outcomes not readable by clients', $$select count(*) from public.match_outcomes$$, '42501');
select pg_temp.throws('event_results not readable by clients', $$select count(*) from public.event_results$$, '42501');
select pg_temp.throws('standings_snapshots not readable by clients', $$select count(*) from public.standings_snapshots$$, '42501');
select pg_temp.throws('head_to_head not readable by clients', $$select count(*) from public.head_to_head$$, '42501');
select pg_temp.eq('your own profile still shows your record', ((public.profile_view(:PIA)->'sections') ? 'record')::text, 'true');
reset role;
set role anon;
select pg_temp.throws('anon: player_records not readable', $$select count(*) from public.player_records$$, '42501');
reset role;
