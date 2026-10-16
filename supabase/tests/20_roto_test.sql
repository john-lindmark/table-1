-- Roto checks (20261016220000_roto.sql). Run after the migration inside one transaction that is thrown away:
-- the last block always raises, and its message is the report ("ROTO n/m passed" + any failures). Used through the
-- Supabase SQL tool as: begin; <migration>; <this file>  — nothing persists.

create temp table t_results (n serial, label text, ok boolean, detail text);
create function pg_temp.eq(label text, got text, want text) returns void language plpgsql as $$
begin insert into t_results (label, ok, detail) values (label, got is not distinct from want, format('got %s, want %s', got, want)); end $$;
create function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(u::text, ''), true);
end $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return 'none'; exception when others then return sqlstate; end $$;
-- One pick by whoever is on the clock (the organizer for a guest), lowest free slot.
create function pg_temp.pick_next(ev uuid) returns jsonb language plpgsql as $$
declare d public.roto_drafts; v_u uuid; v_slot int;
begin
  select * into d from public.roto_drafts where event_id = ev;
  select user_id into v_u from public.participants where id = t1_private.roto_on_clock(d);
  perform pg_temp.as_user(coalesce(v_u, '00000000-0000-4000-8000-0000000000a1'));
  select min(slot) into v_slot from public.roto_pool p where p.event_id = ev
     and not exists (select 1 from public.roto_picks k where k.event_id = ev and k.slot = p.slot);
  return public.roto_pick(ev, v_slot, d.picks_made + 1);
end $$;
create function pg_temp.on_clock_user(ev uuid) returns uuid language sql as $$
  select p.user_id from public.roto_drafts d join public.participants p on p.id = t1_private.roto_on_clock(d) where d.event_id = ev $$;
create function pg_temp.deck_sum(ev uuid, u uuid) returns text language sql as $$
  select coalesce(sum(e.qty), 0)::text from public.card_lists l join public.card_list_entries e on e.list_id = l.id
   where l.event_id = ev and l.user_id = u and l.deleted_at is null $$;
create function pg_temp.picks_of(ev uuid, u uuid) returns text language sql as $$
  select count(*)::text from public.roto_picks k join public.participants p on p.id = k.participant_id
   where k.event_id = ev and p.user_id = u $$;
create temp table t_ids (k text primary key, id uuid);

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-0000000000a1', 'roto-a@example.test', '{"name": "Ana Org"}'),
  ('00000000-0000-4000-8000-0000000000b1', 'roto-b@example.test', '{"name": "Ben"}'),
  ('00000000-0000-4000-8000-0000000000c1', 'roto-c@example.test', '{"name": "Cy"}'),
  ('00000000-0000-4000-8000-0000000000d1', 'roto-d@example.test', '{"name": "Dee"}');
insert into public.profiles (id, display_name) select id, raw_user_meta_data->>'name' from auth.users
 where email like 'roto-_@example.test' on conflict (id) do nothing;

-- ------------------------------------------------------------------ create, cube, clock, start
do $$
declare
  A uuid := '00000000-0000-4000-8000-0000000000a1'; B uuid := '00000000-0000-4000-8000-0000000000b1';
  C uuid := '00000000-0000-4000-8000-0000000000c1';
  ev uuid; r jsonb; l uuid := gen_random_uuid(); e public.events; v_pod uuid;
