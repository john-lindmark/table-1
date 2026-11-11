-- Scheduled events, the sign-up link, caps and the waitlist, top 8, automatic rounds, names
-- (20261027120000_scheduled_events, contract/scheduled-events-2026-10-27.md).
\ir _helpers.sql

-- Event ids for steps that act as non-members (who can no longer read the events table).
create function pg_temp.shop() returns uuid language sql security definer as $$
  select id from public.events where venue_name = 'The Shop' $$;
create function pg_temp.private_event() returns uuid language sql security definer as $$
  select id from public.events where visibility = 'private' limit 1 $$;
grant execute on function pg_temp.shop(), pg_temp.private_event() to anon, authenticated;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'bea@example.com'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com'),
  ('00000000-0000-0000-0000-0000000000d1', 'dee@example.com'),
  ('00000000-0000-0000-0000-0000000000e1', 'eli@example.com');
\set A '''00000000-0000-0000-0000-0000000000a1'''
\set B '''00000000-0000-0000-0000-0000000000b1'''
\set C '''00000000-0000-0000-0000-0000000000c1'''
\set D '''00000000-0000-0000-0000-0000000000d1'''
\set E '''00000000-0000-0000-0000-0000000000e1'''

set role authenticated;

-- Names -------------------------------------------------------------------------------------------------
select pg_temp.as_user(:A);
select (public.create_event_v2(p_name => '  Friday   Night Modern ', p_format_name => 'modern', p_rounds => 3,
          p_local_date => '2026-11-07')->>'event_id') as named \gset
select pg_temp.eq('a typed name is kept (spaces tidied)', (select name || '|' || auto_name from public.events where id = :'named'),
  'Friday Night Modern|false');
select public.update_event_details(p_event_id => :'named', p_name => 'Friday Night Modern', p_format_name => 'pioneer', p_rounds => 3);
select pg_temp.eq('a named event keeps its name when the format changes', (select name from public.events where id = :'named'),
  'Friday Night Modern');
select public.update_event_details(p_event_id => :'named', p_name => '', p_format_name => 'pioneer', p_rounds => 3,
  p_auto_name => true);
select pg_temp.eq('emptying the name goes back to the automatic name', (select name || '|' || auto_name from public.events where id = :'named'),
  'Pioneer · Sat 7 Nov|true');
select public.update_event_details(p_event_id => :'named', p_name => 'Stale echo', p_format_name => 'modern', p_rounds => 3);
select pg_temp.eq('older builds (no p_auto_name) never rename an auto-named event', (select name from public.events where id = :'named'),
  'Modern · Sat 7 Nov');
select public.update_event_details(p_event_id => :'named', p_name => 'Store Championship', p_format_name => 'modern',
  p_rounds => 3, p_auto_name => false);
select pg_temp.eq('an auto-named event can be named', (select name || '|' || auto_name from public.events where id = :'named'),
  'Store Championship|false');
select pg_temp.throws('a named event needs a name', $$select public.update_event_details(p_event_id => (select id from public.events where name = 'Store Championship'), p_name => ' ', p_format_name => 'modern', p_rounds => 3, p_auto_name => false)$$, '22023');

-- Schedule, cap, auto rounds, top 8 ---------------------------------------------------------------------------
select (public.create_event_v2(p_format_name => 'modern', p_rounds => 3, p_local_date => '2026-11-08',
          p_starts_at => now() + interval '12 days', p_venue_name => ' The Shop ', p_capacity => 2,
          p_top_cut => 8, p_auto_rounds => true)->>'event_id') as ev \gset
select pg_temp.eq('scheduled, capped, top 8, auto rounds',
  (select (starts_at > now() + interval '11 days')::text || '|' || venue_name || '|' || capacity || '|' || top_cut || '|' || auto_rounds || '|' || name
     from public.events where id = :'ev'),
  'true|The Shop|2|8|true|Modern · Sun 8 Nov');
