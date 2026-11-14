-- Public events, kept final places, leagues and format boards (20261113120000_public_events_leagues.sql;
-- contract/public-events-leagues-2026-11-13.md). The season is shaped like MMS: points by place, winners qualify
-- with pass-down, the top N on points qualify too.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000073a1', 'ana@example.com', '{"full_name": "Ana Org"}'),
  ('00000000-0000-0000-0000-0000000073b1', 'bea@example.com', '{"full_name": "Bea"}'),
  ('00000000-0000-0000-0000-0000000073c1', 'cal@example.com', '{"full_name": "Cal"}'),
  ('00000000-0000-0000-0000-0000000073d1', 'dee@example.com', '{"full_name": "Dee"}'),
  ('00000000-0000-0000-0000-0000000073e1', 'eve@example.com', '{"full_name": "Eve"}'),
  ('00000000-0000-0000-0000-0000000073f1', 'fay@example.com', '{"full_name": "Fay"}'),
  ('00000000-0000-0000-0000-000000007301', 'gil@example.com', '{"full_name": "Gil"}'),
  ('00000000-0000-0000-0000-000000007302', 'sam@example.com', '{"full_name": "Sam Stranger"}'),
  ('00000000-0000-0000-0000-000000007303', 'kit@example.com', '{"full_name": "Kit Blocked"}'),
  ('00000000-0000-0000-0000-000000007304', 'hoi@example.com', '{"full_name": "Hoi Host"}');
\set A '''00000000-0000-0000-0000-0000000073a1'''
\set B '''00000000-0000-0000-0000-0000000073b1'''
\set C '''00000000-0000-0000-0000-0000000073c1'''
\set D '''00000000-0000-0000-0000-0000000073d1'''
\set E '''00000000-0000-0000-0000-0000000073e1'''
\set F '''00000000-0000-0000-0000-0000000073f1'''
\set G '''00000000-0000-0000-0000-000000007301'''
\set S '''00000000-0000-0000-0000-000000007302'''
\set K '''00000000-0000-0000-0000-000000007303'''
\set H '''00000000-0000-0000-0000-000000007304'''
\set E1 '''e0000000-0000-0000-0000-000000007301'''
\set E2 '''e0000000-0000-0000-0000-000000007302'''
\set E3 '''e0000000-0000-0000-0000-000000007303'''
\set E4 '''e0000000-0000-0000-0000-000000007304'''
\set EP '''e0000000-0000-0000-0000-000000007305'''
\set ED '''e0000000-0000-0000-0000-000000007306'''
\set EH '''e0000000-0000-0000-0000-000000007307'''
\set ES '''e0000000-0000-0000-0000-000000007308'''
\set EF '''e0000000-0000-0000-0000-000000007309'''

-- Ana runs two Opens under way, an upcoming one, a later one, a private night, a demo night and a small pod;
-- Hoi (not in the league) runs one of her own.
insert into public.events (id, short_code, name, created_by, status, current_round, number_of_rounds, visibility, is_demo, starts_at, format_name, format) values
  (:E1, 'MMSMOD', 'Modern Open', :A, 'in_progress', 5, 5, 'link_only', false, now() - interval '30 days', 'modern', 'constructed'),
  (:E2, 'MMSLEG', 'Legacy Open', :A, 'in_progress', 5, 5, 'link_only', false, now() - interval '10 days', 'legacy', 'constructed'),
  (:E3, 'MMSPAU', 'Pauper Open', :A, 'setup', 0, 5, 'link_only', false, now() + interval '9 days', 'pauper', 'constructed'),
  (:E4, 'MMSSTD', 'Standard Open', :A, 'in_progress', 5, 5, 'link_only', false, now() - interval '2 days', 'standard', 'constructed'),
  (:EP, 'MMSPRV', 'Private night', :A, 'completed', 3, 3, 'private', false, null, 'modern', 'constructed'),
  (:ED, 'MMSDEM', 'Demo night', :A, 'setup', 0, 3, 'link_only', true, null, 'modern', 'constructed'),
  (:ES, 'MMSPOD', 'Small pod', :A, 'completed', 3, 3, 'public', false, null, 'modern', 'constructed'),
  (:EH, 'HOIDRF', 'Hoi''s draft', :H, 'setup', 0, 3, 'link_only', false, now() + interval '3 days', 'draft', 'draft'),
  (:EF, 'MMSFRI', 'Friends night', :A, 'setup', 0, 3, 'link_only', false, now() + interval '1 day', 'modern', 'constructed');
update public.events set capacity = 2 where id = :EF;
insert into public.friendships (user_lo, user_hi, requested_by, status) values (:A, :C, :A, 'accepted');
insert into public.event_members (event_id, user_id, role)
select id, created_by, 'owner' from public.events where short_code like 'MMS%' or short_code = 'HOIDRF';
insert into public.user_blocks (user_id, blocked_id) values (:A, :K);

