-- Drafts with several pods: the organizer's pods, pairing inside or across pods, automatic rounds that follow the
-- pods, re-draws, seating newcomers, moving and swapping players by hand (20261109150000_draft_pods,
-- contract/draft-pods-2026-11-09.md).
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'bea@example.com'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com');
\set A '''00000000-0000-0000-0000-0000000000a1'''
\set B '''00000000-0000-0000-0000-0000000000b1'''
\set C '''00000000-0000-0000-0000-0000000000c1'''

-- Pod sizes in display order ("6,6,5"), and whether every pod's seats run 1..n with no gaps.
create or replace function pg_temp.sizes(p_event uuid) returns text language sql as $$
  select coalesce(string_agg(n::text, ',' order by d.display_order), '') from public.pods d
    cross join lateral (select count(*) n from public.participants p
                         where p.pod_id = d.id and p.status = 'active' and p.seat is not null) c
   where d.event_id = p_event and c.n > 0
$$;
create or replace function pg_temp.tidy(p_event uuid) returns text language sql as $$
  select (bool_and(x.ok) and count(*) > 0)::text from (
    select (min(p.seat) = 1 and max(p.seat) = count(*) and count(distinct p.seat) = count(*)) ok
      from public.participants p where p.event_id = p_event and p.status = 'active' and p.seat is not null
     group by p.pod_id) x
$$;
create or replace function pg_temp.seat_of(p_name text) returns text language sql as $$
  select d.name || '#' || p.seat from public.participants p join public.pods d on d.id = p.pod_id
   where p.display_name = p_name order by p.created_at desc limit 1
$$;
create or replace function pg_temp.pid(p_name text) returns uuid language sql as $$
  select id from public.participants where display_name = p_name order by created_at desc limit 1
$$;
create or replace function pg_temp.pod(p_event uuid, p_name text) returns uuid language sql as $$
  select id from public.pods where event_id = p_event and name = p_name
$$;

set role authenticated;
select pg_temp.as_user(:A);

-- Defaults and automatic rounds -------------------------------------------------------------------------
select (public.create_event_v2(p_format_name => 'draft', p_set_name => 'Foundations', p_auto_rounds => true,
          p_player_names => array(select 'P' || lpad(i::text, 2, '0') from generate_series(1, 16) i))->>'event_id') as ev \gset
select pg_temp.eq('a new draft pairs inside pods, pods automatic',
  (select pod_pairing || '|' || coalesce(pods::text, 'auto') from public.events where id = :'ev'), 'pod|auto');
select pg_temp.eq('17 players in pods of up to 8 (6, 6, 5): 3 rounds', (select number_of_rounds::text from public.events where id = :'ev'), '3');
select pg_temp.eq('set_event_pods answers the pick and the rounds',
  (select (x->>'pods') || '|' || (x->>'pod_pairing') || '|' || (x->>'number_of_rounds') || '|' || (x->>'reseated')
     from public.set_event_pods(:'ev', 2, 'pod') x), '2|pod|4|false');
select pg_temp.eq('across pods: enough rounds for all 17', (select (x->>'number_of_rounds') from public.set_event_pods(:'ev', 2, 'cross') x), '5');
select pg_temp.eq('one pod of 17 inside pods: 5', (select (x->>'number_of_rounds') from public.set_event_pods(:'ev', 1, 'pod') x), '5');
select pg_temp.eq('every change is audited', (select count(*)::text from public.audit_log where event_id = :'ev' and action = 'event.pods_updated'), '3');

-- The draw ---------------------------------------------------------------------------------------------
select public.set_event_pods(:'ev', null, 'pod');
select public.seat_event(:'ev');
select pg_temp.eq('automatic: 17 → 6, 6, 5', pg_temp.sizes(:'ev'), '6,6,5');
select pg_temp.eq('seats run 1..n in every pod', pg_temp.tidy(:'ev'), 'true');
select pg_temp.eq('seated', (select status from public.events where id = :'ev'), 'seated');
select pg_temp.eq('3 rounds from the seated pods', (select number_of_rounds::text from public.events where id = :'ev'), '3');
select pg_temp.eq('a new number of pods re-draws the seats',
  (select (x->>'reseated') || '|' || jsonb_array_length(x->'seating') from public.set_event_pods(:'ev', 4, 'pod') x), 'true|4');
