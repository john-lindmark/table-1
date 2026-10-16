-- Roto (rotisserie) cube events, R0 (table-1-context/docs/plan-roto-2026-10-15.md).
--
-- A roto is a cube event where every card is face up: players take turns picking any card still in the pool, in
-- snake order by seat, until each has picks_per_player cards. Then the event runs rounds like any other (Swiss or
-- round robin, paired by events-engine).
--  - The pool is a snapshot of the organizer's Library cube taken at start (one row per copy, Main only).
--  - The server decides whose turn it is. roto_pick takes the pick number the client saw, so a stale tap never lands
--    on someone else's pick.
--  - Each player keeps a private ranked pick list (roto_queue). With auto-pick on (the default) the server takes the
--    first available card on it when their turn comes, in the same transaction as the pick before. A taken card
--    leaves every list at once.
--  - Optional pick clock: a schedule of seconds per range of rounds ({from_round, seconds}), so it can quicken deeper
--    into the draft. On timeout the first available card on the player's list is taken; with an empty list the
--    turn waits (overdue) and the organizer can pick for them. pg_cron sweeps every minute; clients also call
--    roto_expire when their countdown ends.
--  - Every pick lands in the picker's linked Library deck (card_lists.event_id), Main board. Event decks never count
--    Missing (clients skip lists with event_id); nothing is added to anyone's collection.
--  - Players are locked once the draft starts (no adds, removes, seat changes; no drops until the draft is over).
--  - Every mutation writes audit_log. Reads go through roto_state (players and organizers of the event only).
--  - Realtime: one broadcast per change on topic 'roto:<event_id>', event 'roto_changed', with picks_made; clients
--    then fetch roto_state(after = the last pick they have).

-- ==================================================================== events: format, label, pairing
alter table public.events drop constraint if exists events_format_name_check;
alter table public.events add constraint events_format_name_check check (format_name = any (array[
  'standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'premodern', 'canadian_highlander',
  'other_constructed', 'draft', 'team_draft', 'sealed', 'team_sealed', 'roto']));

alter table public.events add column if not exists pairing text not null default 'swiss';
alter table public.events drop constraint if exists events_pairing_check;
-- Round robin is offered for roto only for now (John, 2026-10-16).
alter table public.events add constraint events_pairing_check
  check (pairing in ('swiss', 'round_robin') and (pairing = 'swiss' or format_name = 'roto'));

create or replace function t1_private.event_label(p_format_name text, p_format_other text, p_set_name text, p_cube_name text)
returns text language sql immutable set search_path = '' as $$
  select case p_format_name
           when 'standard' then 'Standard' when 'pioneer' then 'Pioneer' when 'modern' then 'Modern'
           when 'legacy' then 'Legacy' when 'vintage' then 'Vintage' when 'pauper' then 'Pauper'
           when 'premodern' then 'Premodern' when 'canadian_highlander' then 'Canadian Highlander'
           when 'other_constructed' then coalesce(p_format_other, 'Constructed')
           when 'draft' then 'Draft' when 'team_draft' then 'Team draft'
           when 'sealed' then 'Sealed' when 'team_sealed' then 'Team sealed' when 'roto' then 'Roto' else 'Event' end
      || case when p_cube_name is not null then ' · ' || p_cube_name
              when p_set_name is not null then ' · ' || p_set_name else '' end
$$;

alter table public.events alter column format_label set expression as (
  case format_name
    when 'standard' then 'Standard' when 'pioneer' then 'Pioneer' when 'modern' then 'Modern'
    when 'legacy' then 'Legacy' when 'vintage' then 'Vintage' when 'pauper' then 'Pauper'
    when 'premodern' then 'Premodern' when 'canadian_highlander' then 'Canadian Highlander'
    when 'other_constructed' then coalesce(format_other, 'Constructed')
    when 'draft' then 'Draft' when 'team_draft' then 'Team draft'
    when 'sealed' then 'Sealed' when 'team_sealed' then 'Team sealed' when 'roto' then 'Roto'
    else 'Event' end
  || case when cube_name is not null then ' · ' || cube_name
          when set_name is not null then ' · ' || set_name else '' end);

create or replace function public.events_format_sync()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.format_name is null then
    new.format_name := case new.format when 'constructed' then 'other_constructed'
                                       when 'sealed' then 'sealed' else 'draft' end;
    if new.format = 'cube' and new.cube_name is null then new.cube_name := 'Cube'; end if;
  else
    new.format := case
      when new.format_name in ('sealed', 'team_sealed') then 'sealed'
      when new.format_name in ('draft', 'team_draft') then
        case when new.cube_name is not null then 'cube' else 'draft' end
      when new.format_name = 'roto' then 'cube'
      else 'constructed' end;
  end if;
  if new.format_name not in ('team_draft', 'team_sealed') then new.team_size := null; end if;
  if new.format_name is distinct from 'roto' then new.pairing := 'swiss'; end if;
  return new;
end $$;