-- Eight players in the Modern and Legacy Opens: six accounts and two guests (one name typed two ways).
insert into public.participants (id, event_id, user_id, display_name, seat)
select ('a0000000-0000-0000-0000-0000000073' || e.n || p.n)::uuid, e.id, p.uid, p.name, p.n
  from (values (:E1::uuid, '1'), (:E2::uuid, '2'), (:E4::uuid, '4')) e(id, n),
       (values (1, :B::uuid, 'Bea'), (2, :C::uuid, 'Cal'), (3, :D::uuid, 'Dee'), (4, :E::uuid, 'Eve'),
               (5, :F::uuid, 'Fay'), (6, :G::uuid, 'Gil'), (7, null, 'Gus Guest'), (8, null, 'Hal Guest')) p(n, uid, name);
update public.participants set display_name = '  gus   guest ' where id = 'a0000000-0000-0000-0000-000000007327';
insert into public.participants (event_id, user_id, display_name, seat) values (:E3, :B, 'Bea', 1), (:ES, :B, 'Bea', 1), (:ES, :C, 'Cal', 2),
  (:EF, :D, 'Dee', 1), (:EF, :E, 'Eve', 2);

create or replace function pg_temp.pushes(p_kind text) returns text language sql security definer as $$
  select coalesce(string_agg(x, ',' order by x), '-') from (
    select (select string_agg(right(u, 2), '+' order by u) from jsonb_array_elements_text(m.msg->'user_ids') u) x
      from pgmq.messages m where m.msg->>'kind' = p_kind) s $$;
create or replace function pg_temp.asks(p_event uuid) returns text language sql security definer as $$
  select count(*)::text from net.requests r where r.url like '%/events-engine' and r.body->>'event_id' = p_event::text
     and r.body->>'action' = 'placements' $$;
-- The places the engine would hand in: p_order lists seats (1 Bea … 8 Hal) from first to last.
create or replace function pg_temp.place(p_event uuid, p_n text, p_order int[]) returns jsonb language sql security definer as $$
  select public.event_placements_put(p_event, (
    select jsonb_agg(jsonb_build_object('participant_id', 'a0000000-0000-0000-0000-0000000073' || p_n || s.seat,
                                        'place', s.place, 'match_wins', greatest(0, 5 - s.place), 'match_points', 3 * greatest(0, 5 - s.place)))
      from unnest(p_order) with ordinality s(seat, place))) $$;
grant execute on function pg_temp.pushes(text), pg_temp.asks(uuid), pg_temp.place(uuid, text, int[]) to anon, authenticated;

-- ==================================================================== describing and listing
set role authenticated;
select pg_temp.as_user(:S);
select pg_temp.throws('a stranger can''t describe an event', format('select public.event_listing_set(%L, %L)', :E3, '{"description": "x"}'), '42501');
select pg_temp.as_user(:A);
select pg_temp.eq('describe, address, public',
  public.event_listing_set(:E3, '{"description": "  Competitive REL.\nDecklists required.  ", "venue_address": "6835 S Dayton St,   Greenwood Village", "find": "public", "lat": 39.5954, "lng": -104.8771}')::text,
  '{"visibility": "public", "description": "Competitive REL.\nDecklists required.", "venue_address": "6835 S Dayton St, Greenwood Village"}');
select pg_temp.eq('the same again writes no second audit row',
  (select public.event_listing_set(:E3, '{"find": "public"}')->>'visibility') ||
  (select count(*)::text from public.audit_log where event_id = :E3 and action = 'event.listing_updated'), 'public1');
select pg_temp.throws('a long description is refused', format('select public.event_listing_set(%L, jsonb_build_object(''description'', repeat(''x'', 2001)))', :E3), '22023');
select pg_temp.throws('demo events can''t be listed', format('select public.event_listing_set(%L, %L)', :ED, '{"find": "public"}'), '22023');
select pg_temp.throws('bad coordinates', format('select public.event_listing_set(%L, %L)', :E3, '{"lat": 139, "lng": 0}'), '22023');
select pg_temp.eq('the other Opens go public too',
  (public.event_listing_set(:E1, '{"find": "public"}')->>'visibility') || (public.event_listing_set(:E2, '{"find": "public"}')->>'visibility')
  || (public.event_listing_set(:E4, '{"find": "public"}')->>'visibility'), 'publicpublicpublic');
select pg_temp.as_user(:H);
select pg_temp.eq('Hoi lists her draft', public.event_listing_set(:EH, '{"find": "public", "lat": 40.0150, "lng": -105.2705}')->>'visibility', 'public');
select pg_temp.eq('public off goes back to link only', public.event_listing_set(:EH, '{"find": "private"}')->>'visibility', 'link_only');
select pg_temp.eq('and on again', public.event_listing_set(:EH, '{"find": "public"}')->>'visibility', 'public');