select pg_temp.eq('4 pods: 5, 4, 4, 4', pg_temp.sizes(:'ev'), '5,4,4,4');
select pg_temp.eq('4 pods: 3 rounds for the pod of 5', (select number_of_rounds::text from public.events where id = :'ev'), '3');
select public.set_event_pods(:'ev', 2, 'pod');
select pg_temp.eq('2 pods: 9, 8', pg_temp.sizes(:'ev'), '9,8');
select pg_temp.eq('the pods a re-draw no longer needs are gone', (select count(*)::text from public.pods where event_id = :'ev'), '2');
select pg_temp.eq('only the pairing changing keeps the seats',
  (select (x->>'reseated') from public.set_event_pods(:'ev', 2, 'cross') x), 'false');
select public.set_event_pods(:'ev', 2, 'pod');
select pg_temp.eq('the seat_event answer lists the pods', (select json_array_length(x->'pods')::text from public.seat_event(:'ev') x), '2');
reset role;
select pg_temp.eq('more pods than pairs of players: as many as pairs (3 players, pick 4 → 1 pod)',
  (select string_agg(t1_private.pod_count(n, p)::text, ',') from (values (3, 4), (4, 4), (9, 4), (17, null), (0, 2)) v(n, p)), '1,2,4,3,0');
set role authenticated;

-- Moving players by hand -------------------------------------------------------------------------------
select pg_temp.pod(:'ev', 'Pod 1') as pod1 \gset
select pg_temp.pod(:'ev', 'Pod 2') as pod2 \gset
select (select display_name from public.participants where pod_id = :'pod1' and seat = 3) as mover \gset
select public.seat_move(pg_temp.pid(:'mover'), :'pod2', 2);
select pg_temp.eq('moved to Pod 2, seat 2', pg_temp.seat_of(:'mover'), 'Pod 2#2');
select pg_temp.eq('now 8 and 9', pg_temp.sizes(:'ev'), '8,9');
select pg_temp.eq('both pods close up and open up', pg_temp.tidy(:'ev'), 'true');
select pg_temp.eq('moving round 1 inside pods: rounds follow the pod of 9', (select number_of_rounds::text from public.events where id = :'ev'), '4');
select public.seat_move(pg_temp.pid(:'mover'), :'pod2', null);
select pg_temp.eq('no seat: the end of the pod', pg_temp.seat_of(:'mover'), 'Pod 2#9');
select public.seat_move(pg_temp.pid(:'mover'), :'pod2', 1);
select pg_temp.eq('inside the same pod: reordered', pg_temp.seat_of(:'mover') || '|' || pg_temp.tidy(:'ev'), 'Pod 2#1|true');
select public.seat_move(pg_temp.pid(:'mover'), :'pod1', 99);
select pg_temp.eq('a seat past the end: the end', pg_temp.seat_of(:'mover'), 'Pod 1#9');
select public.seat_move(pg_temp.pid(:'mover'), null, null);
select pg_temp.eq('no pod: a new Pod 3', pg_temp.seat_of(:'mover') || '|' || pg_temp.sizes(:'ev'), 'Pod 3#1|8,8,1');
select (select display_name from public.participants where pod_id = :'pod2' and seat = 4) as second \gset
select public.seat_move(pg_temp.pid(:'second'), pg_temp.pod(:'ev', 'Pod 3'), 1);
select pg_temp.eq('into Pod 3 ahead of the first mover', pg_temp.seat_of(:'second') || '|' || pg_temp.seat_of(:'mover') || '|' || pg_temp.tidy(:'ev'),
  'Pod 3#1|Pod 3#2|true');
select public.seat_move(pg_temp.pid(:'second'), :'pod2', null);
select public.seat_move(pg_temp.pid(:'mover'), null, null);
select pg_temp.eq('an emptied pod is the next new pod (no Pod 4)',
  pg_temp.seat_of(:'mover') || '|' || (select count(*) from public.pods where event_id = :'ev'), 'Pod 3#1|3');