select pg_temp.eq('auto rounds: 1 for the organizer alone', (select number_of_rounds::text from public.events where id = :'ev'), '1');
select pg_temp.throws('top 8 is for Swiss events', $$select public.create_event_v2(p_format_name => 'team_draft', p_team_size => 3, p_top_cut => 8)$$, '22023');
select pg_temp.throws('auto rounds are for Swiss events', $$select public.create_event_v2(p_format_name => 'roto', p_cube_name => 'Cube', p_auto_rounds => true)$$, '22023');
select pg_temp.throws('only none or top 8', $$select public.create_event_v2(p_format_name => 'modern', p_top_cut => 4)$$, '22023');
select pg_temp.throws('caps are 2 to 10000', $$select public.create_event_v2(p_format_name => 'modern', p_capacity => 1)$$, '22023');
select pg_temp.throws('a time within a year', $$select public.create_event_v2(p_format_name => 'modern', p_starts_at => now() + interval '2 years')$$, '22023');

-- Sign up and the waitlist ----------------------------------------------------------------------------------
select pg_temp.as_user(:B);
select pg_temp.eq('the page before signing up', (select (x->>'sign_up') || '|' || (x->>'players') || '|' || coalesce(x->>'me', '-') || '|' || (x->>'top_cut') || '|' || (x->>'auto_rounds')
  from public.event_public(:'ev') x), 'open|1|-|8|true');
select pg_temp.eq('Bea signs up', public.event_sign_up(:'ev')->>'status', 'joined');
select pg_temp.eq('signing up twice is safe', public.event_sign_up(:'ev')->>'status', 'already_joined');
select pg_temp.eq('auto rounds follow the players (2 → 1)', (select number_of_rounds::text from public.events where id = :'ev'), '1');
select pg_temp.as_user(:C);
select pg_temp.eq('Cal finds it full', (select x->>'sign_up' from public.event_preview(p_event_id => :'ev') x), 'full');
select pg_temp.eq('Cal goes on the waitlist', (select (x->>'status') || '|' || (x->>'position') from public.event_sign_up(:'ev') x), 'waitlisted|1');
select pg_temp.eq('again: still waiting, same place', (select (x->>'status') || '|' || (x->>'position') from public.event_sign_up(:'ev') x), 'already_waitlisted|1');
select pg_temp.eq('Cal sees their place', (select (x->>'me') || '|' || (x->>'position') || '|' || (x->>'waitlist') from public.event_public(:'ev') x), 'waitlisted|1|1');
select pg_temp.eq('Cal''s home lists the waitlist', (select (h->'waitlist'->0->>'position') || '|' || jsonb_array_length(h->'events') from public.events_home() h), '1|0');
select pg_temp.as_user(:D);
select pg_temp.eq('Dee is second', public.event_sign_up(:'ev')->>'position', '2');
select pg_temp.throws('the waitlist table is not readable', $$select * from public.event_waitlist$$, '42501');

select pg_temp.as_user(:A);
select pg_temp.eq('the organizer sees the waitlist in order', (select string_agg(w->>'display_name' || '#' || (w->>'position'), ',')
  from jsonb_array_elements(public.event_bundle(:'ev')->'waitlist') w), 'cal#1,dee#2');
select pg_temp.as_user(:B);
select pg_temp.eq('a player sees no waitlist', jsonb_array_length(public.event_bundle(:'ev')->'waitlist')::text, '0');
select pg_temp.throws('only organizers let people in', $$select public.waitlist_admit(pg_temp.shop(), '00000000-0000-0000-0000-0000000000d1')$$, '42501');

-- Bea leaves: Cal moves up and is told; Dee is first now.
select pg_temp.eq('Bea leaves', public.event_leave(:'ev')->>'status', 'left');
reset role;
select pg_temp.eq('Cal moved up', (select count(*) from public.participants where event_id = :'ev' and user_id = :C)::text, '1');
select pg_temp.eq('Cal got a push', (select count(*) from pgmq.messages where msg->>'kind' = 'event.waitlist_in'
  and msg->'user_ids' ? '00000000-0000-0000-0000-0000000000c1')::text, '1');
set role authenticated;
select pg_temp.as_user(:D);
select pg_temp.eq('Dee is first now', (select x->>'position' from public.event_public(:'ev') x), '1');