begin
  perform pg_temp.as_user(A);
  perform pg_temp.eq('round robin refused for a draft',
    pg_temp.err($q$select public.create_event_v2(p_format_name => 'draft', p_pairing => 'round_robin')$q$), '22023');
  perform pg_temp.eq('roto needs a cube', pg_temp.err($q$select public.create_event_v2(p_format_name => 'roto')$q$), '22023');
  r := public.create_event_v2(p_format_name => 'roto', p_cube_name => 'Test Cube', p_player_names => array['Gus'],
                              p_rounds => 3, p_local_date => '2026-10-16')::jsonb;
  ev := (r->>'event_id')::uuid;
  insert into t_ids values ('ev', ev), ('list', l);
  select * into e from public.events where id = ev;
  perform pg_temp.eq('format is cube', e.format, 'cube');
  perform pg_temp.eq('label', e.format_label, 'Roto · Test Cube');
  perform pg_temp.eq('pairing defaults to round robin', e.pairing, 'round_robin');
  perform pg_temp.eq('auto name', e.name, 'Roto · Test Cube · Fri 16 Oct');
  perform pg_temp.eq('draft row made', (select count(*)::text from public.roto_drafts where event_id = ev), '1');

  select id into v_pod from public.pods where event_id = ev limit 1;
  insert into public.participants (event_id, pod_id, user_id, display_name) values (ev, v_pod, B, 'Ben'), (ev, v_pod, C, 'Cy');

  perform public.list_create(l, 'cube', 'Test Cube', 'vintage', (
    select jsonb_agg(jsonb_build_array(x.card_id, 'main', 1)) from (
      select o.source_card_id card_id from public.card_oracles o join public.cards c on c.id = o.source_card_id
       where 'nonfoil' = any (c.finishes) and o.type_line not like 'Basic%' order by o.name limit 50) x));
  r := public.roto_set_cube(ev, l);
  perform pg_temp.eq('pool', r->>'pool_count', '50');
  perform pg_temp.eq('players', r->>'players', '4');
  perform pg_temp.eq('max picks each', r->>'max_picks_per_player', '12');
  perform pg_temp.as_user(B);
  perform pg_temp.eq('set cube: organizers only', pg_temp.err(format('select public.roto_set_cube(%L, %L)', ev, l)), '42501');
  perform pg_temp.eq('state before start: players see it', (public.roto_state(ev))->>'phase', 'setup');
  perform pg_temp.as_user(A);
  perform pg_temp.eq('too many picks for the cube', pg_temp.err(format('select public.roto_start(%L, 13)', ev)), '22023');

  r := public.roto_set_clock(ev, '[{"from_round": 3, "seconds": 30}, {"from_round": 1, "seconds": 60}]');
  perform pg_temp.eq('clock sorted', r->'draft'->'clock'->1->>'from_round', '3');
  perform pg_temp.eq('clock must start at round 1',
    pg_temp.err(format($q$select public.roto_set_clock(%L, '[{"from_round": 2, "seconds": 60}]')$q$, ev)), '22023');
  perform pg_temp.eq('clock: 30 s minimum',
    pg_temp.err(format($q$select public.roto_set_clock(%L, '[{"from_round": 1, "seconds": 5}]')$q$, ev)), '22023');

  r := public.roto_start(ev, 10, 'snake');
  perform pg_temp.eq('phase drafting', r->>'phase', 'drafting');
  perform pg_temp.eq('total picks', r->'draft'->>'total_picks', '40');
  perform pg_temp.eq('pool sent on start', jsonb_array_length(r->'pool')::text, '50');
  perform pg_temp.eq('seat 1 on the clock', r->'on_clock'->>'seat', '1');
  perform pg_temp.eq('round 1 time', r->'on_clock'->>'turn_seconds', '60');
  perform pg_temp.eq('one pod, four seats', (select count(distinct seat)::text from public.participants where event_id = ev), '4');
  perform pg_temp.eq('decks for the three accounts', (select count(*)::text from public.card_lists where event_id = ev), '3');
  perform pg_temp.eq('decks are decks', (select string_agg(distinct kind, ',') from public.card_lists where event_id = ev), 'deck');
  perform pg_temp.eq('start twice', pg_temp.err(format('select public.roto_start(%L)', ev)), '55000');
  perform pg_temp.eq('no adds once started', pg_temp.err(format('select public.add_guest(%L, %L)', ev, 'Late')), '55000');
  perform pg_temp.eq('no re-seat once started', pg_temp.err(format('select public.seat_event(%L)', ev)), '55000');
  perform pg_temp.eq('cube locked once started', pg_temp.err(format(
    'select public.update_event_details(%L, null, %L, 3, 3000, null, null, %L)', ev, 'roto', 'Other Cube')), '55000');
  perform pg_temp.eq('details still editable (pairing)', pg_temp.err(format(
    'select public.update_event_details(%L, null, %L, 3, 3000, null, null, %L, null, null, null, null, %L)',
    ev, 'roto', 'Test Cube', 'swiss')), 'none');
  perform pg_temp.eq('pairing now swiss', (select pairing from public.events where id = ev), 'swiss');
end $$;

-- ------------------------------------------------------------------ picking
do $$
declare
  A uuid := '00000000-0000-4000-8000-0000000000a1'; B uuid := '00000000-0000-4000-8000-0000000000b1';
  C uuid := '00000000-0000-4000-8000-0000000000c1'; D uuid := '00000000-0000-4000-8000-0000000000d1';
  ev uuid := (select id from t_ids where k = 'ev');
  r jsonb; v_u uuid; v_other uuid; v_slot int; v_first int; v_free int[]; i int; v_n int;