-- ==================================================================== tables
create table if not exists public.roto_drafts (
  event_id uuid primary key references public.events(id) on delete cascade,
  picks_per_player integer not null default 45 check (picks_per_player between 1 and 100),
  pick_order text not null default 'snake' check (pick_order in ('snake', 'fixed')),
  source_list_id uuid,                         -- the organizer's Library cube (card_lists, kind = cube)
  source_version integer,                      -- its version when the pool was snapshotted
  pool_count integer not null default 0,
  players integer not null default 0,
  seat_order uuid[] not null default '{}',     -- participant ids by seat, frozen at start
  picks_made integer not null default 0,
  started_at timestamptz,
  finished_at timestamptz,
  clock jsonb,                                 -- [{from_round, seconds}, ...] ascending from round 1; null = no clock
  turn_started_at timestamptz,
  turn_seconds integer,                        -- this turn's time, fixed when the turn starts; null = untimed
  clock_paused_at timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists roto_drafts_clock_idx on public.roto_drafts (event_id)
  where started_at is not null and finished_at is null and turn_seconds is not null;

create table if not exists public.roto_pool (
  event_id uuid not null references public.events(id) on delete cascade,
  slot integer not null,                       -- 1..pool_count, one per copy
  card_id uuid not null references public.cards(id),
  oracle_id uuid not null,
  finish text not null default 'nonfoil',
  primary key (event_id, slot)
);

create table if not exists public.roto_picks (
  event_id uuid not null references public.events(id) on delete cascade,
  pick_no integer not null,
  participant_id uuid not null references public.participants(id) on delete cascade,
  slot integer not null,
  how text not null check (how in ('player', 'auto', 'timeout', 'organizer')),
  picked_by uuid,
  picked_at timestamptz not null default now(),
  primary key (event_id, pick_no),
  unique (event_id, slot)
);
create index if not exists roto_picks_participant_idx on public.roto_picks (participant_id, pick_no);

create table if not exists public.roto_queue (
  participant_id uuid not null references public.participants(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  slot integer not null,
  position integer not null,
  primary key (participant_id, slot)
);
create index if not exists roto_queue_order_idx on public.roto_queue (participant_id, position);
create index if not exists roto_queue_slot_idx on public.roto_queue (event_id, slot);

create table if not exists public.roto_settings (
  participant_id uuid primary key references public.participants(id) on delete cascade,
  auto_pick boolean not null default true
);

-- RPC-only: RLS on, no policies.
alter table public.roto_drafts enable row level security;
alter table public.roto_pool enable row level security;
alter table public.roto_picks enable row level security;
alter table public.roto_queue enable row level security;
alter table public.roto_settings enable row level security;

-- Linked decks: a Library deck that belongs to an event (one per account per event).
alter table public.card_lists add column if not exists event_id uuid references public.events(id) on delete set null;
create unique index if not exists card_lists_event_user_idx on public.card_lists (event_id, user_id)
  where event_id is not null and deleted_at is null;

-- ==================================================================== small helpers
-- 1-based seat index on the clock for a pick. Snake reverses every other round.
create or replace function t1_private.roto_seat_index(p_players integer, p_pick_no integer, p_snake boolean)
returns integer language sql immutable set search_path = '' as $$
  select case when p_snake and ((p_pick_no - 1) / p_players) % 2 = 1
              then p_players - (p_pick_no - 1) % p_players
              else (p_pick_no - 1) % p_players + 1 end
$$;

create or replace function t1_private.roto_round(p_players integer, p_pick_no integer)
returns integer language sql immutable set search_path = '' as $$
  select (p_pick_no - 1) / greatest(p_players, 1) + 1
$$;

-- Seconds for a round from the schedule (the last range starting at or before it); null without a clock.
create or replace function t1_private.roto_clock_seconds(p_clock jsonb, p_round integer)
returns integer language sql immutable set search_path = '' as $$
  select (r->>'seconds')::int from jsonb_array_elements(coalesce(p_clock, '[]'::jsonb)) r
   where (r->>'from_round')::int <= p_round order by (r->>'from_round')::int desc limit 1
$$;

-- Validates and normalizes a schedule: 1–10 ranges, first from round 1, rounds ascending, 30 s to 24 h.
create or replace function t1_private.roto_clock_clean(p_clock jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare v_out jsonb; v_n int;
begin
  if p_clock is null or jsonb_typeof(p_clock) = 'null' or p_clock = '[]'::jsonb then return null; end if;
  if jsonb_typeof(p_clock) <> 'array' or jsonb_array_length(p_clock) > 10 then
    raise exception 'A pick clock has 1 to 10 ranges' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_clock) r
              where jsonb_typeof(r->'from_round') <> 'number' or jsonb_typeof(r->'seconds') <> 'number'
                 or (r->>'from_round')::numeric < 1 or (r->>'seconds')::numeric not between 30 and 86400) then
    raise exception 'Each range starts at a round and takes 30 seconds to 24 hours per pick' using errcode = '22023';
  end if;
  select jsonb_agg(jsonb_build_object('from_round', f, 'seconds', s) order by f), count(distinct f)
    into v_out, v_n
    from (select (r->>'from_round')::int f, (r->>'seconds')::int s from jsonb_array_elements(p_clock) r) x;
  if v_n <> jsonb_array_length(v_out) then raise exception 'Two ranges start at the same round' using errcode = '22023'; end if;
  if (v_out->0->>'from_round')::int <> 1 then raise exception 'The first range starts at round 1' using errcode = '22023'; end if;
  return v_out;
end $$;

create or replace function t1_private.roto_deadline(d public.roto_drafts)
returns timestamptz language sql stable set search_path = '' as $$
  select case when d.started_at is null or d.finished_at is not null or d.turn_seconds is null
                   or d.clock_paused_at is not null then null
              else d.turn_started_at + make_interval(secs => d.turn_seconds) end
$$;

create or replace function t1_private.roto_on_clock(d public.roto_drafts)
returns uuid language sql immutable set search_path = '' as $$
  select case when d.started_at is null or d.finished_at is not null or d.players = 0 then null
              else d.seat_order[t1_private.roto_seat_index(d.players, d.picks_made + 1, d.pick_order = 'snake')] end
$$;

create or replace function t1_private.roto_broadcast(p_event_id uuid, p_kind text, p_picks_made integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform realtime.send(jsonb_build_object('event_id', p_event_id, 'kind', p_kind, 'picks_made', p_picks_made),
                        'roto_changed', 'roto:' || p_event_id::text, false);
end $$;

-- ==================================================================== linked decks
-- Adds (delta 1) or removes (delta −1, from Main, else Sideboard, else Considering) one copy in the picker's event
-- deck. Runs of picks extend one "Roto picks" version until the player edits the deck themselves.
create or replace function t1_private.roto_deck_change(p_event_id uuid, p_participant uuid, p_card uuid,
                                                       p_finish text, p_delta integer)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid;
  v_list public.card_lists;
  v_cur public.card_list_versions;
  v_board text;
begin
  select user_id into v_uid from public.participants where id = p_participant;
  if v_uid is null then return; end if;
  insert into public.library_summary (user_id) values (v_uid) on conflict do nothing;
  perform 1 from public.library_summary where user_id = v_uid for update;
  select * into v_list from public.card_lists
   where event_id = p_event_id and user_id = v_uid and deleted_at is null;
  if v_list.id is null then return; end if;
  select * into v_cur from public.card_list_versions where list_id = v_list.id and version = v_list.current_version;
  if p_delta > 0 then
    v_board := 'main';
  else
    select e->>1 into v_board from jsonb_array_elements(coalesce(v_cur.entries, '[]'::jsonb)) e
     where e->>0 = p_card::text and coalesce(e->>3, 'nonfoil') = p_finish
     order by case e->>1 when 'main' then 1 when 'side' then 2 else 3 end limit 1;
    if v_board is null then return; end if;
  end if;
  -- list_write merges duplicate lines by summing, and drops lines that reach 0.
  perform t1_private.list_write(v_list,
    coalesce(v_cur.entries, '[]'::jsonb) || jsonb_build_array(jsonb_build_array(p_card, v_board, sign(p_delta)::int, p_finish)),
    'Roto picks', v_cur.note = 'Roto picks');
  update public.card_list_versions v set open_until = null
    from public.card_lists l where l.id = v_list.id and v.list_id = l.id and v.version = l.current_version;
end $$;

-- Creates the event deck for a seat's account (at start, or when a guest claims the seat), from their picks so far.
create or replace function t1_private.roto_deck_create(p_participant uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  p record;
  v_list public.card_lists;
  v_entries jsonb;
begin
  select pt.id, pt.user_id, pt.event_id, e.cube_name, e.name_date into p
    from public.participants pt join public.events e on e.id = pt.event_id where pt.id = p_participant;
  if p.user_id is null then return; end if;
  if exists (select 1 from public.profiles pr where pr.id = p.user_id and pr.is_demo) then return; end if;
  insert into public.library_summary (user_id) values (p.user_id) on conflict do nothing;
  perform 1 from public.library_summary where user_id = p.user_id for update;
  if exists (select 1 from public.card_lists where event_id = p.event_id and user_id = p.user_id and deleted_at is null)
     or (select count(*) from public.card_lists where user_id = p.user_id and deleted_at is null) >= 500 then
    return;
  end if;
  insert into public.card_lists (id, user_id, kind, name, format, current_version, seq, event_id)
  values (gen_random_uuid(), p.user_id, 'deck',
          left(coalesce(p.cube_name, 'Cube') || ' roto · ' || to_char(coalesce(p.name_date, current_date), 'FMDD Mon'), 60),
          'cube', 0, nextval('public.card_list_seq'), p.event_id)
  returning * into v_list;
  select coalesce(jsonb_agg(jsonb_build_array(rp.card_id, 'main', 1, rp.finish)), '[]'::jsonb) into v_entries
    from public.roto_picks k join public.roto_pool rp on rp.event_id = k.event_id and rp.slot = k.slot
   where k.participant_id = p_participant;
  perform t1_private.list_write(v_list, v_entries, 'Roto picks', false);
  update public.card_list_versions set open_until = null where list_id = v_list.id;
end $$;

-- lists_changes / list_* answers carry the event link, so clients can show "From <event>" and skip Missing.
create or replace function t1_private.list_json(p_list_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', l.id, 'kind', l.kind, 'name', l.name, 'format', l.format, 'seq', l.seq,
    'current_version', l.current_version, 'deleted', l.deleted_at is not null,
    'event_id', l.event_id, 'event_name', e.name,
    'versions', coalesce((select jsonb_agg(jsonb_build_object('version', v.version, 'note', v.note,
                                   'at', extract(epoch from v.edited_at), 'entries', v.entries) order by v.version)
                            from public.card_list_versions v where v.list_id = l.id), '[]'::jsonb))
  from public.card_lists l left join public.events e on e.id = l.event_id where l.id = p_list_id;
$$;

-- ==================================================================== pick machinery
create or replace function t1_private.roto_apply_pick(d public.roto_drafts, p_participant uuid, p_slot integer,
                                                      p_how text, p_by uuid)
returns public.roto_drafts language plpgsql security definer set search_path = '' as $$
declare
  v_no integer := d.picks_made + 1;
  v_card uuid;
  v_finish text;
  v_total integer := d.players * d.picks_per_player;
begin
  select card_id, finish into v_card, v_finish from public.roto_pool where event_id = d.event_id and slot = p_slot;
  insert into public.roto_picks (event_id, pick_no, participant_id, slot, how, picked_by)
  values (d.event_id, v_no, p_participant, p_slot, p_how, p_by);
  delete from public.roto_queue where event_id = d.event_id and slot = p_slot;
  perform t1_private.roto_deck_change(d.event_id, p_participant, v_card, v_finish, 1);
  update public.roto_drafts
     set picks_made = v_no,
         finished_at = case when v_no >= v_total then now() end,
         turn_started_at = now(),
         turn_seconds = case when v_no < v_total
                             then t1_private.roto_clock_seconds(clock, t1_private.roto_round(players, v_no + 1)) end,
         clock_paused_at = case when clock_paused_at is not null and v_no < v_total then now() end,
         updated_at = now()
   where event_id = d.event_id
  returning * into d;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (d.event_id, p_by, 'roto.picked', 'participant', p_participant,
          jsonb_build_object('pick_no', v_no, 'slot', p_slot, 'card_id', v_card, 'how', p_how));
  return d;
end $$;

-- Auto-picks for whoever is on the clock while their switch is on and their list has a card left.
create or replace function t1_private.roto_advance(d public.roto_drafts)
returns public.roto_drafts language plpgsql security definer set search_path = '' as $$
declare v_part uuid; v_slot integer;
begin
  loop
    v_part := t1_private.roto_on_clock(d);
    exit when v_part is null;
    exit when not coalesce((select s.auto_pick from public.roto_settings s where s.participant_id = v_part), true);
    select q.slot into v_slot from public.roto_queue q
     where q.participant_id = v_part
       and not exists (select 1 from public.roto_picks k where k.event_id = d.event_id and k.slot = q.slot)
     order by q.position limit 1;
    exit when v_slot is null;
    d := t1_private.roto_apply_pick(d, v_part, v_slot, 'auto', null);
  end loop;
  return d;
end $$;

-- Past the deadline: take the first available card on the player's list (whatever their switch says), then carry on.
-- With nothing listed the turn just stays overdue.
create or replace function t1_private.roto_expire_draft(d public.roto_drafts)
returns public.roto_drafts language plpgsql security definer set search_path = '' as $$
declare v_part uuid; v_slot integer; v_deadline timestamptz := t1_private.roto_deadline(d);
begin
  if v_deadline is null or v_deadline > now() then return d; end if;
  v_part := t1_private.roto_on_clock(d);
  select q.slot into v_slot from public.roto_queue q
   where q.participant_id = v_part
     and not exists (select 1 from public.roto_picks k where k.event_id = d.event_id and k.slot = q.slot)
   order by q.position limit 1;
  if v_slot is null then return d; end if;
  d := t1_private.roto_apply_pick(d, v_part, v_slot, 'timeout', null);
  return t1_private.roto_advance(d);
end $$;

-- The caller's seat in the event (null if none); raises unless they play in it or organize it.
create or replace function t1_private.roto_viewer(p_event_id uuid)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare v_part uuid;
begin
  if coalesce(auth.role(), '') = 'service_role' then return null; end if;
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select id into v_part from public.participants where event_id = p_event_id and user_id = auth.uid() limit 1;
  if v_part is null and not public.is_event_organizer(p_event_id) then
    raise exception 'Only players and organizers of this event can see the draft' using errcode = '42501';
  end if;
  return v_part;
end $$;

create or replace function t1_private.roto_require_organizer(p_event_id uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can do that' using errcode = '42501';
  end if;
end $$;

-- ==================================================================== roto_state (the one read)
-- {event_id, phase: setup|drafting|done, draft{…}, on_clock{…}|null, seats[], picks[[pick_no, seat, slot, how, at]]
--  after p_after_pick, pool[[slot, card_id, finish]] (with p_pool; default when p_after_pick = 0), me{…}|null}
create or replace function public.roto_state(p_event_id uuid, p_after_pick integer default 0, p_pool boolean default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_me uuid := t1_private.roto_viewer(p_event_id);
  e public.events;
  d public.roto_drafts;
  v_seats jsonb;
  v_on uuid;
  v_deadline timestamptz;
begin
  select * into e from public.events where id = p_event_id;
  if e.id is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if e.format_name is distinct from 'roto' then raise exception 'That event isn''t a roto' using errcode = '22023'; end if;
  select * into d from public.roto_drafts where event_id = p_event_id;
  if d.started_at is not null then
    select jsonb_agg(jsonb_build_object('seat', o.n, 'participant_id', p.id, 'display_name', p.display_name,
                                        'account', p.user_id is not null, 'me', p.id = v_me) order by o.n)
      into v_seats from unnest(d.seat_order) with ordinality o(id, n) join public.participants p on p.id = o.id;
  else
    select jsonb_agg(jsonb_build_object('seat', p.seat, 'participant_id', p.id, 'display_name', p.display_name,
                                        'account', p.user_id is not null, 'me', p.id = v_me)
                     order by p.seat nulls last, p.display_name)
      into v_seats from public.participants p where p.event_id = p_event_id and p.status = 'active';
  end if;
  v_on := t1_private.roto_on_clock(d);
  v_deadline := t1_private.roto_deadline(d);
  return jsonb_build_object(
    'event_id', p_event_id,
    'phase', case when d.finished_at is not null then 'done' when d.started_at is not null then 'drafting' else 'setup' end,
    'draft', jsonb_build_object(
      'picks_per_player', coalesce(d.picks_per_player, 45), 'pick_order', coalesce(d.pick_order, 'snake'),
      'players', case when d.started_at is not null then d.players else coalesce(jsonb_array_length(v_seats), 0) end,
      'pool_count', coalesce(d.pool_count, 0), 'picks_made', coalesce(d.picks_made, 0),
      'total_picks', case when d.started_at is not null then d.players * d.picks_per_player end,
      'source_list_id', d.source_list_id, 'clock', d.clock, 'clock_paused', d.clock_paused_at is not null,
      'started_at', extract(epoch from d.started_at)::bigint, 'finished_at', extract(epoch from d.finished_at)::bigint),
    'on_clock', case when v_on is not null then jsonb_build_object(
      'participant_id', v_on, 'seat', array_position(d.seat_order, v_on), 'pick_no', d.picks_made + 1,
      'round', t1_private.roto_round(d.players, d.picks_made + 1),
      'turn_started_at', extract(epoch from d.turn_started_at)::bigint,
      'turn_seconds', d.turn_seconds,
      'remaining_seconds', case when d.clock_paused_at is not null and d.turn_seconds is not null
                                then greatest(0, d.turn_seconds - extract(epoch from d.clock_paused_at - d.turn_started_at))::int end,
      'deadline', extract(epoch from v_deadline)::bigint,
      'overdue', coalesce(v_deadline < now(), false)) end,
    'seats', coalesce(v_seats, '[]'::jsonb),
    'picks', coalesce((select jsonb_agg(jsonb_build_array(k.pick_no, array_position(d.seat_order, k.participant_id),
                                                          k.slot, k.how, extract(epoch from k.picked_at)::bigint)
                                        order by k.pick_no)
                         from public.roto_picks k where k.event_id = p_event_id and k.pick_no > coalesce(p_after_pick, 0)),
                      '[]'::jsonb),
    'pool', case when coalesce(p_pool, coalesce(p_after_pick, 0) = 0) then
              coalesce((select jsonb_agg(jsonb_build_array(rp.slot, rp.card_id, rp.finish) order by rp.slot)
                          from public.roto_pool rp where rp.event_id = p_event_id), '[]'::jsonb) end,
    'me', case when v_me is not null then jsonb_build_object(
      'participant_id', v_me, 'seat', array_position(d.seat_order, v_me),
      'queue', coalesce((select jsonb_agg(q.slot order by q.position) from public.roto_queue q
                          where q.participant_id = v_me), '[]'::jsonb),
      'auto_pick', coalesce((select s.auto_pick from public.roto_settings s where s.participant_id = v_me), true),
      'deck_list_id', (select l.id from public.card_lists l
                        where l.event_id = p_event_id and l.user_id = auth.uid() and l.deleted_at is null)) end);
end $$;

-- ==================================================================== organizer RPCs
create or replace function public.roto_set_cube(p_event_id uuid, p_list_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  l public.card_lists;
  v_pool integer;
  v_players integer;
begin
  perform t1_private.roto_require_organizer(p_event_id);
  select * into e from public.events where id = p_event_id for update;
  if e.format_name is distinct from 'roto' then raise exception 'That event isn''t a roto' using errcode = '22023'; end if;
  if exists (select 1 from public.roto_drafts where event_id = p_event_id and started_at is not null) then
    raise exception 'The cube locks once the draft starts' using errcode = '55000';
  end if;
  select * into l from public.card_lists
   where id = p_list_id and user_id = auth.uid() and kind = 'cube' and deleted_at is null;
  if l.id is null then raise exception 'Pick one of your cubes' using errcode = 'P0002'; end if;
  select coalesce(sum(qty), 0) into v_pool from public.card_list_entries where list_id = l.id and board = 'main';
  if v_pool = 0 then raise exception 'That cube has no cards in Main' using errcode = '22023'; end if;
  insert into public.roto_drafts (event_id, source_list_id, source_version, pool_count)
  values (p_event_id, l.id, l.current_version, v_pool)
  on conflict (event_id) do update set source_list_id = excluded.source_list_id,
    source_version = excluded.source_version, pool_count = excluded.pool_count, updated_at = now();
  update public.events set cube_name = left(l.name, 80), updated_at = now() where id = p_event_id;
  select count(*) into v_players from public.participants where event_id = p_event_id and status = 'active';
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, auth.uid(), 'roto.cube_set', 'event', p_event_id,
          jsonb_build_object('list_id', l.id, 'version', l.current_version, 'pool', v_pool));
  return jsonb_build_object('event_id', p_event_id, 'source_list_id', l.id, 'cube_name', left(l.name, 80),
                            'pool_count', v_pool, 'players', v_players,
                            'max_picks_per_player', least(100, v_pool / greatest(v_players, 1)));
end $$;

create or replace function public.roto_start(p_event_id uuid, p_picks_per_player integer default 45,
                                             p_order text default 'snake')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  d public.roto_drafts;
  l public.card_lists;
  v_order uuid[];
  v_n integer;
  v_pool integer;
  v_id uuid;
begin
  perform t1_private.roto_require_organizer(p_event_id);
  select * into e from public.events where id = p_event_id for update;
  if e.format_name is distinct from 'roto' then raise exception 'That event isn''t a roto' using errcode = '22023'; end if;
  if e.status not in ('setup', 'seated') or exists (select 1 from public.rounds r where r.event_id = p_event_id) then
    raise exception 'That event can''t start a draft now' using errcode = '55000';
  end if;
  insert into public.roto_drafts (event_id) values (p_event_id) on conflict do nothing;
  select * into d from public.roto_drafts where event_id = p_event_id for update;
  if d.started_at is not null then raise exception 'The draft has already started' using errcode = '55000'; end if;
  if coalesce(p_order, '') not in ('snake', 'fixed') then raise exception 'Pick snake or fixed order' using errcode = '22023'; end if;
  if coalesce(p_picks_per_player, 0) not between 1 and 100 then
    raise exception 'Picks per player must be 1 to 100' using errcode = '22023';
  end if;
  select * into l from public.card_lists where id = d.source_list_id and deleted_at is null;
  if l.id is null then raise exception 'Pick a cube first' using errcode = '55000'; end if;

  -- Seat everyone (one pod, random order) unless the organizer already has a clean seating.
  if exists (select 1 from public.participants where event_id = p_event_id and status = 'active' and seat is null)
     or (select count(*) <> count(distinct seat) from public.participants where event_id = p_event_id and status = 'active') then
    perform public.seat_event(p_event_id);
  end if;
  select array_agg(id order by seat) into v_order
    from public.participants where event_id = p_event_id and status = 'active';
  v_n := coalesce(cardinality(v_order), 0);
  if v_n < 2 then raise exception 'A roto needs at least 2 players' using errcode = '22023'; end if;

  select coalesce(sum(qty), 0) into v_pool from public.card_list_entries where list_id = l.id and board = 'main';
  if v_pool < v_n * p_picks_per_player then
    raise exception 'The cube has % cards: enough for % picks each', v_pool, v_pool / v_n using errcode = '22023';
  end if;

  insert into public.roto_pool (event_id, slot, card_id, oracle_id, finish)
  select p_event_id, row_number() over (order by o.name, x.card_id, x.finish, g), x.card_id, c.oracle_id, x.finish
    from public.card_list_entries x
    join public.cards c on c.id = x.card_id
    join public.card_oracles o on o.oracle_id = c.oracle_id
    cross join lateral generate_series(1, x.qty) g
   where x.list_id = l.id and x.board = 'main';

  update public.roto_drafts
     set picks_per_player = p_picks_per_player, pick_order = p_order, seat_order = v_order, players = v_n,
         pool_count = v_pool, source_version = l.current_version, picks_made = 0, started_at = now(),
         finished_at = null, turn_started_at = now(), turn_seconds = t1_private.roto_clock_seconds(clock, 1),
         clock_paused_at = case when clock_paused_at is not null then now() end, updated_at = now()
   where event_id = p_event_id
  returning * into d;
  update public.events set status = 'seated', updated_at = now() where id = p_event_id and status = 'setup';

  foreach v_id in array v_order loop perform t1_private.roto_deck_create(v_id); end loop;

  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, auth.uid(), 'roto.started', 'event', p_event_id,
          jsonb_build_object('players', v_n, 'picks_per_player', p_picks_per_player, 'order', p_order,
                             'pool', v_pool, 'list_id', l.id, 'version', l.current_version, 'clock', d.clock));
  perform t1_private.roto_broadcast(p_event_id, 'started', 0);
  return public.roto_state(p_event_id, 0, true);
end $$;

create or replace function public.roto_set_clock(p_event_id uuid, p_clock jsonb default null, p_paused boolean default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  d public.roto_drafts;
  v_clock jsonb;
  v_before jsonb;
begin
  perform t1_private.roto_require_organizer(p_event_id);
  if not exists (select 1 from public.events where id = p_event_id and format_name = 'roto') then
    raise exception 'That event isn''t a roto' using errcode = '22023';
  end if;
  insert into public.roto_drafts (event_id) values (p_event_id) on conflict do nothing;
  select * into d from public.roto_drafts where event_id = p_event_id for update;
  if d.finished_at is not null then raise exception 'The draft is over' using errcode = '55000'; end if;
  v_before := jsonb_build_object('clock', d.clock, 'paused', d.clock_paused_at is not null);

  if p_clock is not null then
    v_clock := t1_private.roto_clock_clean(p_clock);
    update public.roto_drafts
       set clock = v_clock,
           -- The current turn keeps its time; a turn that had none starts timing now.
           turn_seconds = case when v_clock is null or started_at is null then null
                               when turn_seconds is null then
                                 t1_private.roto_clock_seconds(v_clock, t1_private.roto_round(players, picks_made + 1))
                               else turn_seconds end,
           turn_started_at = case when v_clock is not null and started_at is not null and turn_seconds is null
                                  then now() else turn_started_at end,
           clock_paused_at = case when v_clock is null then null else clock_paused_at end,
           updated_at = now()
     where event_id = p_event_id
    returning * into d;
  end if;
  if p_paused is true and d.clock_paused_at is null and d.clock is not null then
    update public.roto_drafts set clock_paused_at = now(), updated_at = now() where event_id = p_event_id returning * into d;
  elsif p_paused is false and d.clock_paused_at is not null then
    update public.roto_drafts
       set turn_started_at = turn_started_at + (now() - clock_paused_at), clock_paused_at = null, updated_at = now()
     where event_id = p_event_id returning * into d;
  end if;

  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
  values (p_event_id, auth.uid(), 'roto.clock_set', 'event', p_event_id, v_before,
          jsonb_build_object('clock', d.clock, 'paused', d.clock_paused_at is not null));
  perform t1_private.roto_broadcast(p_event_id, 'clock', d.picks_made);
  return public.roto_state(p_event_id, d.picks_made, false);
end $$;

create or replace function public.roto_undo(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  d public.roto_drafts;
  v_from integer;
  r record;
  v_n integer := 0;
begin
  perform t1_private.roto_require_organizer(p_event_id);
  select * into d from public.roto_drafts where event_id = p_event_id for update;
  if d.started_at is null or d.picks_made = 0 then raise exception 'No picks to undo' using errcode = '55000'; end if;
  if exists (select 1 from public.rounds where event_id = p_event_id) then
    raise exception 'Picks are final once round 1 is paired' using errcode = '55000';
  end if;
  -- The last pick someone made (player or organizer) and every automatic pick after it.
  select max(pick_no) into v_from from public.roto_picks where event_id = p_event_id and how in ('player', 'organizer');
  v_from := coalesce(v_from, d.picks_made);
  for r in select k.participant_id, rp.card_id, rp.finish from public.roto_picks k
             join public.roto_pool rp on rp.event_id = k.event_id and rp.slot = k.slot
            where k.event_id = p_event_id and k.pick_no >= v_from order by k.pick_no desc loop
    perform t1_private.roto_deck_change(p_event_id, r.participant_id, r.card_id, r.finish, -1);
    v_n := v_n + 1;
  end loop;
  delete from public.roto_picks where event_id = p_event_id and pick_no >= v_from;
  -- No auto-picks run here, or the undone pick would be taken straight back.
  update public.roto_drafts
     set picks_made = v_from - 1, finished_at = null, turn_started_at = now(),
         turn_seconds = t1_private.roto_clock_seconds(clock, t1_private.roto_round(players, v_from)),
         clock_paused_at = case when clock_paused_at is not null then now() end, updated_at = now()
   where event_id = p_event_id
  returning * into d;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, auth.uid(), 'roto.undone', 'event', p_event_id,
          jsonb_build_object('from_pick', v_from, 'picks_removed', v_n));
  perform t1_private.roto_broadcast(p_event_id, 'undo', d.picks_made);
  return public.roto_state(p_event_id, d.picks_made, false);
end $$;

-- ==================================================================== player RPCs
-- {ok: true, state} or, when p_pick_no is stale, {ok: false, conflict: true, state} (state = picks after the caller's).
create or replace function public.roto_pick(p_event_id uuid, p_slot integer, p_pick_no integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  d public.roto_drafts;
  v_part uuid;
  v_how text := 'player';
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into d from public.roto_drafts where event_id = p_event_id for update;
  if d.started_at is null then raise exception 'The draft hasn''t started' using errcode = '55000'; end if;
  if d.finished_at is not null then raise exception 'The draft is over' using errcode = '55000'; end if;
  if p_pick_no is distinct from d.picks_made + 1 then
    return jsonb_build_object('ok', false, 'conflict', true,
      'state', public.roto_state(p_event_id, greatest(least(coalesce(p_pick_no, 1), d.picks_made + 1) - 1, 0), false));
  end if;
  v_part := t1_private.roto_on_clock(d);
  if not exists (select 1 from public.participants where id = v_part and user_id = auth.uid()) then
    if not public.is_event_organizer(p_event_id) then
      raise exception 'It isn''t your pick' using errcode = '42501';
    end if;
    v_how := 'organizer';
  end if;
  if not exists (select 1 from public.roto_pool where event_id = p_event_id and slot = p_slot) then
    raise exception 'That card isn''t in this cube' using errcode = '22023';
  end if;
  if exists (select 1 from public.roto_picks where event_id = p_event_id and slot = p_slot) then
    raise exception 'That card has been picked' using errcode = '23505';
  end if;
  d := t1_private.roto_apply_pick(d, v_part, p_slot, v_how, auth.uid());
  d := t1_private.roto_advance(d);
  perform t1_private.roto_broadcast(p_event_id, 'pick', d.picks_made);
  return jsonb_build_object('ok', true, 'state', public.roto_state(p_event_id, p_pick_no - 1, false));
end $$;

-- Replaces the caller's pick list (taken and unknown cards dropped, duplicates keep their first place) and,
-- optionally, the auto-pick switch. If they're on the clock this can pick at once (auto-pick, or an overdue turn).
create or replace function public.roto_queue_set(p_event_id uuid, p_slots integer[], p_auto_pick boolean default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_part uuid;
  d public.roto_drafts;
  v_before integer;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select id into v_part from public.participants where event_id = p_event_id and user_id = auth.uid() limit 1;
  if v_part is null then raise exception 'Only players in this draft have a pick list' using errcode = '42501'; end if;
  if coalesce(cardinality(p_slots), 0) > 1000 then raise exception 'A pick list holds up to 1000 cards' using errcode = '22023'; end if;
  select * into d from public.roto_drafts where event_id = p_event_id for update;
  if d.started_at is null then raise exception 'The draft hasn''t started' using errcode = '55000'; end if;
  if d.finished_at is not null then raise exception 'The draft is over' using errcode = '55000'; end if;
  v_before := d.picks_made;

  delete from public.roto_queue where participant_id = v_part;
  insert into public.roto_queue (participant_id, event_id, slot, position)
  select v_part, p_event_id, s.slot, row_number() over (order by min(s.ord))
    from unnest(coalesce(p_slots, '{}')) with ordinality s(slot, ord)
   where exists (select 1 from public.roto_pool rp where rp.event_id = p_event_id and rp.slot = s.slot)
     and not exists (select 1 from public.roto_picks k where k.event_id = p_event_id and k.slot = s.slot)
   group by s.slot;
  if p_auto_pick is not null then
    insert into public.roto_settings (participant_id, auto_pick) values (v_part, p_auto_pick)
    on conflict (participant_id) do update set auto_pick = excluded.auto_pick;
  end if;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, auth.uid(), 'roto.list_set', 'participant', v_part,
          jsonb_build_object('cards', (select count(*) from public.roto_queue where participant_id = v_part),
                             'auto_pick', p_auto_pick));

  d := t1_private.roto_advance(d);
  d := t1_private.roto_expire_draft(d);
  if d.picks_made <> v_before then perform t1_private.roto_broadcast(p_event_id, 'pick', d.picks_made); end if;
  return jsonb_build_object(
    'queue', coalesce((select jsonb_agg(q.slot order by q.position) from public.roto_queue q where q.participant_id = v_part), '[]'::jsonb),
    'auto_pick', coalesce((select s.auto_pick from public.roto_settings s where s.participant_id = v_part), true),
    'picks_made', d.picks_made);
end $$;

-- Anyone in the event (a client whose countdown reached zero). No-op before the deadline.
create or replace function public.roto_expire(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  d public.roto_drafts;
  v_before integer;
  v_deadline timestamptz;
begin
  perform t1_private.roto_viewer(p_event_id);
  select * into d from public.roto_drafts where event_id = p_event_id for update;
  if d.event_id is null then raise exception 'That event has no draft' using errcode = 'P0002'; end if;
  v_before := d.picks_made;
  d := t1_private.roto_expire_draft(d);
  if d.picks_made <> v_before then perform t1_private.roto_broadcast(p_event_id, 'timeout', d.picks_made); end if;
  v_deadline := t1_private.roto_deadline(d);
  return jsonb_build_object('picks_made', d.picks_made, 'overdue', coalesce(v_deadline < now(), false));
end $$;

-- pg_cron, every minute: overdue turns across all drafts. Rows another transaction holds are left for next time.
create or replace function t1_private.roto_expire_all()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  d public.roto_drafts;
  v_before integer;
  v_n integer := 0;
begin
  for d in select * from public.roto_drafts
            where started_at is not null and finished_at is null and turn_seconds is not null and clock_paused_at is null
              and turn_started_at + make_interval(secs => turn_seconds) <= now()
            for update skip locked loop
    v_before := d.picks_made;
    d := t1_private.roto_expire_draft(d);
    if d.picks_made <> v_before then
      perform t1_private.roto_broadcast(d.event_id, 'timeout', d.picks_made);
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;

do $$ begin
  if exists (select 1 from cron.job where jobname = 't1-roto-expire') then perform cron.unschedule('t1-roto-expire'); end if;
  perform cron.schedule('t1-roto-expire', '* * * * *', 'select t1_private.roto_expire_all()');
end $$;

-- ==================================================================== participants lock + claim
create or replace function t1_private.roto_participants_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_event uuid := case when tg_op = 'DELETE' then old.event_id else new.event_id end;
begin
  if coalesce(current_setting('t1.roto_bypass', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'DELETE' and not exists (select 1 from public.events where id = v_event) then return old; end if;
  if exists (select 1 from public.roto_drafts d where d.event_id = v_event and d.started_at is not null
              and (tg_op <> 'UPDATE' or new.seat is distinct from old.seat or new.pod_id is distinct from old.pod_id
                   or (d.finished_at is null and new.status is distinct from old.status))) then
    raise exception 'Players are locked once the draft starts' using errcode = '55000';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists participants_roto_guard on public.participants;
create trigger participants_roto_guard before insert or delete or update of seat, pod_id, status
  on public.participants for each row execute function t1_private.roto_participants_guard();

create or replace function t1_private.roto_participants_claimed()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.user_id is null and new.user_id is not null
     and exists (select 1 from public.roto_drafts d where d.event_id = new.event_id and d.started_at is not null) then
    perform t1_private.roto_deck_create(new.id);
  end if;
  return null;
end $$;
drop trigger if exists participants_roto_claimed on public.participants;
create trigger participants_roto_claimed after update of user_id on public.participants
  for each row execute function t1_private.roto_participants_claimed();

-- Deleting an event deck in Library just unlinks it (the picks stay in the event); list_delete is unchanged.

-- ==================================================================== seat_event: roto is one pod, locked at start
create or replace function public.seat_event(p_event_id uuid)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_event public.events%rowtype;
  v_ids uuid[];
  v_n int;
  v_pod_count int;
  v_base int;
  v_extra int;
  v_pod_ids uuid[];
  v_team_ids uuid[];
  v_loose int;
  v_id uuid;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can do that' using errcode = '42501';
  end if;

  -- Row lock: two quick re-seats run one after the other, never interleaved.
  select * into v_event from public.events where id = p_event_id for update;
  if not found then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if coalesce(v_event.format_name, '') not in ('draft', 'team_draft', 'roto') then
    raise exception 'Seating is for draft events' using errcode = '55000';
  end if;
  if exists (select 1 from public.rounds r where r.event_id = p_event_id) then
    raise exception 'Seats are locked once round 1 is paired' using errcode = '55000';
  end if;
  if exists (select 1 from public.roto_drafts d where d.event_id = p_event_id and d.started_at is not null) then
    raise exception 'Seats are locked once the draft starts' using errcode = '55000';
  end if;
  if v_event.status not in ('setup', 'seated') then
    raise exception 'That event can''t be seated now' using errcode = '55000';
  end if;

  if v_event.format_name = 'team_draft' then
    select array_agg(t.id order by t.display_order) into v_team_ids
      from public.event_teams t where t.event_id = p_event_id and t.active;
    if coalesce(cardinality(v_team_ids), 0) <> 2 then
      raise exception 'A team draft needs exactly two teams before seating' using errcode = '55000';
    end if;
    select count(*) into v_loose from public.participants p
     where p.event_id = p_event_id and p.status = 'active'
       and (p.team_id is null or p.team_id <> all (v_team_ids));
    if v_loose > 0 then
      raise exception '% player%', v_loose, case when v_loose = 1 then ' isn''t on a team yet' else 's aren''t on a team yet' end
        using errcode = '55000';
    end if;
    -- A1 B1 A2 B2 …: rank within each team by slot (then name), interleave by rank, team A first.
    select array_agg(x.id order by x.rn, x.team_order) into v_ids from (
      select p.id,
             row_number() over (partition by p.team_id order by p.team_slot nulls last, p.display_name) as rn,
             array_position(v_team_ids, p.team_id) as team_order
        from public.participants p
       where p.event_id = p_event_id and p.status = 'active'
    ) x;
    v_n := coalesce(cardinality(v_ids), 0);
    v_pod_count := 1;
  else
    select array_agg(p.id order by random()) into v_ids
      from public.participants p where p.event_id = p_event_id and p.status = 'active';
    v_n := coalesce(cardinality(v_ids), 0);
    -- A roto is one pod however many play.
    v_pod_count := case when v_event.format_name = 'roto' then 1 else greatest(1, ceil(v_n / 8.0)::int) end;
  end if;

  if v_n = 0 then
    raise exception 'Add players before seating' using errcode = '22023';
  end if;
  v_base := v_n / v_pod_count;
  v_extra := v_n % v_pod_count;

  -- Enough pods (existing ones keep their ids and names).
  select array_agg(d.id order by d.display_order) into v_pod_ids from public.pods d where d.event_id = p_event_id;
  for i in coalesce(cardinality(v_pod_ids), 0) + 1 .. v_pod_count loop
    insert into public.pods (event_id, name, display_order) values (p_event_id, 'Pod ' || i, i - 1)
    returning id into v_id;
    v_pod_ids := array_append(v_pod_ids, v_id);
  end loop;

  -- Position k (0-based) in the shuffled order → pod and seat. The first v_extra pods hold v_base + 1.
  -- Everyone not in the plan (dropped players) loses their seat, as before.
  update public.participants p
     set seat = s.seat, pod_id = coalesce(s.pod_id, p.pod_id)
    from (
      select pp.id, plan.seat, plan.pod_id
        from public.participants pp
        left join (
          select u.id,
                 case when u.k < v_extra * (v_base + 1) then u.k % (v_base + 1)
                      else (u.k - v_extra * (v_base + 1)) % v_base end + 1 as seat,
                 v_pod_ids[1 + case when u.k < v_extra * (v_base + 1) then u.k / (v_base + 1)
                                    else v_extra + (u.k - v_extra * (v_base + 1)) / v_base end] as pod_id
            from (select o.id, (o.ord - 1)::int as k from unnest(v_ids) with ordinality as o(id, ord)) u
        ) plan on plan.id = pp.id
       where pp.event_id = p_event_id
    ) s
   where s.id = p.id;

  if v_event.status = 'setup' then
    update public.events set status = 'seated', updated_at = now() where id = p_event_id;
  end if;

  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, auth.uid(), 'event.seated', 'event', p_event_id,
          jsonb_build_object('players', v_n, 'pods', v_pod_count));

  return json_build_object('event_id', p_event_id, 'pods', coalesce((
    select json_agg(json_build_object('pod_id', d.id, 'name', d.name, 'seats', d.seats) order by d.display_order)
      from (
        select pd.id, pd.name, pd.display_order,
               (select json_agg(json_build_object('seat', p.seat, 'participant_id', p.id,
                                                  'display_name', p.display_name, 'team', t.name) order by p.seat)
                  from public.participants p
                  left join public.event_teams t on t.id = p.team_id
                 where p.pod_id = pd.id and p.status = 'active' and p.seat is not null) as seats
          from public.pods pd where pd.event_id = p_event_id
      ) d
     where d.seats is not null), '[]'::json));
end $$;


-- ==================================================================== create / update event: roto + pairing
drop function if exists public.create_event_v2(text, text, integer, integer, text, text, text, text, integer, text, text[], boolean, boolean, date);
create or replace function public.create_event_v2(p_name text default null, p_format_name text default null,
  p_rounds integer default null, p_round_seconds integer default 3000, p_set_code text default null,
  p_set_name text default null, p_cube_name text default null, p_cube_url text default null,
  p_team_size integer default null, p_format_other text default null, p_player_names text[] default '{}',
  p_include_me boolean default true, p_show_clock boolean default true, p_local_date date default null,
  p_pairing text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_team boolean := p_format_name in ('team_draft', 'team_sealed');
  v_limited boolean := p_format_name in ('draft', 'team_draft', 'sealed', 'team_sealed', 'roto');
  v_roto boolean := p_format_name = 'roto';
  v_set_name text;
  v_res json;
  v_id uuid;
  v_pod uuid;
  v_me text;
begin
  if v_uid is null then raise exception 'Sign in required to create an event' using errcode = '28000'; end if;
  if p_format_name is null or p_format_name not in ('standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper',
      'premodern', 'canadian_highlander', 'other_constructed', 'draft', 'team_draft', 'sealed', 'team_sealed', 'roto') then
    raise exception 'Pick a format' using errcode = '22023';
  end if;
  if v_team and coalesce(p_team_size, 0) not in (3, 4) then
    raise exception 'Teams have 3 or 4 players' using errcode = '22023';
  end if;
  if not v_limited and (p_set_code is not null or p_cube_name is not null) then
    raise exception 'Sets and cubes are for limited events' using errcode = '22023';
  end if;
  if p_set_code is not null and p_cube_name is not null then
    raise exception 'Pick a set or a cube, not both' using errcode = '22023';
  end if;
  if v_roto and nullif(trim(p_cube_name), '') is null then
    raise exception 'A roto is drafted from a cube' using errcode = '22023';
  end if;
  if p_pairing is not null and p_pairing not in ('swiss', 'round_robin') then
    raise exception 'Pick Swiss or round robin' using errcode = '22023';
  end if;
  if p_pairing = 'round_robin' and not v_roto then
    raise exception 'Round robin is for roto events for now' using errcode = '22023';
  end if;
  if p_set_code is not null then
    select s.name into v_set_name from public.mtg_sets s where s.code = lower(p_set_code);
    v_set_name := coalesce(v_set_name, nullif(trim(p_set_name), ''), upper(p_set_code));
  elsif v_limited and p_cube_name is null then
    v_set_name := left(nullif(trim(p_set_name), ''), 80);
  end if;

  v_res := public.create_event(
    'New event',
    case when not v_limited then 'constructed' when p_format_name in ('sealed', 'team_sealed') then 'sealed'
         when p_cube_name is not null then 'cube' else 'draft' end,
    coalesce(p_rounds, 3), 3000, coalesce(p_player_names, '{}'));
  v_id := (v_res->>'event_id')::uuid;

  update public.events
     set format_name = p_format_name,
         format_other = case when p_format_name = 'other_constructed' then nullif(trim(p_format_other), '') end,
         set_code = lower(p_set_code), set_name = v_set_name,
         cube_name = nullif(trim(p_cube_name), ''), cube_url = nullif(trim(p_cube_url), ''),
         team_size = case when v_team then p_team_size end,
         show_clock = coalesce(p_show_clock, true),
         name_date = coalesce(p_local_date, (now() at time zone 'utc')::date),
         auto_name = true
   where id = v_id;
  if v_roto then
    update public.events set pairing = coalesce(p_pairing, 'round_robin') where id = v_id;
    insert into public.roto_drafts (event_id) values (v_id) on conflict do nothing;
  end if;

  if coalesce(p_include_me, true) then
    select coalesce(nullif(trim(pr.display_name), ''), nullif(trim(pr.handle), ''), 'Organizer') into v_me
      from public.profiles pr where pr.id = v_uid;
    select d.id into v_pod from public.pods d where d.event_id = v_id order by d.display_order limit 1;
    update public.participants set seat = seat + 1 where event_id = v_id and seat is not null;
    insert into public.participants (event_id, pod_id, user_id, display_name, seat)
    values (v_id, v_pod, v_uid, left(coalesce(v_me, 'Organizer'), 40), 1);
  end if;
  return v_res;
end $$;
revoke execute on function public.create_event_v2(text, text, integer, integer, text, text, text, text, integer, text, text[], boolean, boolean, date, text) from public, anon;
grant execute on function public.create_event_v2(text, text, integer, integer, text, text, text, text, integer, text, text[], boolean, boolean, date, text) to authenticated;

drop function if exists public.update_event_details(uuid, text, text, integer, integer, text, text, text, text, integer, text, boolean);
create or replace function public.update_event_details(p_event_id uuid, p_name text, p_format_name text,
  p_rounds integer, p_round_seconds integer default 3000, p_set_code text default null, p_set_name text default null,
  p_cube_name text default null, p_cube_url text default null, p_team_size integer default null,
  p_format_other text default null, p_show_clock boolean default null, p_pairing text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  v_team boolean := p_format_name in ('team_draft', 'team_sealed');
  v_limited boolean := p_format_name in ('draft', 'team_draft', 'sealed', 'team_sealed', 'roto');
  v_roto boolean := p_format_name = 'roto';
  v_set_name text;
  v_name text := nullif(trim(p_name), '');
  v_before jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into e from public.events where id = p_event_id for update;
  if e.id is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can change the event' using errcode = '42501';
  end if;
  if e.status not in ('setup', 'seated') or exists (select 1 from public.rounds r where r.event_id = p_event_id) then
    raise exception 'Details lock once round 1 is paired' using errcode = '55000';
  end if;
  if exists (select 1 from public.roto_drafts d where d.event_id = p_event_id and d.started_at is not null)
     and (not v_roto or nullif(trim(p_cube_name), '') is distinct from e.cube_name) then
    raise exception 'The format and cube lock once the draft starts' using errcode = '55000';
  end if;
  if not e.auto_name and (v_name is null or char_length(v_name) > 80) then
    raise exception 'Name the event (up to 80 characters)' using errcode = '22023';
  end if;
  if p_format_name is null or p_format_name not in ('standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper',
      'premodern', 'canadian_highlander', 'other_constructed', 'draft', 'team_draft', 'sealed', 'team_sealed', 'roto') then
    raise exception 'Pick a format' using errcode = '22023';
  end if;
  if v_team and coalesce(p_team_size, 0) not in (3, 4) then
    raise exception 'Teams have 3 or 4 players' using errcode = '22023';
  end if;
  if not v_limited and (p_set_code is not null or p_cube_name is not null) then
    raise exception 'Sets and cubes are for limited events' using errcode = '22023';
  end if;
  if p_set_code is not null and p_cube_name is not null then
    raise exception 'Pick a set or a cube, not both' using errcode = '22023';
  end if;
  if v_roto and nullif(trim(p_cube_name), '') is null then
    raise exception 'A roto is drafted from a cube' using errcode = '22023';
  end if;
  if p_pairing is not null and p_pairing not in ('swiss', 'round_robin') then
    raise exception 'Pick Swiss or round robin' using errcode = '22023';
  end if;
  if p_pairing = 'round_robin' and not v_roto then
    raise exception 'Round robin is for roto events for now' using errcode = '22023';
  end if;
  if coalesce(p_rounds, 0) not between 1 and 15 then
    raise exception 'Rounds must be 1 to 15' using errcode = '22023';
  end if;
  if p_set_code is not null then
    select s.name into v_set_name from public.mtg_sets s where s.code = lower(p_set_code);
    v_set_name := coalesce(v_set_name, nullif(trim(p_set_name), ''), upper(p_set_code));
  elsif v_limited and p_cube_name is null then
    v_set_name := left(nullif(trim(p_set_name), ''), 80);
  end if;

  v_before := jsonb_build_object('name', e.name, 'format_name', e.format_name, 'rounds', e.number_of_rounds,
    'show_clock', e.show_clock, 'set_code', e.set_code, 'cube_name', e.cube_name, 'team_size', e.team_size,
    'pairing', e.pairing);

  update public.events
     set name = case when e.auto_name then e.name else v_name end,
         format_name = p_format_name,
         format_other = case when p_format_name = 'other_constructed' then left(nullif(trim(p_format_other), ''), 40) end,
         set_code = lower(p_set_code),
         set_name = v_set_name,
         cube_name = case when v_limited then nullif(trim(p_cube_name), '') end,
         cube_url = case when v_limited and nullif(trim(p_cube_name), '') is not null then nullif(trim(p_cube_url), '') end,
         team_size = case when v_team then p_team_size end,
         number_of_rounds = p_rounds,
         round_length_seconds = 3000,
         show_clock = coalesce(p_show_clock, e.show_clock),
         pairing = case when v_roto then coalesce(p_pairing, case when e.format_name = 'roto' then e.pairing end, 'round_robin')
                        else 'swiss' end,
         updated_at = now()
   where id = p_event_id
  returning * into e;
  if v_roto then insert into public.roto_drafts (event_id) values (p_event_id) on conflict do nothing; end if;

  if not v_team then
    update public.participants set team_id = null, team_slot = null where event_id = p_event_id and team_id is not null;
    update public.event_teams set active = false where event_id = p_event_id and active;
  end if;

  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, reason, before, after)
  values (p_event_id, v_uid, 'event.details_updated', 'event', p_event_id, null, v_before,
          jsonb_build_object('name', e.name, 'format_name', e.format_name, 'rounds', e.number_of_rounds,
            'show_clock', e.show_clock, 'set_code', e.set_code, 'cube_name', e.cube_name, 'team_size', e.team_size,
            'pairing', e.pairing));

  return jsonb_build_object('event_id', e.id, 'name', e.name, 'format_name', e.format_name, 'format_label', e.format_label,
    'number_of_rounds', e.number_of_rounds, 'round_length_seconds', e.round_length_seconds, 'set_code', e.set_code,
    'set_name', e.set_name, 'cube_name', e.cube_name, 'cube_url', e.cube_url, 'team_size', e.team_size,
    'format_other', e.format_other, 'show_clock', e.show_clock, 'pairing', e.pairing);
end $$;
revoke execute on function public.update_event_details(uuid, text, text, integer, integer, text, text, text, text, integer, text, boolean, text) from public, anon;
grant execute on function public.update_event_details(uuid, text, text, integer, integer, text, text, text, text, integer, text, boolean, text) to authenticated;

-- ==================================================================== grants
revoke execute on function public.roto_state(uuid, integer, boolean) from public, anon;
revoke execute on function public.roto_set_cube(uuid, uuid) from public, anon;
revoke execute on function public.roto_start(uuid, integer, text) from public, anon;
revoke execute on function public.roto_set_clock(uuid, jsonb, boolean) from public, anon;
revoke execute on function public.roto_undo(uuid) from public, anon;
revoke execute on function public.roto_pick(uuid, integer, integer) from public, anon;
revoke execute on function public.roto_queue_set(uuid, integer[], boolean) from public, anon;
revoke execute on function public.roto_expire(uuid) from public, anon;
grant execute on function public.roto_state(uuid, integer, boolean) to authenticated, service_role;
grant execute on function public.roto_set_cube(uuid, uuid) to authenticated;
grant execute on function public.roto_start(uuid, integer, text) to authenticated;
grant execute on function public.roto_set_clock(uuid, jsonb, boolean) to authenticated;
grant execute on function public.roto_undo(uuid) to authenticated;
grant execute on function public.roto_pick(uuid, integer, integer) to authenticated;
grant execute on function public.roto_queue_set(uuid, integer[], boolean) to authenticated;
grant execute on function public.roto_expire(uuid) to authenticated;

-- ==================================================================== demo (demo_testers only, is_demo events)
-- 360 real cards: 50 of each colour, 45 multicolour, 35 colourless, 30 nonbasic lands, from the original printings.
create or replace function t1_private.demo_roto_pool(p_event uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  insert into public.roto_pool (event_id, slot, card_id, oracle_id, finish)
  select p_event, row_number() over (order by x.name), x.card_id, x.oracle_id, 'nonfoil'
    from (
      select o.oracle_id, o.source_card_id card_id, o.name,
             row_number() over (partition by b.bucket order by md5(o.name)) rn, b.bucket
        from public.card_oracles o
        join public.cards c on c.id = o.source_card_id
        cross join lateral (select case when o.type_line like '%Land%' then 'L'
                                        when coalesce(cardinality(o.colors), 0) = 0 then 'C'
                                        when cardinality(o.colors) > 1 then 'M' else o.colors[1] end bucket) b
       where o.legalities->>'vintage' in ('legal', 'restricted') and o.type_line not like 'Basic%'
         and o.layout in ('normal', 'split', 'transform', 'modal_dfc', 'adventure') and 'nonfoil' = any (c.finishes)
    ) x
   where (x.bucket in ('W', 'U', 'B', 'R', 'G') and x.rn <= 50) or (x.bucket = 'M' and x.rn <= 45)
      or (x.bucket = 'C' and x.rn <= 35) or (x.bucket = 'L' and x.rn <= 30);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Picks 1..p_picks with pseudo-random cards (stable per event); every fifth pick is an auto-pick.
create or replace function t1_private.demo_roto_picks(p_event uuid, p_picks integer, p_started timestamptz, p_step interval)
returns void language plpgsql security definer set search_path = '' as $$
declare d public.roto_drafts;
begin
  select * into d from public.roto_drafts where event_id = p_event;
  insert into public.roto_picks (event_id, pick_no, participant_id, slot, how, picked_at)
  select p_event, k.n, d.seat_order[t1_private.roto_seat_index(d.players, k.n::int, true)], s.slot,
         case when k.n % 5 = 0 then 'auto' else 'player' end, p_started + p_step * k.n
    from (select slot, row_number() over (order by md5(p_event::text || slot)) n from public.roto_pool where event_id = p_event) s
    join generate_series(1, p_picks) k(n) on k.n = s.n;
  update public.roto_drafts set picks_made = p_picks,
         finished_at = case when p_picks >= players * picks_per_player then p_started + p_step * p_picks end,
         turn_started_at = now() - interval '25 minutes',
         turn_seconds = case when p_picks < players * picks_per_player
                             then t1_private.roto_clock_seconds(clock, t1_private.roto_round(players, p_picks + 1)) end
   where event_id = p_event;
end $$;

create or replace function t1_private.demo_roto(p_owner uuid, p uuid[])
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_now timestamptz := now();
  v_ev uuid;
  v_me uuid;
  v_day timestamptz;
begin
  -- Live: 8 players, 45 picks each from 360, pick 125 on the clock, you (seat 1) pick in 3. Pick clock on.
  v_ev := t1_private.demo_event(p_owner, 'Vintage Roto', 'cube', 7, 50, p_owner, v_now - interval '5 days',
                                v_now - interval '4 days', array[p_owner, p[1], p[2], p[3], p[4], p[5], p[6], p[7]]);
  update public.events set format_name = 'roto', cube_name = 'Vintage Cube', pairing = 'round_robin', status = 'seated'
   where id = v_ev;
  insert into public.roto_drafts (event_id, picks_per_player, pick_order, players, seat_order, started_at, clock)
  select v_ev, 45, 'snake', 8, array_agg(id order by seat), v_now - interval '4 days',
         '[{"from_round": 1, "seconds": 14400}, {"from_round": 11, "seconds": 7200}, {"from_round": 31, "seconds": 1800}]'::jsonb
    from public.participants where event_id = v_ev;
  update public.roto_drafts set pool_count = t1_private.demo_roto_pool(v_ev) where event_id = v_ev;
  perform t1_private.demo_roto_picks(v_ev, 124, v_now - interval '4 days', interval '40 minutes');
  select id into v_me from public.participants where event_id = v_ev and user_id = p_owner;
  insert into public.roto_queue (participant_id, event_id, slot, position)
  select v_me, v_ev, s.slot, row_number() over (order by s.n)
    from (select slot, row_number() over (order by md5('list' || slot)) n from public.roto_pool rp
           where rp.event_id = v_ev and not exists (select 1 from public.roto_picks k where k.event_id = v_ev and k.slot = rp.slot)) s
   where s.n <= 6;
  perform t1_private.roto_deck_create(v_me);

  -- Done: same cube, drafted last week, round robin in round 3 of 7.
  v_day := v_now - interval '1 hour 40 minutes';
  v_ev := t1_private.demo_event(p_owner, 'Legacy Cube Roto', 'cube', 7, 50, null, v_now - interval '12 days',
                                v_day, array[p_owner, p[8], p[9], p[10], p[11], p[12], p[1], p[3]]);
  update public.events set format_name = 'roto', cube_name = 'Legacy Cube', pairing = 'round_robin' where id = v_ev;
  insert into public.roto_drafts (event_id, picks_per_player, pick_order, players, seat_order, started_at)
  select v_ev, 45, 'snake', 8, array_agg(id order by seat), v_now - interval '11 days'
    from public.participants where event_id = v_ev;
  update public.roto_drafts set pool_count = t1_private.demo_roto_pool(v_ev) where event_id = v_ev;
  perform t1_private.demo_roto_picks(v_ev, 360, v_now - interval '11 days', interval '20 minutes');
  select id into v_me from public.participants where event_id = v_ev and user_id = p_owner;
  perform t1_private.roto_deck_create(v_me);
  perform t1_private.demo_round(v_ev, p_owner, 1, false, '2-1', null, v_day, 0);
  perform t1_private.demo_round(v_ev, p_owner, 2, false, '2-0', null, v_day + interval '55 minutes', 0);
  perform t1_private.demo_round(v_ev, p_owner, 3, true, null, 2, v_now - interval '10 minutes', 2);
  update public.events set status = 'in_progress', current_round = 3, updated_at = v_now - interval '10 minutes' where id = v_ev;
end $$;

-- Wrap the existing seed/remove: the original bodies move to t1_private unchanged.
do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 't1_private' and p.proname = 'demo_seed_events') then
    alter function public.demo_seed() rename to demo_seed_events;
    alter function public.demo_seed_events() set schema t1_private;
    alter function public.demo_remove() rename to demo_remove_events;
    alter function public.demo_remove_events() set schema t1_private;
  end if;
end $$;
revoke execute on function t1_private.demo_seed_events() from public, anon, authenticated;
revoke execute on function t1_private.demo_remove_events() from public, anon, authenticated;

create or replace function public.demo_remove()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_res jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  -- Event decks of demo events leave every device on the next lists sync.
  delete from public.card_list_entries where list_id in
    (select l.id from public.card_lists l join public.events e on e.id = l.event_id
      where e.is_demo and e.demo_owner = v_uid and l.deleted_at is null);
  update public.card_lists l set deleted_at = now(), seq = nextval('public.card_list_seq'), updated_at = now()
    from public.events e
   where e.id = l.event_id and e.is_demo and e.demo_owner = v_uid and l.deleted_at is null;
  -- Demo events go with their (locked) roto seats.
  perform set_config('t1.roto_bypass', 'on', true);
  v_res := t1_private.demo_remove_events();
  perform set_config('t1.roto_bypass', '', true);
  return v_res;
end $$;

create or replace function public.demo_seed()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_res jsonb; v_people uuid[];
begin
  v_res := t1_private.demo_seed_events();
  select array_agg(id order by display_name) into v_people
    from public.profiles where is_demo and demo_owner = auth.uid();
  perform t1_private.demo_roto(auth.uid(), v_people);
  return v_res || jsonb_build_object('events', (v_res->>'events')::int + 2);
end $$;
revoke execute on function public.demo_remove() from public, anon;
revoke execute on function public.demo_seed() from public, anon;
grant execute on function public.demo_remove() to authenticated;
grant execute on function public.demo_seed() to authenticated;