set role anon;
select pg_temp.as_user(null);
select pg_temp.eq('signed out: upcoming and running public events, soonest first',
  (select string_agg(x->>'name', ' | ') from jsonb_array_elements(public.find_events()) x),
  'Hoi''s draft | Pauper Open');
select pg_temp.eq('by format', (select string_agg(x->>'name', ' | ') from jsonb_array_elements(public.find_events('{"formats": ["pauper", "modern"]}')) x), 'Pauper Open');
select pg_temp.eq('format keys, who runs it, how it is listed',
  (select string_agg((x->>'format_key') || ' ' || (x->>'organizer') || ' ' || (x->>'visibility'), ', ') from jsonb_array_elements(public.find_events()) x),
  'limited Hoi Host public, pauper Ana Org public');
select pg_temp.eq('distance in km from a place given, never stored',
  (select string_agg((x->>'name') || ' ' || (x->>'km'), ' | ') from jsonb_array_elements(public.find_events('{"lat": 39.7392, "lng": -104.9903}')) x),
  'Hoi''s draft 39 | Pauper Open 19');
select pg_temp.eq('within 25 km', (select string_agg(x->>'name', ' | ') from jsonb_array_elements(public.find_events('{"lat": 39.7392, "lng": -104.9903, "km": 25}')) x), 'Pauper Open');
select pg_temp.eq('by words in the name, venue or address', (select string_agg(x->>'name', ' | ') from jsonb_array_elements(public.find_events('{"q": "greenwood"}')) x), 'Pauper Open');
select pg_temp.eq('by when it starts',
  (select string_agg(x->>'name', ' | ') from jsonb_array_elements(public.find_events(jsonb_build_object('from', now() + interval '5 days', 'to', now() + interval '14 days'))) x), 'Pauper Open');
select pg_temp.eq('team events only: none yet', public.find_events('{"team": true}')::text, '[]');
select pg_temp.eq('signed out never sees friends'' events', (select count(*)::text from jsonb_array_elements(public.find_events()) x where x->>'visibility' = 'friends'), '0');
select pg_temp.throws('a bad filter is refused', $$select public.find_events('{"km": "far"}')$$, '22023');
select pg_temp.eq('signed out has no me', ((public.find_events()->1->>'me') is null)::text, 'true');
select pg_temp.eq('about: the description and address', public.event_about(:E3)->>'venue_address', '6835 S Dayton St, Greenwood Village');
select pg_temp.throws('about: a private event stays closed', format('select public.event_about(%L)', :EP), '42501');
select pg_temp.throws('anon can''t list an event', format('select public.event_listing_set(%L, %L)', :E3, '{"find": "public"}'), '42501');
select pg_temp.throws('anon reads no league tables', 'select count(*) from public.leagues', '42501');
select pg_temp.throws('anon reads no places', 'select count(*) from public.event_placements', '42501');

set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.eq('Bea is marked a player', public.find_events('{"formats": ["pauper"]}')->0->>'me', 'player');
-- Friends: Ana lists a night for her friends. Cal is her friend; Sam isn't.
select pg_temp.as_user(:A);
select pg_temp.eq('list for friends', public.event_listing_set(:EF, '{"find": "friends"}')->>'visibility', 'friends');
select pg_temp.eq('you see your own friends event', (select string_agg(x->>'name', ' | ') from jsonb_array_elements(public.find_events('{"scope": "friends"}')) x), 'Friends night');
select pg_temp.as_user(:C);
select pg_temp.eq('a friend finds it with the public ones',
  (select string_agg((x->>'name') || ' ' || (x->>'visibility'), ' | ') from jsonb_array_elements(public.find_events()) x),
  'Friends night friends | Hoi''s draft public | Pauper Open public');
select pg_temp.eq('only seats left: the full friends night drops out',
  (select string_agg(x->>'name', ' | ') from jsonb_array_elements(public.find_events('{"open": true}')) x), 'Hoi''s draft | Pauper Open');
select pg_temp.eq('public only', (select string_agg(x->>'name', ' | ') from jsonb_array_elements(public.find_events('{"scope": "public"}')) x), 'Hoi''s draft | Pauper Open');
select pg_temp.as_user(:S);
select pg_temp.eq('someone who isn''t a friend doesn''t', (select string_agg(x->>'name', ' | ') from jsonb_array_elements(public.find_events()) x), 'Hoi''s draft | Pauper Open');
select pg_temp.eq('its link still opens, as for any unlisted event', public.event_about(:EF)->>'visibility', 'friends');
select pg_temp.as_user(:A);
select pg_temp.eq('private unlists it', public.event_listing_set(:EF, '{"find": "private"}')->>'visibility', 'link_only');
select pg_temp.eq('private leaves an invitation-only event as it is', public.event_listing_set(:EP, '{"find": "private"}')->>'visibility', 'private');
select pg_temp.throws('find is one of three', format('select public.event_listing_set(%L, %L)', :EF, '{"find": "everyone"}'), '22023');
select pg_temp.as_user(:K);
select pg_temp.eq('someone Ana blocked doesn''t see her events', (select string_agg(x->>'name', ' | ') from jsonb_array_elements(public.find_events()) x), 'Hoi''s draft');
select pg_temp.throws('signed in reads no league tables either', 'select count(*) from public.league_events', '42501');
select pg_temp.throws('only the engine hands in places', format('select public.event_placements_put(%L, %L)', :E1, '[]'), '42501');

