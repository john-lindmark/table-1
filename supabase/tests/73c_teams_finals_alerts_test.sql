-- Phase 2 of leagues (20261113140000_teams_finals_alerts.sql; contract/teams-finals-alerts-2026-11-13.md): Team Trios
-- and the top 4 cut, teams that sign themselves up with a captain, a season's final, alerts for new public events.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data)
select ('00000000-0000-0000-0000-0000000074' || lower(c) || '1')::uuid, lower(n) || '@example.com', jsonb_build_object('full_name', n)
  from (values ('A', 'Ana Org'), ('B', 'Bea'), ('C', 'Cal'), ('D', 'Dee'), ('E', 'Eve'), ('F', 'Fay'), ('0', 'Sam Stranger')) x(c, n);
\set A '''00000000-0000-0000-0000-0000000074a1'''
\set B '''00000000-0000-0000-0000-0000000074b1'''
\set C '''00000000-0000-0000-0000-0000000074c1'''
\set D '''00000000-0000-0000-0000-0000000074d1'''
\set E '''00000000-0000-0000-0000-0000000074e1'''
\set F '''00000000-0000-0000-0000-0000000074f1'''
\set S '''00000000-0000-0000-0000-000000007401'''

create or replace function pg_temp.pushes(p_kind text) returns text language sql security definer as $$
  select coalesce(string_agg(x, ',' order by x), '-') from (
    select (select string_agg(right(u, 2), '+' order by u) from jsonb_array_elements_text(m.msg->'user_ids') u) x
      from pgmq.messages m where m.msg->>'kind' = p_kind) s $$;
create or replace function pg_temp.ev(p_id uuid) returns public.events language sql security definer as $$ select * from public.events where id = p_id $$;
grant execute on function pg_temp.pushes(text), pg_temp.ev(uuid) to anon, authenticated;

-- ==================================================================== Team Trios and the cut
set role authenticated;
select pg_temp.as_user(:A);
select (public.create_event_v2(p_name => 'Winter Trios', p_format_name => 'team_trios', p_include_me => false,
                               p_starts_at => now() + interval '3 days', p_capacity => 6, p_top_cut => 4)->>'event_id') as "ET" \gset
select pg_temp.eq('Team Trios: three a team, a format a seat, top 4 allowed',
  (select e.format_label || ' / ' || e.team_size || ' / ' || array_to_string(e.seat_formats, ',') || ' / ' || e.top_cut || ' / ' || e.event_type from pg_temp.ev(:'ET') e),
  'Team Trios / 3 / modern,standard,pioneer / 4 / constructed');
select pg_temp.throws('team events don''t cut to 8', $$select public.create_event_v2(p_format_name => 'team_trios', p_top_cut => 8)$$, '22023');
select pg_temp.throws('a team draft has no cut', $$select public.create_event_v2(p_format_name => 'team_draft', p_team_size => 3, p_top_cut => 4)$$, '22023');
select pg_temp.eq('players'' events can cut to 4',
  (select e.top_cut::text from pg_temp.ev((public.create_event_v2(p_format_name => 'modern', p_top_cut => 4, p_include_me => false)->>'event_id')::uuid) e), '4');
select pg_temp.throws('no top 6', $$select public.create_event_v2(p_format_name => 'modern', p_top_cut => 6)$$, '22023');
select pg_temp.eq('pick the seats'' formats', public.set_event_trios(:'ET', array['pauper', 'premodern', 'legacy'])->>'seat_formats', '["pauper", "premodern", "legacy"]');
select pg_temp.throws('three seats, known formats', format('select public.set_event_trios(%L, array[''pauper'', ''draft'', ''legacy''])', :'ET'), '22023');
select pg_temp.eq('details keep the trios and their cut',
  (public.update_event_details(:'ET', 'Winter Trios', 'team_trios', 4) is not null)::text, 'true');