select pg_temp.eq('moves are audited with where from and to',
  (select count(*) || '|' || bool_and((before->>'seat') is not null and (after->>'pod_id') is not null) from public.audit_log
    where event_id = :'ev' and action = 'participant.seat_moved'), '8|true');

-- Swapping
select (select display_name from public.participants where pod_id = :'pod1' and seat = 1) as one \gset
select (select display_name from public.participants where pod_id = :'pod2' and seat = 5) as two \gset
select public.seat_swap(pg_temp.pid(:'one'), pg_temp.pid(:'two'));
select pg_temp.eq('swapped pod and seat', pg_temp.seat_of(:'one') || '|' || pg_temp.seat_of(:'two'), 'Pod 2#5|Pod 1#1');
select pg_temp.eq('a swap is audited', (select count(*)::text from public.audit_log where event_id = :'ev' and action = 'participant.seats_swapped'), '1');
select pg_temp.eq('swapping with yourself changes nothing', (select json_array_length(x->'pods')::text from public.seat_swap(pg_temp.pid(:'one'), pg_temp.pid(:'one')) x), '3');

-- Randomize: a draw puts everyone back into the pick (2 pods), Pod 3 goes.
select public.seat_event(:'ev');
select pg_temp.eq('randomize all: back to the pick', pg_temp.sizes(:'ev') || '|' || (select count(*) from public.pods where event_id = :'ev'), '9,8|2');

-- Newcomers after the draw ------------------------------------------------------------------------------
select (select display_name from public.participants where pod_id = :'pod1' and seat = 1) as pmove \gset
select public.seat_move(pg_temp.pid(:'pmove'), :'pod2', null);   -- 8 and 9 now, by hand
select (select string_agg(display_name || '@' || seat, ',' order by display_name) from public.participants where event_id = :'ev') as before \gset
select public.add_guest(:'ev', 'Late Lou');
select pg_temp.eq('a guest added to a seated draft waits unseated', (select coalesce(seat::text, 'none') from public.participants where display_name = 'Late Lou'), 'none');
select pg_temp.as_user(:B);
select pg_temp.eq('Bea signs up to the seated draft', public.event_sign_up(:'ev')->>'status', 'joined');
reset role;
select pg_temp.eq('… and waits unseated too', (select coalesce(seat::text, 'none') from public.participants
    where event_id = :'ev' and user_id = :B), 'none');
set role authenticated;
select pg_temp.as_user(:C);
select pg_temp.throws('only organizers seat newcomers', format('select public.seat_fill(%L)', :'ev'), '42501');
select pg_temp.as_user(:A);
select public.seat_fill(:'ev');
select pg_temp.eq('seat_fill: each newcomer to the smallest pod (the first on a tie), at the end',
  pg_temp.sizes(:'ev') || '|' || pg_temp.tidy(:'ev') || '|' || (select string_agg(seat::text, ',' order by seat) from public.participants
    where event_id = :'ev' and (display_name = 'Late Lou' or user_id = :B)), '10,9|true|9,10');
select pg_temp.eq('nobody already seated moved',
  (select string_agg(display_name || '@' || seat, ',' order by display_name) from public.participants
    where event_id = :'ev' and display_name <> 'Late Lou' and user_id is distinct from :B), :'before');
select pg_temp.eq('seat_fill is audited', (select (after->>'players') from public.audit_log where event_id = :'ev' and action = 'event.seats_filled'), '2');