-- ==================================================================== a league and its season
set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('anon can''t make a league', $$select public.league_create('Nope')$$, '42501');
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.eq('create: you own it, the address comes from the name',
  (select (l->>'slug') || ' / ' || (l->>'name') || ' / ' || (l->'organizers')::text
     from public.league_create('  The Mountain   Magic Series ', 'A monthly tournament series for Denver.', 'Denver, Colorado', 'https://discord.gg/example') l),
  'the-mountain-magic-series / The Mountain Magic Series / ["Ana Org"]');
reset role;
select id as "L" from public.leagues where slug = 'the-mountain-magic-series' \gset
set role authenticated;
select pg_temp.eq('a second league of the same name gets its own address', public.league_create('The Mountain Magic Series')->>'slug', 'the-mountain-magic-series-2');
select pg_temp.eq('a third', public.league_create('Third')->>'slug', 'third');
select pg_temp.throws('three leagues an account', $$select public.league_create('Fourth league')$$, '53400');
select pg_temp.throws('an unknown league can''t be changed', $$select public.league_update('00000000-0000-0000-0000-000000000000', '{}')$$, '42501');
select pg_temp.throws('a bad link is refused', format('select public.league_update(%L, %L)', :'L', '{"link": "ftp://x"}'), '22023');
select pg_temp.eq('update', public.league_update(:'L', '{"region": "Denver and its neighbors"}')->>'region', 'Denver and its neighbors');
select pg_temp.as_user(:S);
select pg_temp.throws('a stranger can''t change the league', format('select public.league_update(%L, %L)', :'L', '{"name": "Mine now"}'), '42501');
select pg_temp.throws('or its seasons', format('select public.league_season_set(%L, null, %L)', :'L', '{"name": "x"}'), '42501');
select pg_temp.throws('or its organizers', format('select public.league_member_set(%L, %L, %L)', :'L', :S, 'owner'), '42501');

select pg_temp.as_user(:A);
select pg_temp.throws('a rule with no points is refused',
  format('select public.league_season_set(%L, null, %L)', :'L', '{"name": "2026", "starts_on": "2026-01-01", "ends_on": "2026-12-31", "points": {"places": []}}'), '22023');
select pg_temp.throws('brackets must go up',
  format('select public.league_season_set(%L, null, %L)', :'L', '{"name": "2026", "starts_on": "2026-01-01", "ends_on": "2026-12-31", "points": {"places": [{"through": 4, "points": 8}, {"through": 2, "points": 10}]}}'), '22023');
select pg_temp.throws('a season needs its dates',
  format('select public.league_season_set(%L, null, %L)', :'L', '{"name": "2026", "points": {"participation": 1}}'), '22023');
select public.league_season_set(:'L', null, '{"name": "2026", "starts_on": "2026-01-01", "ends_on": "2026-12-31",
  "points": {"places": [{"through": 1, "points": 12}, {"through": 2, "points": 10}, {"through": 4, "points": 8}, {"through": 8, "points": 6}, {"through": 16, "points": 3}], "participation": 1},
  "qualify": {"winners": true, "top": 2}}')->>'id' as "SE" \gset
reset role;
select pg_temp.eq('the season keeps a cleaned rule',
  (select (points->>'participation') || ' ' || (points->>'match_win') || ' ' || jsonb_array_length(points->'places') || ' ' || (qualify->>'pass_down')
     from public.league_seasons where id = :'SE'), '1 0 5 true');
select pg_temp.throws('one season a name', format('select public.league_season_set(%L, null, %L)', :'L', '{"name": "2026", "starts_on": "2027-01-01", "ends_on": "2027-12-31", "points": {"participation": 1}}'), '23505');
select pg_temp.eq('place points: 1st 12, 3rd 8, 9th 3, 40th participation',
  (select string_agg(t1_private.league_place_points(points, p)::text, ',' order by p) from public.league_seasons, unnest(array[1, 3, 9, 40]) p where id = :'SE'), '12,8,3,1');
set role authenticated;