select pg_temp.eq('after an edit: still three seats, the picked formats and top 4',
  (select e.team_size || ' / ' || array_to_string(e.seat_formats, ',') || ' / ' || e.top_cut || ' / ' || e.number_of_rounds from pg_temp.ev(:'ET') e), '3 / pauper,premodern,legacy / 4 / 4');
select pg_temp.as_user(:S);
select pg_temp.throws('a stranger can''t pick seat formats', format('select public.set_event_trios(%L, array[''pauper'', ''modern'', ''legacy''])', :'ET'), '42501');
select pg_temp.throws('or switch team sign-up', format('select public.team_signup_set(%L, true)', :'ET'), '42501');

-- ==================================================================== teams sign themselves up
select pg_temp.as_user(:B);
select pg_temp.throws('until the organizer allows it, teams can''t sign up', format('select public.team_create(%L, %L)', :'ET', 'Team One'), '22023');
select pg_temp.as_user(:A);
select pg_temp.eq('teams sign themselves up', public.team_signup_set(:'ET', true)::text, '{"team_signup": true}');
select pg_temp.as_user(:B);
select pg_temp.eq('sign up a team: you are its captain in seat A, with a code to share',
  (select (v->'team'->>'name') || ' / ' || (v->>'captain') || ' / ' || (v->'team'->'members'->0->>'slot') || ' / ' || char_length(v->'team'->>'join_code') || ' / ' || (v->'team'->>'complete')
     from public.team_create(:'ET', '  Team   One ') v), 'Team One / true / 1 / 8 / false');
select public.team_mine(:'ET')->'team'->>'join_code' as "CODE" \gset
select public.team_mine(:'ET')->'team'->>'id' as "T1" \gset
select pg_temp.throws('one team each', format('select public.team_create(%L, %L)', :'ET', 'Second'), '22023');
select pg_temp.as_user(:S);
select pg_temp.eq('others see the teams and their size, never the code',
  (select (v->'teams'->0->>'name') || ' ' || (v->'teams'->0->>'members') || ' ' || coalesce(v->'teams'->0->>'join_code', 'no code') || ' ' || (v->>'can_create') from public.team_mine(:'ET') v),
  'Team One 1 no code true');
select pg_temp.throws('a wrong code', format('select public.team_join(%L, %L)', :'ET', 'NOPE1234'), 'P0002');
select pg_temp.as_user(:C);
select pg_temp.eq('join with the code: the next free seat', (select m->>'slot' from jsonb_array_elements(public.team_join(:'ET', lower(:'CODE'))->'team'->'members') m where m->>'name' = 'Cal'), '2');
select pg_temp.as_user(:D);
select pg_temp.eq('the third member completes it', public.team_join(:'ET', :'CODE')->'team'->>'complete', 'true');
select pg_temp.as_user(:E);
select pg_temp.throws('a full team takes no more', format('select public.team_join(%L, %L)', :'ET', :'CODE'), '22023');
select pg_temp.eq('a second team fits the cap of six', public.team_create(:'ET', 'Team Two')->'team'->>'name', 'Team Two');
select pg_temp.throws('a name is taken once', format('select public.team_update(%L, %L)', (public.team_mine(:'ET')->'team'->>'id'), '{"name": "team one"}'), '23505');
select pg_temp.as_user(:F);
select pg_temp.throws('a third team doesn''t: every team counts whole', format('select public.team_create(%L, %L)', :'ET', 'Team Three'), '55000');
select pg_temp.eq('so nobody new can start one', public.team_mine(:'ET')->>'can_create', 'false');

-- The captain runs the team.
select pg_temp.as_user(:C);
select pg_temp.throws('only the captain changes the team', format('select public.team_update(%L, %L)', :'T1', '{"name": "Mine"}'), '42501');
select pg_temp.as_user(:B);
select pg_temp.eq('reorder the seats',
  (select string_agg((m->>'name') || (m->>'slot'), ' ') from jsonb_array_elements(public.team_update(:'T1',
     jsonb_build_object('order', (select jsonb_agg(m->>'participant_id' order by m->>'name' desc) from jsonb_array_elements(public.team_mine(:'ET')->'team'->'members') m)))->'team'->'members') m),
  'Dee1 Cal2 Bea3');