-- The cap goes up: Dee moves up. The cap comes down: nobody is removed.
select pg_temp.as_user(:A);
select pg_temp.eq('raising the cap seats the waitlist', (select (x->>'players') || '|' || (x->>'waitlist') from public.set_event_schedule(:'ev', now() + interval '12 days', 'The Shop', 3) x), '3|0');
select pg_temp.eq('auto rounds follow (3 → 2)', (select number_of_rounds::text from public.events where id = :'ev'), '2');
select pg_temp.eq('lowering the cap keeps everyone', (select x->>'players' from public.set_event_schedule(:'ev', now() + interval '12 days', 'The Shop', 2) x), '3');

-- A code join on a full event: signed in → the waitlist; signed out → full.
reset role;
select short_code as ev_code from public.events where id = :'ev' \gset
set role authenticated;
select pg_temp.as_user(:E);
select pg_temp.eq('Eli joins by code and waits', (select (x->>'error') || '|' || (x->>'waitlisted') || '|' || (x->>'position')
  from public.join_event(:'ev_code', 'Eli') x), 'full|true|1');
reset role;
select short_code as shop_code, id as shop_id from public.events where venue_name = 'The Shop' \gset
select pg_temp.as_user(null);
set role anon;
select pg_temp.eq('a guest is told it''s full', (select x->>'message' from public.join_event(:'shop_code', 'Walk-in') x), 'This event is full');
select pg_temp.throws('signing up needs an account', format($$select public.event_sign_up(%L)$$, :'shop_id'), '42501');
set role authenticated;

select pg_temp.as_user(:A);
select public.waitlist_admit(:'ev', :E);
select pg_temp.eq('the organizer lets Eli in past the cap', (select count(*) from public.participants p
  where p.event_id = :'ev' and p.status = 'active')::text, '4');
select pg_temp.eq('… and the waitlist is empty', jsonb_array_length(public.event_bundle(:'ev')->'waitlist')::text, '0');
select pg_temp.eq('auto rounds: 4 players → 2', (select number_of_rounds::text from public.events where id = :'ev'), '2');
select pg_temp.as_user(:B);
select pg_temp.eq('Bea waits again (full)', public.event_sign_up(:'ev')->>'status', 'waitlisted');
select pg_temp.as_user(:A);
select pg_temp.eq('the organizer takes Bea off', public.waitlist_remove(:'ev', :B)->>'removed', 'true');
select pg_temp.eq('audited', (select string_agg(distinct action, ',' order by action) from public.audit_log where event_id = :'ev'
  and action like 'waitlist.%' or (event_id = :'ev' and action in ('participant.left', 'event.schedule_updated'))),
  'event.schedule_updated,participant.left,waitlist.joined,waitlist.removed');

-- Private events: nothing for strangers.
select (public.create_event_v2(p_format_name => 'modern')->>'event_id') as priv \gset
reset role;
update public.events set visibility = 'private' where id = :'priv';
set role authenticated;
select pg_temp.as_user(:C);
select pg_temp.throws('a private event can''t be signed up for', $$select public.event_sign_up(pg_temp.private_event())$$, '42501');

-- Round 1 closes sign-ups and leaving; auto rounds stop following.
reset role;
insert into public.rounds (event_id, number, status) values (:'ev', 1, 'active');
update public.events set status = 'in_progress', current_round = 1 where id = :'ev';
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.throws('sign-ups close at round 1', $$select public.event_sign_up(pg_temp.shop())$$, '55000');
select pg_temp.eq('the page says closed', (select x->>'sign_up' from public.event_public(:'ev') x), 'closed');
select pg_temp.as_user(:C);
select pg_temp.throws('players can''t leave once it''s started', $$select public.event_leave(pg_temp.shop())$$, '55000');
select pg_temp.throws('details lock', $$select public.set_event_schedule(pg_temp.shop(), null, null, null)$$, '42501');
select pg_temp.as_user(:A);
select pg_temp.throws('details lock for the organizer too', $$select public.set_event_schedule(pg_temp.shop(), null, null, null)$$, '55000');
reset role;
insert into public.participants (event_id, display_name) values (:'ev', 'Late');
select pg_temp.eq('number_of_rounds stays once paired', (select number_of_rounds::text from public.events where id = :'ev'), '2');