-- Sam follows before any event is added.
select pg_temp.as_user(:S);
select pg_temp.eq('follow', public.league_follow_set(:'L', true)::text, '{"notify": true, "following": true}');

-- ==================================================================== events into the season
select pg_temp.throws('a stranger can''t add an event', format('select public.league_event_set(%L, %L)', :E3, :'SE'), '42501');
select pg_temp.as_user(:H);
select pg_temp.throws('an event''s organizer who isn''t the league''s can''t add it', format('select public.league_event_set(%L, %L)', :EH, :'SE'), '42501');
select pg_temp.as_user(:A);
select pg_temp.throws('private events can''t be in a league', format('select public.league_event_set(%L, %L)', :EP, :'SE'), '22023');
select pg_temp.throws('the multiplier is 1 to 5', format('select public.league_event_set(%L, %L, 7)', :E3, :'SE'), '22023');
select pg_temp.eq('add the upcoming Open', public.league_event_set(:E3, :'SE')->'league'->>'name', 'The Mountain Magic Series');
select pg_temp.eq('its sign-ups follow the league, and followers hear once (not Ana, who added it)', pg_temp.pushes('league.event'), '02+b1');
select pg_temp.eq('adding it again says nothing new', (select (public.league_event_set(:E3, :'SE', 1)->'league'->>'season') || pg_temp.pushes('league.event')), '202602+b1');
select pg_temp.eq('the listing names the league', public.find_events('{"formats": ["pauper"]}')->0->'league'->>'slug', 'the-mountain-magic-series');
select pg_temp.eq('add the three running Opens',
  (public.league_event_set(:E1, :'SE')->'league'->>'season') || (public.league_event_set(:E2, :'SE')->'league'->>'season')
  || (public.league_event_set(:E4, :'SE')->'league'->>'season'), '202620262026');
select pg_temp.eq('running events aren''t announced', pg_temp.pushes('league.event'), '02+b1');

-- ==================================================================== finishing asks the engine for places
reset role;
update public.events set status = 'completed' where id = :E1;
select pg_temp.eq('finishing an event asks the engine once', pg_temp.asks(:E1), '1');
select pg_temp.eq('a job waits for the answer', (select tries::text || (done_at is null)::text from t1_private.placement_jobs where event_id = :E1), '1true');
update public.events set status = 'setup' where id = :ED;
select pg_temp.eq('demo events aren''t asked about', pg_temp.asks(:ED), '0');
select pg_temp.eq('places before the event is over are skipped', pg_temp.place(:E2, '2', array[2, 1, 7, 3, 4, 5, 6, 8])->>'skipped', 'true');
update public.events set status = 'completed' where id in (:E2, :E4);

-- Modern: Bea, Cal, Dee, Eve, Fay, Gil, Gus, Hal. Legacy: Cal, Bea, Gus, Dee, Eve, Fay, Gil, Hal.
select pg_temp.eq('Modern Open placed', pg_temp.place(:E1, '1', array[1, 2, 3, 4, 5, 6, 7, 8])->>'placed', '8');
select pg_temp.eq('the job is done', (select (done_at is not null)::text from t1_private.placement_jobs where event_id = :E1), 'true');
select pg_temp.eq('names and accounts come from the participants', (select name || ' ' || (user_id = :B)::text from public.event_placements where event_id = :E1 and place = 1), 'Bea true');
select pg_temp.eq('results go to the league once: followers and players, not the blocked',
  pg_temp.pushes('league.results'), '01+02+a1+b1+c1+d1+e1+f1');
select pg_temp.eq('the winner hears they qualified', pg_temp.pushes('league.qualified'), 'b1');
select pg_temp.eq('placing again sends nothing more', (pg_temp.place(:E1, '1', array[1, 2, 3, 4, 5, 6, 7, 8])->>'placed') || pg_temp.pushes('league.results') || pg_temp.pushes('league.qualified'),
  '801+02+a1+b1+c1+d1+e1+f1b1');
select pg_temp.eq('Legacy Open placed', pg_temp.place(:E2, '2', array[2, 1, 7, 3, 4, 5, 6, 8])->>'placed', '8');

-- ==================================================================== standings
set role anon;
select pg_temp.as_user(null);
select pg_temp.eq('standings: points, ties by best finishes then name, guests merged by name',
  (select string_agg((r->>'rank') || ' ' || (r->>'name') || ' ' || (r->>'points') || coalesce(' ' || (r->>'qualified'), ''), ' | ')
     from jsonb_array_elements(public.league_view('the-mountain-magic-series')->'standings') r),
  '1 Bea 22 winner | 1 Cal 22 winner | 3 Dee 16 points | 4 gus guest 14 points | 5 Eve 14 | 6 Fay 12 | 7 Gil 12 | 8 Hal Guest 12');