select pg_temp.throws('the order names every member', format('select public.team_update(%L, %L)', :'T1', '{"order": []}'), '22023');
select pg_temp.eq('hand the captaincy on', public.team_update(:'T1', jsonb_build_object('captain', :C))->>'captain', 'false');
select pg_temp.as_user(:C);
select pg_temp.eq('the new captain removes a member, who leaves the event',
  (select jsonb_array_length(v->'team'->'members')::text || (v->'team'->>'complete') from public.team_update(:'T1',
     jsonb_build_object('remove', (select m->>'participant_id' from jsonb_array_elements(public.team_mine(:'ET')->'team'->'members') m where m->>'name' = 'Dee'))) v), '2false');
select pg_temp.eq('a captain who leaves passes it on', public.event_leave(:'ET')->>'status', 'left');
select pg_temp.as_user(:B);
select pg_temp.eq('to the first member left', (select (v->>'captain') || jsonb_array_length(v->'team'->'members') from public.team_mine(:'ET') v), 'true1');
select pg_temp.eq('the last one out closes the team', public.event_leave(:'ET')->>'status', 'left');
select pg_temp.eq('and frees its place', (select jsonb_array_length(v->'teams')::text || (v->>'can_create') from public.team_mine(:'ET') v), '1true');
select pg_temp.as_user(:A);
select pg_temp.eq('organizers see every team with its code', ((public.team_mine(:'ET')->'teams'->0->>'join_code') is not null)::text, 'true');
reset role;
select pg_temp.eq('every step is audited', (select string_agg(action, ',' order by action) from (select distinct action from public.audit_log where event_id = :'ET' and action like 'team.%') x),
  'team.created,team.joined,team.removed,team.updated');

-- ==================================================================== a season's final
insert into public.events (id, short_code, name, created_by, status, current_round, number_of_rounds, visibility, starts_at, format_name, format) values
  ('e0000000-0000-0000-0000-000000007401', 'FINOPN', 'Open', :A, 'completed', 5, 5, 'public', now() - interval '20 days', 'modern', 'constructed'),
  ('e0000000-0000-0000-0000-000000007402', 'FINFIN', 'The Final', :A, 'setup', 0, 5, 'private', now() + interval '20 days', 'modern', 'constructed'),
  ('e0000000-0000-0000-0000-000000007403', 'FINNOT', 'Not a final', :A, 'setup', 0, 5, 'link_only', now() + interval '20 days', 'modern', 'constructed');
\set EO '''e0000000-0000-0000-0000-000000007401'''
\set EFN '''e0000000-0000-0000-0000-000000007402'''
\set EN '''e0000000-0000-0000-0000-000000007403'''
insert into public.event_members (event_id, user_id, role) values (:EO, :A, 'owner'), (:EFN, :A, 'owner'), (:EN, :A, 'owner');
insert into public.leagues (id, slug, name, created_by) values ('10000000-0000-0000-0000-000000007401', 'final-series', 'Final Series', :A);
insert into public.league_members (league_id, user_id, role) values ('10000000-0000-0000-0000-000000007401', :A, 'owner');
insert into public.league_seasons (id, league_id, name, starts_on, ends_on, points, qualify)
values ('20000000-0000-0000-0000-000000007401', '10000000-0000-0000-0000-000000007401', '2026', current_date - 300, current_date + 60,
        '{"places": [{"through": 1, "points": 12}, {"through": 2, "points": 10}, {"through": 4, "points": 8}], "participation": 1, "match_win": 0}',
        '{"winners": true, "pass_down": true, "top": 1}');