-- Playoff matches need a winner -------------------------------------------------------------------------------
insert into public.rounds (id, event_id, number, status, stage) values
  ('f0000000-0000-0000-0000-0000000000a9', :'ev', 3, 'active', 'quarterfinal');
insert into public.matches (id, event_id, round_id, table_number, status) values
  ('f1000000-0000-0000-0000-0000000000a9', :'ev', 'f0000000-0000-0000-0000-0000000000a9', 1, 'pending');
insert into public.match_sides (match_id, participant_id, side, game_wins)
select 'f1000000-0000-0000-0000-0000000000a9', p.id, row_number() over (order by p.seat) - 1, 0
  from public.participants p where p.event_id = :'ev' and p.user_id in (:C, :D);
set role authenticated;
select pg_temp.as_user(:C);
select pg_temp.throws('a player can''t report a playoff draw', $$select public.report_match('f1000000-0000-0000-0000-0000000000a9', 1, 1, 1)$$, '22023');
select pg_temp.as_user(:A);
select pg_temp.throws('nor can the organizer set one', $$select public.set_match_result('f1000000-0000-0000-0000-0000000000a9', 1, 1, 0)$$, '22023');
select pg_temp.eq('a playoff result with a winner counts', public.set_match_result('f1000000-0000-0000-0000-0000000000a9', 2, 1, 0)->>'status', 'confirmed');
select pg_temp.eq('a Swiss draw is still fine', (select count(*) from public.rounds where event_id = :'ev' and stage = 'swiss')::text, '1');

-- Decklists -------------------------------------------------------------------------------------------------
\set cases `cat ../../testdata/scheduled-events/cases.json`
reset role;
select pg_temp.eq('decklist counts: ' || left(replace(c->>'body', E'\n', ' / '), 30),
  (select jsonb_build_object('main', x.main, 'side', x.side) from t1_private.decklist_counts(c->>'body') x)::text,
  (c->'want')::text)
  from jsonb_array_elements((:'cases')::jsonb->'decklist') c;
select pg_temp.eq('auto rounds match the shared cases', count(*)::text, '0')
  from jsonb_array_elements((:'cases')::jsonb->'rounds') c
 where t1_private.swiss_rounds((c->>'players')::int) <> (c->>'want')::int;
set role authenticated;

select pg_temp.as_user(:A);
select pg_temp.throws('decklists are for constructed events', $$select public.create_event_v2(p_format_name => 'draft', p_decklists => 'required')$$, '22023');
select (public.create_event_v2(p_format_name => 'modern', p_decklists => 'required', p_include_me => true)->>'event_id') as dl \gset
select (public.add_guest(:'dl', 'Walk-in')->>'participant_id') as dl_guest \gset
select (select id from public.participants where event_id = :'dl' and user_id = :A) as dl_ana \gset
select pg_temp.as_user(:B);
select (public.event_sign_up(:'dl')->>'participant_id') as dl_bea \gset
reset role;
insert into public.card_lists (id, user_id, kind, name, format, seq) values
  ('c1000000-0000-0000-0000-0000000000b1', :B, 'deck', 'Bea''s Burn', 'modern', 1),
  ('c1000000-0000-0000-0000-0000000000a1', :A, 'deck', 'Ana''s Tron', 'modern', 1);
set role authenticated;

select pg_temp.eq('Bea sends her deck', (select (x->>'main_count') || '|' || (x->>'side_count') || '|' || (x->>'list_name')
  from public.decklist_submit(:'dl_bea', E'4 Lightning Bolt\n56 Mountain\n\n15 Pyroblast', 'c1000000-0000-0000-0000-0000000000b1') x),
  '60|15|Bea''s Burn');
select pg_temp.eq('… and replaces it with text', (select (x->>'main_count') || '|' || coalesce(x->>'list_name', '-')
  from public.decklist_submit(:'dl_bea', E'Deck\n60 Mountain') x), '60|-');