select pg_temp.eq('signed out: names, no accounts', (select count(*)::text from jsonb_array_elements(public.league_view('the-mountain-magic-series')->'standings') r where r->>'user_id' is not null), '0');
select pg_temp.eq('the page: league, season, events with winners',
  (select (v->'league'->>'name') || ' / ' || (v->'season'->>'name') || ' ' || (v->'season'->>'state') || ' / ' || (v->>'standings_count') || ' / ' ||
          (select string_agg((e->>'name') || coalesce(' ' || (e->>'winner'), ''), ', ') from jsonb_array_elements(v->'events') e)
     from public.league_view('the-mountain-magic-series') v),
  'The Mountain Magic Series / 2026 active / 8 / Modern Open Bea, Legacy Open Cal, Standard Open, Pauper Open');
select pg_temp.eq('by id too', public.league_view(:'L')->'league'->>'slug', 'the-mountain-magic-series');
select pg_temp.throws('an unknown league', $$select public.league_view('nope')$$, 'P0002');
select pg_temp.eq('a page of the table', (select string_agg(r->>'name', ',') from jsonb_array_elements(public.league_standings(:'SE', 2, 2)) r), 'Dee,gus guest');
select pg_temp.eq('a player, event by event',
  (select (v->'player'->>'points') || ' / ' || (select string_agg((e->>'name') || ' ' || (e->>'place') || ' ' || (e->>'points'), ', ') from jsonb_array_elements(v->'events') e)
     from public.league_player(:'SE', 'g:gus guest') v), '14 / Legacy Open 3 8, Modern Open 7 6');
set role authenticated;
select pg_temp.as_user(:D);
select pg_temp.eq('signed in: your row and people''s accounts',
  (select (v->'my_row'->>'rank') || ' ' || (v->'my_row'->>'points') || ' ' || (v->'me'->>'following') || ' ' || (v->'standings'->0->>'user_id' is not null)::text
     from public.league_view(:'L') v), '3 16 true true');

-- Bea wins the Standard Open too: her invite passes down to the best finisher not yet qualified (Dee, 2nd).
reset role;
select pg_temp.eq('Standard Open placed', pg_temp.place(:E4, '4', array[1, 3, 5, 6, 2, 4, 7, 8])->>'placed', '8');
select pg_temp.eq('pass-down: Dee qualifies as a winner, the next two on points',
  (select string_agg(t.name || ' ' || t.points || coalesce(' ' || t.qualified, ''), ' | ' order by t.ord) from t1_private.league_table(:'SE') t where t.ord <= 5),
  'Bea 34 winner | Cal 28 winner | Dee 26 winner | Fay 20 points | Gus Guest 20 points');
select pg_temp.eq('only the newly qualified hear it', pg_temp.pushes('league.qualified'), 'b1,c1,d1');

-- Best N, a multiplier and points per match win.
update public.league_seasons set best_n = 1 where id = :'SE';
select pg_temp.eq('best 1: each player''s best event', (select string_agg(t.name || ' ' || t.points, ', ' order by t.ord) from t1_private.league_table(:'SE') t where t.ord <= 3), 'Bea 12, Cal 12, Dee 10');
update public.league_seasons set best_n = null where id = :'SE';
update public.league_events set multiplier = 2 where event_id = :E2;
select pg_temp.eq('a 2x event doubles its points', (select t.points::text from t1_private.league_table(:'SE') t where t.name = 'Cal'), '40');
update public.league_events set multiplier = 1 where event_id = :E2;
update public.league_seasons set points = points || '{"match_win": 1}' where id = :'SE';
select pg_temp.eq('a point per match win on top', (select t.points::text from t1_private.league_table(:'SE') t where t.name = 'Bea'), '45');
update public.league_seasons set points = points || '{"match_win": 0}' where id = :'SE';
update public.league_events set final = true where event_id = :E4;
select pg_temp.eq('the season''s final earns no points', (select t.points::text from t1_private.league_table(:'SE') t where t.name = 'Bea'), '22');
update public.league_events set final = false where event_id = :E4;

-- ==================================================================== follows
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.eq('players follow the league already', (public.league_view(:'L')->'me')::text, '{"role": null, "notify": true, "following": true}');
select pg_temp.eq('notifications off', public.league_follow_set(:'L', true, false)::text, '{"notify": false, "following": true}');
select pg_temp.eq('unfollow', public.league_follow_set(:'L', false)::text, '{"notify": false, "following": false}');
select pg_temp.eq('home: Bea follows nothing now', (public.leagues_home()->'following')::text, '[]');
select pg_temp.as_user(:S);
select pg_temp.eq('home: Sam follows it, with its next event',
  (select (c->>'name') || ' / ' || (c->>'season') || ' / ' || (c->'next_event'->>'name') from jsonb_array_elements(public.leagues_home()->'following') c),
  'The Mountain Magic Series / 2026 / Pauper Open');