insert into public.league_events (event_id, season_id, league_id, final) values
  (:EO, '20000000-0000-0000-0000-000000007401', '10000000-0000-0000-0000-000000007401', false),
  (:EFN, '20000000-0000-0000-0000-000000007401', '10000000-0000-0000-0000-000000007401', true);
insert into public.participants (id, event_id, user_id, display_name, seat)
select md5('fp' || n)::uuid, :EO, u, name, n from (values (1, :B::uuid, 'Bea'), (2, :C::uuid, 'Cal'), (3, :D::uuid, 'Dee'), (4, null, 'Gus Guest'), (5, :E::uuid, 'Eve')) x(n, u, name);
insert into public.event_placements (event_id, participant_id, user_id, name, place)
select :EO, md5('fp' || n)::uuid, u, name, n from (values (1, :B::uuid, 'Bea'), (2, :C::uuid, 'Cal'), (3, :D::uuid, 'Dee'), (4, null, 'Gus Guest'), (5, :E::uuid, 'Eve')) x(n, u, name);

set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.eq('the final: who qualified and who is next',
  (select (select string_agg((q->>'name') || ' ' || (q->>'how') || ' ' || (q->>'state'), ', ') from jsonb_array_elements(v->'qualified') q) || ' | ' ||
          (select string_agg((q->>'name') || ' ' || (q->>'state'), ', ') from jsonb_array_elements(v->'next') q)
     from public.league_final_status(:EFN) v), 'Bea winner none, Cal points none | Dee none, Gus Guest guest, Eve none');
select pg_temp.throws('only a final has this', format('select public.league_final_status(%L)', :EN), '42501');
select pg_temp.eq('invite the qualified', public.league_final_invite(:EFN)->>'invited', '2');
select pg_temp.eq('they read invited', (select string_agg(q->>'state', ',') from jsonb_array_elements(public.league_final_status(:EFN)->'qualified') q), 'invited,invited');
select pg_temp.eq('inviting again invites nobody', public.league_final_invite(:EFN)->>'invited', '0');
select pg_temp.eq('pass one down to the next in line', public.league_final_invite(:EFN, array[:D::text])->>'invited', '1');
select pg_temp.as_user(:B);
select pg_temp.eq('an invited player signs up to the invitation-only final', public.event_sign_up(:EFN)->>'status', 'joined');
select pg_temp.as_user(:E);
select pg_temp.throws('nobody else can', format('select public.event_sign_up(%L)', :EFN), '42501');
select pg_temp.as_user(:S);
select pg_temp.throws('a stranger sees nothing of the final', format('select public.league_final_status(%L)', :EFN), '42501');
select pg_temp.throws('and invites nobody', format('select public.league_final_invite(%L)', :EFN), '42501');
select pg_temp.as_user(:A);
select pg_temp.eq('status follows: in, invited, and Dee invited',
  (select (select string_agg(q->>'state', ',') from jsonb_array_elements(v->'qualified') q) || ' | ' || (v->'next'->0->>'state') from public.league_final_status(:EFN) v), 'in,invited | invited');
select pg_temp.eq('invitations went as event invites', pg_temp.pushes('event.invite'), 'b1+c1,d1');

-- ==================================================================== alerts for new public events
select pg_temp.as_user(:B);
select pg_temp.eq('no alert settings yet', public.event_alerts_get()::text, '{"km": null, "on": false, "lat": null, "lng": null, "formats": []}');
select pg_temp.eq('Modern within 50 km of a rough home area',
  public.event_alerts_set('{"on": true, "formats": ["modern"], "km": 50, "lat": 39.7392, "lng": -104.9903}')::text,
  '{"km": 50, "on": true, "lat": 39.7, "lng": -105.0, "formats": ["modern"]}');