begin
  -- Wrong player, stale pick number, taken card.
  v_u := pg_temp.on_clock_user(ev);
  select p.user_id into v_other from public.participants p
   where p.event_id = ev and p.user_id is not null and p.user_id not in (A, coalesce(v_u, A)) limit 1;
  perform pg_temp.as_user(v_other);
  perform pg_temp.eq('not your pick', pg_temp.err(format('select public.roto_pick(%L, 1, 1)', ev)), '42501');
  perform pg_temp.as_user(coalesce(v_u, A));
  r := public.roto_pick(ev, 1, 5);
  perform pg_temp.eq('stale pick number → conflict', r->>'conflict', 'true');
  perform pg_temp.eq('stale pick number → nothing picked', (select picks_made::text from public.roto_drafts where event_id = ev), '0');
  perform pg_temp.eq('unknown card', pg_temp.err(format('select public.roto_pick(%L, 999, 1)', ev)), '22023');

  for i in 1 .. 8 loop r := pg_temp.pick_next(ev); end loop;
  perform pg_temp.eq('snake order', (select string_agg(array_position(d2.seat_order, k.participant_id)::text, ',' order by k.pick_no)
                                       from public.roto_picks k join public.roto_drafts d2 on d2.event_id = k.event_id
                                      where k.event_id = ev), '1,2,3,4,4,3,2,1');
  perform pg_temp.eq('guest picks are organizer picks',
    (select string_agg(distinct k.how, ',') from public.roto_picks k join public.participants p on p.id = k.participant_id
      where k.event_id = ev and p.user_id is null), 'organizer');
  perform pg_temp.as_user(coalesce(pg_temp.on_clock_user(ev), A));
  perform pg_temp.eq('taken card', pg_temp.err(format('select public.roto_pick(%L, 1, 9)', ev)), '23505');
  perform pg_temp.eq('round 3 clock', ((public.roto_state(ev, 8))->'on_clock'->>'turn_seconds'), '30');
  perform pg_temp.eq('picks delta only', jsonb_array_length((public.roto_state(ev, 8))->'picks')::text, '0');
  perform pg_temp.eq('no pool on delta', (public.roto_state(ev, 8))->>'pool', null);

  -- B lists five cards (auto on by default); C lists two with auto off.
  select array_agg(slot order by slot desc) into v_free from (
    select slot from public.roto_pool p where p.event_id = ev
       and not exists (select 1 from public.roto_picks k where k.event_id = ev and k.slot = p.slot)
     order by slot desc limit 7) x;
  perform pg_temp.as_user(B);
  r := public.roto_queue_set(ev, v_free[1:5] || v_free[1:1] || array[1]);   -- duplicate and taken are dropped
  perform pg_temp.eq('B auto default', r->>'auto_pick', 'true');
  perform pg_temp.as_user(C);
  r := public.roto_queue_set(ev, v_free[6:7], false);
  perform pg_temp.eq('C list kept', jsonb_array_length(r->'queue')::text, '2');
  perform pg_temp.eq('C auto off', r->>'auto_pick', 'false');
  perform pg_temp.as_user(D);
  perform pg_temp.eq('outsider has no list', pg_temp.err(format('select public.roto_queue_set(%L, %L)', ev, '{1}')), '42501');
  perform pg_temp.eq('outsider can''t read', pg_temp.err(format('select public.roto_state(%L)', ev)), '42501');

  -- Play on until B has made an auto-pick (C never auto-picks: its switch is off).
  for i in 1 .. 8 loop
    exit when exists (select 1 from public.roto_picks k join public.participants p on p.id = k.participant_id
                       where k.event_id = ev and p.user_id = B and k.how = 'auto');
    r := pg_temp.pick_next(ev);
  end loop;
  perform pg_temp.eq('B auto-picked from the list', (select count(*) > 0 from public.roto_picks k join public.participants p
    on p.id = k.participant_id where k.event_id = ev and p.user_id = B and k.how = 'auto')::text, 'true');
  perform pg_temp.eq('auto-pick takes the first listed', (select k.slot from public.roto_picks k join public.participants p
    on p.id = k.participant_id where k.event_id = ev and p.user_id = B and k.how = 'auto' order by k.pick_no limit 1)::text,
    v_free[1]::text);
  perform pg_temp.eq('taken cards leave lists', (select count(*)::text from public.roto_queue q
    where q.event_id = ev and exists (select 1 from public.roto_picks k where k.event_id = ev and k.slot = q.slot)), '0');
  perform pg_temp.eq('C made no auto-picks', (select count(*)::text from public.roto_picks k join public.participants p
    on p.id = k.participant_id where k.event_id = ev and p.user_id = C and k.how = 'auto'), '0');
  perform pg_temp.eq('B deck = B picks', pg_temp.deck_sum(ev, B), pg_temp.picks_of(ev, B));
  perform pg_temp.eq('A deck = A picks', pg_temp.deck_sum(ev, A), pg_temp.picks_of(ev, A));
  perform pg_temp.eq('deck note', (select v.note from public.card_lists l join public.card_list_versions v
    on v.list_id = l.id and v.version = l.current_version where l.event_id = ev and l.user_id = B), 'Roto picks');
  perform pg_temp.eq('picks extend one version', (select max(v.version)::text from public.card_lists l
    join public.card_list_versions v on v.list_id = l.id where l.event_id = ev and l.user_id = B), '1');
  perform pg_temp.eq('event deck carries the event', (select (t1_private.list_json(l.id))->>'event_id' from public.card_lists l
    where l.event_id = ev and l.user_id = B), ev::text);

  -- Undo: the last pick someone made plus the auto-picks after it.
  select max(pick_no) into v_first from public.roto_picks where event_id = ev and how in ('player', 'organizer');
  perform pg_temp.as_user(B);
  perform pg_temp.eq('undo: organizers only', pg_temp.err(format('select public.roto_undo(%L)', ev)), '42501');
  perform pg_temp.as_user(A);
  r := public.roto_undo(ev);
  perform pg_temp.eq('undo back to before that pick', r->'draft'->>'picks_made', (v_first - 1)::text);
  perform pg_temp.eq('undo keeps decks in step (B)', pg_temp.deck_sum(ev, B), pg_temp.picks_of(ev, B));
  perform pg_temp.eq('undo keeps decks in step (A)', pg_temp.deck_sum(ev, A), pg_temp.picks_of(ev, A));

  -- Clock: pause and resume.
  r := public.roto_set_clock(ev, null, true);
  perform pg_temp.eq('paused: no deadline', r->'on_clock'->>'deadline', null);
  perform pg_temp.eq('paused: remaining shown', (r->'on_clock'->>'remaining_seconds' is not null)::text, 'true');
  r := public.roto_set_clock(ev, null, false);
  perform pg_temp.eq('resumed: deadline back', (r->'on_clock'->>'deadline' is not null)::text, 'true');

  -- Timeout: play on to B's turn; B's list (auto off) is used when time runs out.
  perform pg_temp.as_user(C);
  perform public.roto_queue_set(ev, '{}', false);
  perform pg_temp.as_user(B);
  perform public.roto_queue_set(ev, '{}', false);
  for i in 1 .. 8 loop exit when pg_temp.on_clock_user(ev) = B; r := pg_temp.pick_next(ev); end loop;
  perform pg_temp.eq('B on the clock', pg_temp.on_clock_user(ev)::text, B::text);
  select min(slot) into v_slot from public.roto_pool p where p.event_id = ev
     and not exists (select 1 from public.roto_picks k where k.event_id = ev and k.slot = p.slot);
  perform pg_temp.as_user(B);
  r := public.roto_queue_set(ev, array[v_slot], false);
  perform pg_temp.eq('auto off: listing doesn''t pick', (r->'queue'->>0), v_slot::text);
  perform pg_temp.as_user(C);
  r := public.roto_expire(ev);
  perform pg_temp.eq('before the deadline nothing happens', r->>'overdue', 'false');
  update public.roto_drafts set turn_started_at = now() - interval '10 minutes' where event_id = ev;
  select picks_made into v_n from public.roto_drafts where event_id = ev;
  r := public.roto_expire(ev);
  perform pg_temp.eq('timeout picks from the list', (select how || ':' || slot from public.roto_picks where event_id = ev and pick_no = v_n + 1),
                     'timeout:' || v_slot);
  -- Next player has nothing listed: the turn waits, overdue.
  perform pg_temp.as_user(A);
  delete from public.roto_queue where event_id = ev;
  update public.roto_drafts set turn_started_at = now() - interval '10 minutes' where event_id = ev;
  select picks_made into v_n from public.roto_drafts where event_id = ev;
  r := public.roto_expire(ev);
  perform pg_temp.eq('empty list: overdue', r->>'overdue', 'true');
  perform pg_temp.eq('empty list: no pick', r->>'picks_made', v_n::text);
  perform pg_temp.eq('cron sweep leaves it', t1_private.roto_expire_all()::text, '0');
  perform pg_temp.eq('state shows overdue', (public.roto_state(ev, v_n))->'on_clock'->>'overdue', 'true');
  update public.roto_drafts set turn_started_at = now() where event_id = ev;

  -- To the end.
  for i in 1 .. 60 loop
    exit when (select finished_at is not null from public.roto_drafts where event_id = ev);
    r := pg_temp.pick_next(ev);
  end loop;
  perform pg_temp.as_user(A);
  r := public.roto_state(ev);
  perform pg_temp.eq('done', r->>'phase', 'done');
  perform pg_temp.eq('40 picks', jsonb_array_length(r->'picks')::text, '40');
  perform pg_temp.eq('no one on the clock', r->>'on_clock', null);
  perform pg_temp.eq('ten each', (select string_agg(n::text, ',') from (select count(*) n from public.roto_picks
    where event_id = ev group by participant_id) x), '10,10,10,10');
  perform pg_temp.eq('final decks (A)', pg_temp.deck_sum(ev, A), '10');
  perform pg_temp.eq('final decks (B)', pg_temp.deck_sum(ev, B), '10');
  perform pg_temp.eq('pick after the end', pg_temp.err(format('select public.roto_pick(%L, 1, 41)', ev)), '55000');

  -- After the draft: drops allowed, seats and roster still locked.
  perform pg_temp.eq('drop after the draft', pg_temp.err(format(
    $q$update public.participants set status = 'dropped', dropped_in_round = 0 where event_id = %L and user_id = %L$q$, ev, C)), 'none');
  perform pg_temp.eq('seat change still locked', pg_temp.err(format(
    'update public.participants set seat = 9 where event_id = %L and user_id = %L', ev, B)), '55000');

  -- A guest's claim brings their deck.
  perform pg_temp.as_user(D);
  perform public.claim_participant((select t.token from public.participant_tokens t join public.participants p
    on p.id = t.participant_id where p.event_id = ev and p.user_id is null limit 1));
  perform pg_temp.eq('claimed guest gets the deck', pg_temp.deck_sum(ev, D), '10');
  perform pg_temp.eq('lists_changes carries event_id', (select (x->>'event_id') from jsonb_array_elements(
    (public.lists_changes(0, 100))->'lists') x where x->>'event_id' is not null limit 1), ev::text);