-- Refusals ---------------------------------------------------------------------------------------------
select pg_temp.throws('pods are 1 to 16', format('select public.set_event_pods(%L, 17, ''pod'')', :'ev'), '22023');
select pg_temp.throws('pair inside or across', format('select public.set_event_pods(%L, 2, ''sideways'')', :'ev'), '22023');
select pg_temp.throws('a move to another event''s pod', format('select public.seat_move(%L, gen_random_uuid(), 1)', pg_temp.pid('P02')), '22023');
select (public.create_event_v2(p_format_name => 'sealed', p_set_name => 'Foundations')->>'event_id') as sealed \gset
select pg_temp.throws('pods are for drafts', format('select public.set_event_pods(%L, 2, ''pod'')', :'sealed'), '55000');
select (public.create_event_v2(p_format_name => 'team_draft', p_team_size => 3)->>'event_id') as teamdraft \gset
select pg_temp.throws('a team draft has one pod', format('select public.set_event_pods(%L, 2, ''pod'')', :'teamdraft'), '55000');
select pg_temp.as_user(:C);
select pg_temp.throws('only organizers set pods', format('select public.set_event_pods(%L, 2, ''pod'')', :'ev'), '42501');
select pg_temp.throws('only organizers move players', format('select public.seat_move(%L, null, null)', pg_temp.pid('P02')), '42501');
select pg_temp.throws('only organizers swap players', format('select public.seat_swap(%L, %L)', pg_temp.pid('P02'), pg_temp.pid('P03')), '42501');
select pg_temp.as_user(null);
set role anon;
select pg_temp.throws('signed out: no pods', format('select public.set_event_pods(%L, 2, ''pod'')', :'ev'), '42501');
set role authenticated;
select pg_temp.as_user(:A);

-- Unseated players can't be moved; a new draft before the draw has nothing to move.
select (public.create_event_v2(p_format_name => 'draft', p_player_names => array['X', 'Y', 'Z'])->>'event_id') as fresh \gset
select pg_temp.throws('seat players before moving them', format('select public.seat_move(%L, null, null)', pg_temp.pid('X')), '55000');
select pg_temp.eq('before the draw a new pick just saves', (select (x->>'reseated') from public.set_event_pods(:'fresh', 2, 'cross') x), 'false');

-- After round 1 everything locks.
reset role;
insert into public.rounds (event_id, number) values (:'ev', 1);
set role authenticated;
select pg_temp.throws('pods lock at round 1', format('select public.set_event_pods(%L, 3, ''pod'')', :'ev'), '55000');
select pg_temp.throws('moves lock at round 1', format('select public.seat_move(%L, null, null)', pg_temp.pid('P02')), '55000');
select pg_temp.throws('swaps lock at round 1', format('select public.seat_swap(%L, %L)', pg_temp.pid('P02'), pg_temp.pid('P03')), '55000');
select pg_temp.throws('re-draws lock at round 1', format('select public.seat_event(%L)', :'ev'), '55000');
select pg_temp.throws('seat_fill locks at round 1', format('select public.seat_fill(%L)', :'ev'), '55000');

-- Older events keep pairing across pods; the reads carry the new fields.
reset role;
select pg_temp.eq('the column default for new events is inside pods',
  (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'events' and column_name = 'pod_pairing'),
  '''pod''::text');
set role authenticated;
select pg_temp.eq('event_bundle carries pods and pod_pairing',
  (select (b->'event'->>'pod_pairing') || '|' || (b->'event'->>'pods') || '|' ||
          (select string_agg(x->>'name', ',' order by (x->>'display_order')::int) from jsonb_array_elements(b->'pods') x)
     from public.event_bundle(:'ev') b), 'pod|2|Pod 1,Pod 2');
reset role;
select pg_temp.eq('helpers closed to clients',
  (select string_agg(has_function_privilege('authenticated', f, 'execute')::text, ',') from unnest(array[
    't1_private.pod_count(integer, integer)', 't1_private.auto_round_count(uuid, text, integer, text, text)',
    't1_private.seating_json(uuid)']) f), 'false,false,false');
select pg_temp.eq('anon can''t move or set pods',
  (select string_agg(has_function_privilege('anon', f, 'execute')::text, ',') from unnest(array[
    'public.seat_move(uuid, uuid, integer)', 'public.seat_swap(uuid, uuid)', 'public.set_event_pods(uuid, integer, text)',
    'public.seat_fill(uuid)']) f), 'false,false,false,false');

-- seat_fill before the draw is the draw (setup: everyone holds a placeholder seat in pod 1).
set role authenticated;
select pg_temp.as_user(:A);
select (public.create_event_v2(p_format_name => 'draft',
          p_player_names => array(select 'Q' || i from generate_series(1, 11) i))->>'event_id') as early \gset
select public.set_event_pods(:'early', 2, 'pod');
select public.seat_fill(:'early');
select pg_temp.eq('seat_fill in setup draws the pods', pg_temp.sizes(:'early') || '|' || (select status from public.events where id = :'early'),
  '6,6|seated');