select pg_temp.throws('a distance needs an area', $$select public.event_alerts_set('{"place": null}')$$, '22023');
select pg_temp.throws('unknown formats are refused', $$select public.event_alerts_set('{"formats": ["chess"]}')$$, '22023');
select pg_temp.as_user(:C);
select pg_temp.eq('every format, anywhere', public.event_alerts_set('{"on": true}')->>'on', 'true');
select pg_temp.as_user(:D);
select pg_temp.eq('off', public.event_alerts_set('{"on": false, "formats": ["modern"]}')->>'on', 'false');
select pg_temp.as_user(:E);
select pg_temp.eq('Eve wants everything too', public.event_alerts_set('{"on": true}')->>'on', 'true');

select pg_temp.as_user(:A);
select (public.create_event_v2(p_name => 'Modern Open', p_format_name => 'modern', p_include_me => false, p_starts_at => now() + interval '9 days')->>'event_id') as "EA" \gset
select (public.create_event_v2(p_name => 'Springs Pauper', p_format_name => 'pauper', p_include_me => false, p_starts_at => now() + interval '9 days')->>'event_id') as "EB" \gset
select pg_temp.eq('listed near Denver', public.event_listing_set(:'EA', '{"find": "public", "lat": 39.5954, "lng": -104.8771}')->>'visibility', 'public');
select pg_temp.as_user(:E);
select pg_temp.eq('Eve signs up before the alert goes', public.event_sign_up(:'EA')->>'status', 'joined');
reset role;
select pg_temp.eq('the alert waits ten minutes', t1_private.event_alerts_send()::text || pg_temp.pushes('event.public_new'), '0-');
update t1_private.event_alert_queue set due_at = now() - interval '1 second';
select pg_temp.eq('then goes to those it fits: not the organizer, not who''s in, not the switched off', t1_private.event_alerts_send()::text, '2');
select pg_temp.eq('Bea (Modern, 19 km) and Cal (everything)', pg_temp.pushes('event.public_new'), 'b1+c1');
select pg_temp.eq('once per event', t1_private.event_alerts_send()::text, '0');
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.eq('a Pauper event 100 km south', public.event_listing_set(:'EB', '{"find": "public", "lat": 38.8339, "lng": -104.8214}')->>'visibility', 'public');
reset role;
update t1_private.event_alert_queue set due_at = now() - interval '1 second' where sent_at is null;
select pg_temp.eq('fits Cal and Eve, not Bea (format and distance)', t1_private.event_alerts_send()::text || ' ' || pg_temp.pushes('event.public_new'), '2 b1+c1,c1+e1');
insert into t1_private.event_alert_log (user_id, event_id) select :C, gen_random_uuid() from generate_series(1, 4);
update public.events set visibility = 'link_only' where id = :'EA';
update public.events set visibility = 'public' where id = :'EA';
select pg_temp.eq('an event listed twice alerts once', (select count(*)::text from t1_private.event_alert_queue where event_id = :'EA'), '1');
set role authenticated;
select pg_temp.as_user(:A);
select (public.create_event_v2(p_name => 'Legacy Open', p_format_name => 'legacy', p_include_me => false, p_starts_at => now() + interval '9 days')->>'event_id') as "EC" \gset
select pg_temp.eq('a third event', public.event_listing_set(:'EC', '{"find": "public"}')->>'visibility', 'public');
reset role;
update t1_private.event_alert_queue set due_at = now() - interval '1 second' where sent_at is null;
select pg_temp.eq('five alerts a week is the cap: Cal sits this one out; no place, so only the anywhere alerts fit', t1_private.event_alerts_send()::text || ' ' || pg_temp.pushes('event.public_new'), '1 b1+c1,c1+e1,e1');

set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('anon has no alerts', 'select public.event_alerts_get()', '42501');
select pg_temp.throws('anon reads no alert table', 'select count(*) from public.event_alerts', '42501');
select pg_temp.throws('anon can''t sign up a team', format('select public.team_create(%L, %L)', :'ET', 'Anon'), '42501');
select pg_temp.eq('anon can read the teams of an event they can open', jsonb_array_length(public.team_mine(:'ET')->'teams')::text, '1');