select pg_temp.eq('find by region', (select string_agg(c->>'slug', ',') from jsonb_array_elements(public.leagues_home('denver')->'found') c), 'the-mountain-magic-series');
select pg_temp.as_user(:A);
select pg_temp.eq('home: Ana runs three', jsonb_array_length(public.leagues_home()->'mine')::text, '3');

-- A season closes: final standings to those still listening, and the points qualifiers hear it.
select pg_temp.eq('close the season', public.league_season_set(:'L', :'SE', '{"closed": true}')->>'state', 'over');
select pg_temp.eq('season push: followers with notifications on and organizers (Bea unfollowed)', pg_temp.pushes('league.season'), '01+02+a1+c1+d1+e1+f1');
select pg_temp.eq('points qualifiers hear it', pg_temp.pushes('league.qualified'), 'b1,c1,d1,f1');
select pg_temp.throws('a closed season takes no more events', format('select public.league_event_set(%L, %L)', :E3, :'SE'), '22023');
select pg_temp.eq('an organizer is added', public.league_member_set(:'L', :H, 'organizer')->>'role', 'organizer');
select pg_temp.throws('a league keeps an owner', format('select public.league_member_set(%L, %L, null)', :'L', :A), '22023');
select pg_temp.throws('blocked people can''t be added', format('select public.league_member_set(%L, %L, %L)', :'L', :K, 'organizer'), '42501');
select pg_temp.eq('archive', public.league_update(:'L', '{"archived": true}')->>'archived', 'true');
set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('an archived league reads as gone', $$select public.league_view('the-mountain-magic-series')$$, 'P0002');
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.eq('its organizers still open it', public.league_update(:'L', '{"archived": false}')->>'archived', 'false');

-- ==================================================================== format boards
reset role;
-- Seeded straight into finished events: the guards that keep finished events closed are off for these rows.
set session_replication_role = replica;
insert into public.rounds (id, event_id, number, status)
select md5('r' || e.n)::uuid, e.id, 1, 'recorded' from (values (:E1::uuid, 1), (:E2::uuid, 2), (:EP::uuid, 5), (:ES::uuid, 8)) e(id, n);
-- Legacy: Bea beats Cal, Bea beats Dee, Cal beats Dee, Eve and Fay draw, Gil beats a guest (not rated).
create or replace function pg_temp.played(p_event uuid, p_round int, p_n int, p_a uuid, p_b uuid, p_result text) returns void language plpgsql as $$
declare v_m uuid := md5('m' || p_round || '-' || p_n)::uuid;
begin
  insert into public.matches (id, event_id, round_id, table_number) values (v_m, p_event, md5('r' || p_round)::uuid, p_n);
  insert into public.match_outcomes (match_id, user_id, opponent_id, event_id, mw, ml, md, played_at)
  values (v_m, p_a, p_b, p_event, (p_result = 'w')::int, (p_result = 'l')::int, (p_result = 'd')::int, now() - interval '1 day' + p_n * interval '1 minute');
  if p_b is not null then
    insert into public.match_outcomes (match_id, user_id, opponent_id, event_id, mw, ml, md, played_at)
    values (v_m, p_b, p_a, p_event, (p_result = 'l')::int, (p_result = 'w')::int, (p_result = 'd')::int, now() - interval '1 day' + p_n * interval '1 minute');
  end if;
end $$;
select pg_temp.played(:E2, 2, 1, :B, :C, 'w'), pg_temp.played(:E2, 2, 2, :B, :D, 'w'), pg_temp.played(:E2, 2, 3, :C, :D, 'w'),
       pg_temp.played(:E2, 2, 4, :E, :F, 'd'), pg_temp.played(:E2, 2, 5, :G, null, 'w');
-- Modern: Bea and Cal play twelve times (Bea wins eight). The private night and the two-player pod don't count.
select pg_temp.played(:E1, 1, n, :B, :C, case when n % 3 = 0 then 'l' else 'w' end) from generate_series(1, 12) n;
select pg_temp.played(:EP, 5, 1, :D, :E, 'w'), pg_temp.played(:ES, 8, 1, :B, :C, 'l');
insert into public.matches (id, event_id, round_id, table_number) values (md5('m2-9')::uuid, :E2, md5('r2')::uuid, 9);
insert into public.match_sides (id, match_id, event_id, participant_id, side, game_wins)
values ('b0000000-0000-0000-0000-000000007301', md5('m2-9')::uuid, :E2, 'a0000000-0000-0000-0000-000000007321', 0, 2);
set session_replication_role = origin;
select pg_temp.eq('rebuild every board', t1_private.ratings_rebuild_all()::text, '16');
select pg_temp.eq('Legacy by Elo: 1500 start, K 40',
  (select string_agg(right(user_id::text, 2) || ' ' || round(rating) || ' ' || matches, ', ' order by rating desc, user_id) from t1_private.format_ratings where board = 'legacy'),
  'b1 1539 2, c1 1500 2, e1 1500 1, f1 1500 1, d1 1461 2');