end $$;

-- ------------------------------------------------------------------ demo seed
do $$
declare A uuid := '00000000-0000-4000-8000-0000000000a1'; ev uuid; r jsonb;
begin
  insert into t1_private.demo_testers (user_id) values (A) on conflict do nothing;
  perform pg_temp.as_user(A);
  r := public.demo_seed();
  perform pg_temp.eq('demo events count', r->>'events', '11');
  perform pg_temp.eq('two demo rotos', (select count(*)::text from public.events where demo_owner = A and format_name = 'roto'), '2');
  select id into ev from public.events where demo_owner = A and name = 'Vintage Roto';
  r := public.roto_state(ev);
  perform pg_temp.eq('demo pool', r->'draft'->>'pool_count', '360');
  perform pg_temp.eq('demo picks', r->'draft'->>'picks_made', '124');
  perform pg_temp.eq('demo on the clock: seat 4', r->'on_clock'->>'seat', '4');
  perform pg_temp.eq('demo: you are seat 1', r->'me'->>'seat', '1');
  perform pg_temp.eq('demo list', jsonb_array_length(r->'me'->'queue')::text, '6');
  perform pg_temp.eq('demo deck', pg_temp.deck_sum(ev, A), '15');
  perform pg_temp.eq('demo clock round 16', r->'on_clock'->>'turn_seconds', '7200');
  perform pg_temp.eq('demo not overdue', r->'on_clock'->>'overdue', 'false');
  select id into ev from public.events where demo_owner = A and name = 'Legacy Cube Roto';
  r := public.roto_state(ev, 0, false);
  perform pg_temp.eq('demo done', r->>'phase', 'done');
  perform pg_temp.eq('demo done deck', pg_temp.deck_sum(ev, A), '45');
  perform pg_temp.eq('demo round robin round 3', (select current_round || '/' || pairing from public.events where id = ev), '3/round_robin');
  r := public.demo_remove();
  perform pg_temp.eq('demo rotos removed', (select count(*)::text from public.events where demo_owner = A), '0');
  perform pg_temp.eq('demo decks removed', (select count(*)::text from public.card_lists where user_id = A and deleted_at is null
                      and (name like 'Vintage Cube roto%' or name like 'Legacy Cube roto%')), '0');
end $$;

-- ------------------------------------------------------------------ report (always raises: nothing is kept)
do $$
begin
  raise exception 'ROTO % of % passed%', (select count(*) from t_results where ok), (select count(*) from t_results),
    coalesce(E'\n' || (select string_agg('FAIL ' || label || ': ' || detail, E'\n' order by n) from t_results where not ok), '');
end $$;