select pg_temp.throws('a list needs cards', $$select public.decklist_submit((select id from public.participants where display_name = 'bea' and event_id = (select id from public.events where decklists = 'required')), 'Lightning Bolt')$$, '22023');
select pg_temp.throws('someone else''s deck can''t be used', $$select public.decklist_submit((select id from public.participants where display_name = 'bea' and event_id = (select id from public.events where decklists = 'required')), '60 Island', 'c1000000-0000-0000-0000-0000000000a1')$$, '42501');
select pg_temp.throws('Bea can''t touch the guest''s list', $$select public.decklist_submit((select id from public.participants where display_name = 'Walk-in'), '60 Island')$$, '42501');
select pg_temp.throws('nor read it', $$select public.decklist_get((select id from public.participants where display_name = 'Walk-in'))$$, '42501');
select pg_temp.eq('Bea reads her own', public.decklist_get(:'dl_bea')->>'body', E'Deck\n60 Mountain');
select pg_temp.eq('the bundle shows Bea only her own', (select string_agg(d->>'participant_id', ',') from jsonb_array_elements(public.event_bundle(:'dl')->'decklists') d), :'dl_bea');
select pg_temp.as_user(:C);
select pg_temp.throws('a stranger can''t read lists', $$select public.decklist_get((select p.id from public.participants p join public.events e on e.id = p.event_id where e.decklists = 'required' and p.display_name = 'bea'))$$, '42501');

select pg_temp.as_user(:A);
select pg_temp.eq('the organizer enters the guest''s list', public.decklist_submit(:'dl_guest', E'60 Island\n\n15 Hydroblast')->>'side_count', '15');
select pg_temp.eq('the organizer sees every list', jsonb_array_length(public.event_bundle(:'dl')->'decklists')::text, '2');
select pg_temp.eq('… and the text', public.decklist_get(:'dl_bea')->>'main_count', '60');
select pg_temp.eq('home says who still owes one', (select (r->>'decklists') || '|' || (r->>'my_decklist')
  from jsonb_array_elements(public.events_home()->'events') r where r->>'id' = :'dl'), 'required|false');
select pg_temp.eq('the page says decklists are required', public.event_public(:'dl')->>'decklists', 'required');
select pg_temp.throws('switching to a draft turns lists off or refuses', $$select public.update_event_details(p_event_id => (select id from public.events where decklists = 'required'), p_name => null, p_format_name => 'draft', p_rounds => 3, p_decklists => 'optional')$$, '22023');
select pg_temp.eq('organizer removes a list', public.decklist_remove(:'dl_guest')->>'removed', 'true');
select pg_temp.eq('audited', (select count(*) from public.audit_log where event_id = :'dl' and action like 'decklist.%')::text, '4');

-- After round 1: players are locked out, organizers can still fix lists.
reset role;
insert into public.rounds (event_id, number, status) values (:'dl', 1, 'active');
update public.events set status = 'in_progress', current_round = 1 where id = :'dl';
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.throws('players'' lists lock at round 1', $$select public.decklist_submit((select p.id from public.participants p join public.events e on e.id = p.event_id where e.decklists = 'required' and p.display_name = 'bea'), '60 Island')$$, '55000');
select pg_temp.as_user(:A);
select pg_temp.eq('the organizer can still fix one', public.decklist_submit(:'dl_bea', '60 Island')->>'main_count', '60');

-- The public link shows every round's matchups (names only, newest first) -----------------------------------
select pg_temp.as_user(null);
set role anon;
select pg_temp.eq('public rounds: newest first with stages', (select string_agg((r->>'number') || ':' || (r->>'stage') || ':' || jsonb_array_length(r->'matches'), ',')
  from jsonb_array_elements(public.event_public(:'ev')->'rounds') r), '3:quarterfinal:1,1:swiss:0');
select pg_temp.eq('public matchups carry names, no account ids', (select (m->'sides'->0 ? 'display_name')::text || '|' || (m->'sides'->0 ? 'user_id')::text
  from jsonb_array_elements(public.event_public(:'ev')->'rounds'->0->'matches') m), 'true|false');
set role authenticated;