select pg_temp.eq('the private night and the small pod rate nobody',
  (select count(*)::text from t1_private.format_ratings where board = 'modern'), '2');
select pg_temp.eq('a rebuild is repeatable', (select t1_private.ratings_rebuild('legacy')::text || ' ' || round(rating) from t1_private.format_ratings where board = 'legacy' and user_id = :B), '4 1539');

set role anon;
select pg_temp.as_user(null);
select pg_temp.eq('Modern lists the two with 10+ matches, by name only',
  (select (v->>'count') || ' ' || string_agg((r->>'rank') || ' ' || (r->>'name') || ' ' || (r->>'wins') || '-' || (r->>'losses') || coalesce(r->>'user_id', ''), ', ' order by (r->>'rank')::int)
     from public.format_leaderboard('modern') v, jsonb_array_elements(v->'rows') r group by v->>'count'), '2 1 Bea 8-4, 2 Cal 4-8');
select pg_temp.eq('Legacy lists nobody yet', public.format_leaderboard('legacy')->>'count', '0');
select pg_temp.throws('no such board', $$select public.format_leaderboard('other')$$, '22023');
select pg_temp.eq('ten boards', jsonb_array_length(public.format_boards()->'boards')::text, '10');
select pg_temp.throws('anon can''t change listing', 'select public.leaderboards_listed_set(false)', '42501');
set role authenticated;
select pg_temp.as_user(:D);
select pg_temp.eq('your own rating shows before you''re listed',
  (select (b->'me'->>'rating') || ' ' || (b->'me'->>'to_go') || ' ' || coalesce(b->'me'->>'rank', 'unranked') from jsonb_array_elements(public.format_boards()->'boards') b where b->>'board' = 'legacy'),
  '1461 8 unranked');
select pg_temp.as_user(:C);
select pg_temp.eq('Cal sees his rank', public.format_leaderboard('modern')->'me'->>'rank', '2');
select pg_temp.as_user(:B);
select pg_temp.eq('hide yourself', public.leaderboards_listed_set(false)::text, '{"listed": false}');
select pg_temp.eq('hidden: off the board, the others move up, your matches still count',
  (select (v->>'count') || ' ' || (v->'rows'->0->>'name') || ' ' || (v->'rows'->0->>'rank') || ' ' || (v->'me'->>'rating' is not null)::text || ' ' || coalesce(v->'me'->>'rank', 'unranked')
     from public.format_leaderboard('modern') v), '1 Cal 1 true unranked');
select pg_temp.eq('boards say you''re hidden', public.format_boards()->>'listed', 'false');
select pg_temp.eq('show yourself again', public.leaderboards_listed_set(true)::text, '{"listed": true}');
reset role;
select pg_temp.eq('audited both ways', (select count(*)::text from public.account_audit where actor = :B and action = 'leaderboards.listed'), '2');
insert into public.user_blocks (user_id, blocked_id) values (:B, :S);
set role authenticated;
select pg_temp.as_user(:S);
select pg_temp.eq('someone in a block with you isn''t shown to you', (select string_agg(r->>'name', ',') from jsonb_array_elements(public.format_leaderboard('modern')->'rows') r), 'Cal');

-- A result corrected after the finish asks for the places again, and they rebuild the board.
reset role;
update public.match_sides set game_wins = 1 where id = 'b0000000-0000-0000-0000-000000007301';
select pg_temp.eq('a corrected result asks the engine again', pg_temp.asks(:E2), '2');
select pg_temp.eq('nothing asks while places were never wanted', pg_temp.asks(:EP), '0');
update public.match_outcomes set mw = 1 - mw, ml = 1 - ml where match_id = md5('m2-1')::uuid;
select pg_temp.eq('the corrected places come in', pg_temp.place(:E2, '2', array[2, 1, 7, 3, 4, 5, 6, 8])->>'placed', '8');
select pg_temp.eq('new places rebuild the event''s board',
  (select round(rating)::text from t1_private.format_ratings where board = 'legacy' and user_id = :C), '1538');
update t1_private.placement_jobs set done_at = null, asked_at = now() - interval '5 minutes' where event_id = :E1;
select pg_temp.eq('the sweep asks again for places that never came', t1_private.placements_sweep()::text || pg_temp.asks(:E1), '12');

-- ==================================================================== moderation queue
select pg_temp.eq('descriptions and league names are queued for review',
  (select string_agg(k || ' ' || n, ', ' order by k) from (select subject_kind k, count(*) n from public.moderation_checks
     where subject_kind in ('event_description', 'league_name', 'league_description') group by 1) x),
  'event_description 1, league_description 1, league_name 3');
