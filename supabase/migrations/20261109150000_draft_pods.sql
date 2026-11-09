-- Drafts with several pods (contract/draft-pods-2026-11-09.md). Additive: older builds keep working.
--   a_columns   events.pods (null = automatic, pods of up to 8) and events.pod_pairing ('pod' | 'cross')
--   b_rounds    automatic rounds follow the pods: inside pods, enough for the largest pod
--   c_seating   seat_event draws the organizer's number of pods; seat_fill seats newcomers only; the seating json
--   d_moves     seat_move (to another pod, a seat, or a new pod) and seat_swap, by hand before round 1
--   e_settings  set_event_pods
--   f_joins     joining a seated draft leaves you unseated (as add_guest and the waitlist already did)
--   g_grants

-- ==================================================================== a_columns
-- Events before this one were paired across pods after round 1, so they keep that; new drafts pair inside pods.
alter table public.events
  add column if not exists pods integer check (pods between 1 and 16),
  add column if not exists pod_pairing text not null default 'cross' check (pod_pairing in ('pod', 'cross'));
alter table public.events alter column pod_pairing set default 'pod';

-- ==================================================================== b_rounds
-- How many pods an organizer's pick makes (seating.ts podCount): null = pods of up to 8; never a pod under 2.
create or replace function t1_private.pod_count(p_players integer, p_pods integer)
returns integer language sql immutable set search_path = '' as $$
  select case when coalesce(p_players, 0) <= 0 then 0
              when p_pods is null then ceil(p_players / 8.0)::int
              else greatest(1, least(p_pods, p_players / 2)) end
$$;

-- Automatic Swiss rounds for an event (playoffs.ts swissRounds / draftRounds). A draft paired inside pods plays
-- enough rounds for its largest pod: as seated once the draw is made (status seated), else as the pick would seat
-- them (before the draw players hold placeholder seats in pod 1).
create or replace function t1_private.auto_round_count(p_event_id uuid, p_format text, p_pods integer, p_pod_pairing text,
  p_status text)
returns integer language plpgsql stable security definer set search_path = '' as $$
declare
  v_n integer;
  v_count integer;
  v_largest integer;
begin
  select count(*)::int into v_n from public.participants p where p.event_id = p_event_id and p.status = 'active';
  if coalesce(p_format, '') <> 'draft' or coalesce(p_pod_pairing, 'cross') <> 'pod' then
    return t1_private.swiss_rounds(v_n);
  end if;
  if p_status = 'seated' then
    select max(c)::int into v_largest from (
      select count(*) c from public.participants p
       where p.event_id = p_event_id and p.status = 'active' and p.seat is not null group by p.pod_id) x;
  end if;
  if v_largest is null then
    v_count := t1_private.pod_count(v_n, p_pods);
    v_largest := case when v_count = 0 then 0 else ceil(v_n::numeric / v_count)::int end;
  end if;
  return t1_private.swiss_rounds(v_largest);
end $$;

create or replace function t1_private.events_auto_rounds() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.auto_rounds and new.status in ('setup', 'seated')
     and not exists (select 1 from public.rounds r where r.event_id = new.id) then
    new.number_of_rounds := t1_private.auto_round_count(new.id, new.format_name, new.pods, new.pod_pairing, new.status);
  end if;
  return new;
end $$;
drop trigger if exists events_auto_rounds on public.events;
create trigger events_auto_rounds
  before insert or update of auto_rounds, number_of_rounds, status, format_name, pods, pod_pairing on public.events
  for each row execute function t1_private.events_auto_rounds();

create or replace function t1_private.participants_auto_rounds() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_event uuid := coalesce(new.event_id, old.event_id);
  e public.events;
  v_n integer;
begin
  select * into e from public.events where id = v_event;
  if e.id is null or not e.auto_rounds or e.status not in ('setup', 'seated')
     or exists (select 1 from public.rounds r where r.event_id = e.id) then
    return null;
  end if;
  v_n := t1_private.auto_round_count(e.id, e.format_name, e.pods, e.pod_pairing, e.status);
  if e.number_of_rounds <> v_n then
    update public.events set number_of_rounds = v_n where id = e.id;
  end if;
  return null;
end $$;
drop trigger if exists participants_auto_rounds on public.participants;
create trigger participants_auto_rounds
  after insert or delete or update of status, pod_id, seat on public.participants
  for each row execute function t1_private.participants_auto_rounds();

-- ==================================================================== c_seating
-- The seating as seat_event has always returned it: pods in order, active seated players by seat.
create or replace function t1_private.seating_json(p_event_id uuid)
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object('event_id', p_event_id, 'pods', coalesce((
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
     where d.seats is not null), '[]'::json))
$$;

-- Shared refusals for changing seats by hand or by draw.
create or replace function t1_private.assert_seating_open(e public.events)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if e.id is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if exists (select 1 from public.rounds r where r.event_id = e.id) then
    raise exception 'Seats are locked once round 1 is paired' using errcode = '55000';
  end if;
  if e.status not in ('setup', 'seated') then
    raise exception 'That event can''t be seated now' using errcode = '55000';
  end if;
end $$;

-- seat_event (from 20261016220000_roto) with the organizer's number of pods (events.pods) and a re-draw that
-- drops the pods it no longer needs. Calling it again re-draws every pod and seat.
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
    -- A roto is one pod however many play; a draft has the organizer's pods (or pods of up to 8).
    v_pod_count := case when v_event.format_name = 'roto' then 1
                        else greatest(1, t1_private.pod_count(v_n, v_event.pods)) end;
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

  -- Pods past the draw that nobody sits in any more go (a re-draw from 3 pods to 2 leaves no empty Pod 3).
  delete from public.pods d
   where d.event_id = p_event_id and d.id <> all (v_pod_ids[1:v_pod_count])
     and not exists (select 1 from public.participants p where p.pod_id = d.id);

  if v_event.status = 'setup' then
    update public.events set status = 'seated', updated_at = now() where id = p_event_id;
  end if;

  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, auth.uid(), 'event.seated', 'event', p_event_id,
          jsonb_build_object('players', v_n, 'pods', v_pod_count, 'pick', v_event.pods));

  return t1_private.seating_json(p_event_id);
end $$;

-- Seats active players who have no seat yet (they joined after the draw) without touching anyone else: each, in
-- random order, at the end of the pod with the fewest players (the first such pod). Before the draw it is the
-- full draw. Pairing round 1 calls it, so pods arranged by hand stay as they are.
create or replace function public.seat_fill(p_event_id uuid)
returns json language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_id uuid;
  v_pod uuid;
  v_seat int;
  v_n int := 0;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can do that' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id for update;
  perform t1_private.assert_seating_open(e);
  if coalesce(e.format_name, '') not in ('draft', 'team_draft') then
    raise exception 'Seating is for draft events' using errcode = '55000';
  end if;
  -- Not drawn yet (setup: seats are placeholders in pod 1) or nobody seated: the full draw.
  if e.format_name = 'team_draft' or e.status <> 'seated' or not exists (
       select 1 from public.participants p where p.event_id = p_event_id and p.status = 'active' and p.seat is not null) then
    return public.seat_event(p_event_id);
  end if;
  for v_id in select p.id from public.participants p
               where p.event_id = p_event_id and p.status = 'active' and p.seat is null order by random() loop
    select d.id into v_pod from public.pods d
      left join public.participants p on p.pod_id = d.id and p.status = 'active' and p.seat is not null
     where d.event_id = p_event_id
     group by d.id, d.display_order
     having count(p.id) > 0
     order by count(p.id), d.display_order limit 1;
    select coalesce(max(p.seat), 0) + 1 into v_seat from public.participants p
     where p.pod_id = v_pod and p.status = 'active' and p.seat is not null;
    update public.participants set pod_id = v_pod, seat = v_seat where id = v_id;
    v_n := v_n + 1;
  end loop;
  if v_n > 0 then
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
    values (p_event_id, auth.uid(), 'event.seats_filled', 'event', p_event_id, jsonb_build_object('players', v_n));
  end if;
  return t1_private.seating_json(p_event_id);
end $$;

-- ==================================================================== d_moves
-- One seated player to another pod (p_pod_id; null = a new pod), at a seat (p_seat; null = the end of that pod).
-- Seats close up behind them and open in front of them, so every pod stays 1..n. Moving within a pod reorders it.
create or replace function public.seat_move(p_participant_id uuid, p_pod_id uuid default null, p_seat integer default null)
returns json language plpgsql security definer set search_path = '' as $$
declare
  p public.participants;
  e public.events;
  v_target uuid := p_pod_id;
  v_size int;
  v_seat int;
  v_order int;
begin
  select * into p from public.participants where id = p_participant_id;
  if p.id is null then raise exception 'That player isn''t in the event' using errcode = 'P0002'; end if;
  if not public.is_event_organizer(p.event_id) then
    raise exception 'Only organizers can do that' using errcode = '42501';
  end if;
  select * into e from public.events where id = p.event_id for update;
  perform t1_private.assert_seating_open(e);
  if e.format_name is distinct from 'draft' then
    raise exception 'Players move between pods in drafts' using errcode = '55000';
  end if;
  select * into p from public.participants where id = p_participant_id;
  if e.status <> 'seated' or p.status <> 'active' or p.seat is null then
    raise exception 'Seat players before moving them' using errcode = '55000';
  end if;
  if v_target is not null and not exists (select 1 from public.pods d where d.id = v_target and d.event_id = e.id) then
    raise exception 'That pod isn''t in this event' using errcode = '22023';
  end if;
  if v_target is null then
    -- A new pod: the first empty one (not counting the mover), else the next "Pod N".
    select d.id into v_target from public.pods d
     where d.event_id = e.id
       and not exists (select 1 from public.participants x
                        where x.pod_id = d.id and x.status = 'active' and x.seat is not null and x.id <> p.id)
     order by d.display_order limit 1;
    if v_target is null then
      select coalesce(max(d.display_order), -1) + 1 into v_order from public.pods d where d.event_id = e.id;
      if v_order >= 16 then raise exception 'Up to 16 pods' using errcode = '22023'; end if;
      insert into public.pods (event_id, name, display_order) values (e.id, 'Pod ' || (v_order + 1), v_order)
      returning id into v_target;
    end if;
  end if;

  -- Out of the old place: everyone behind moves up one.
  update public.participants x set seat = -1 where x.id = p.id;
  update public.participants x set seat = x.seat - 1
   where x.pod_id = p.pod_id and x.status = 'active' and x.seat > p.seat;
  -- Into the new place: everyone from that seat on moves back one.
  select count(*)::int into v_size from public.participants x
   where x.pod_id = v_target and x.status = 'active' and x.seat > 0;
  v_seat := least(greatest(coalesce(p_seat, v_size + 1), 1), v_size + 1);
  update public.participants x set seat = x.seat + 1
   where x.pod_id = v_target and x.status = 'active' and x.seat >= v_seat;
  update public.participants x set pod_id = v_target, seat = v_seat where x.id = p.id;

  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
  values (e.id, auth.uid(), 'participant.seat_moved', 'participant', p.id,
          jsonb_build_object('pod_id', p.pod_id, 'seat', p.seat),
          jsonb_build_object('pod_id', v_target, 'seat', v_seat));
  return t1_private.seating_json(e.id);
end $$;

-- Two seated players trade places (pod and seat).
create or replace function public.seat_swap(p_a uuid, p_b uuid)
returns json language plpgsql security definer set search_path = '' as $$
declare
  a public.participants;
  b public.participants;
  e public.events;
begin
  select * into a from public.participants where id = p_a;
  select * into b from public.participants where id = p_b;
  if a.id is null or b.id is null or a.event_id <> b.event_id then
    raise exception 'Those players aren''t in one event' using errcode = 'P0002';
  end if;
  if not public.is_event_organizer(a.event_id) then
    raise exception 'Only organizers can do that' using errcode = '42501';
  end if;
  select * into e from public.events where id = a.event_id for update;
  perform t1_private.assert_seating_open(e);
  if e.format_name not in ('draft', 'team_draft') then
    raise exception 'Seats are for drafts' using errcode = '55000';
  end if;
  select * into a from public.participants where id = p_a;
  select * into b from public.participants where id = p_b;
  if e.status <> 'seated' or a.status <> 'active' or b.status <> 'active' or a.seat is null or b.seat is null then
    raise exception 'Seat players before moving them' using errcode = '55000';
  end if;
  if a.id = b.id then return t1_private.seating_json(e.id); end if;
  update public.participants set pod_id = b.pod_id, seat = b.seat where id = a.id;
  update public.participants set pod_id = a.pod_id, seat = a.seat where id = b.id;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
  values (e.id, auth.uid(), 'participant.seats_swapped', 'participant', a.id,
          jsonb_build_object('a', a.id, 'a_pod', a.pod_id, 'a_seat', a.seat, 'b', b.id, 'b_pod', b.pod_id, 'b_seat', b.seat),
          jsonb_build_object('a_pod', b.pod_id, 'a_seat', b.seat, 'b_pod', a.pod_id, 'b_seat', a.seat));
  return t1_private.seating_json(e.id);
end $$;

-- ==================================================================== e_settings
-- The organizer's pods (null = automatic) and how rounds 2+ pair. Before round 1 only. A new number of pods
-- re-draws the seats when they were already drawn, so what's shown always matches the pick.
create or replace function public.set_event_pods(p_event_id uuid, p_pods integer, p_pod_pairing text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_reseat boolean;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into e from public.events where id = p_event_id for update;
  if e.id is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can change the event' using errcode = '42501';
  end if;
  if e.format_name is distinct from 'draft' then
    raise exception 'Pods are for drafts' using errcode = '55000';
  end if;
  if e.status not in ('setup', 'seated') or exists (select 1 from public.rounds r where r.event_id = p_event_id) then
    raise exception 'Pods lock once round 1 is paired' using errcode = '55000';
  end if;
  if p_pods is not null and p_pods not between 1 and 16 then
    raise exception 'Pods are 1 to 16' using errcode = '22023';
  end if;
  if coalesce(p_pod_pairing, '') not in ('pod', 'cross') then
    raise exception 'Pair inside pods or across pods' using errcode = '22023';
  end if;
  v_reseat := e.status = 'seated' and e.pods is distinct from p_pods
    and exists (select 1 from public.participants p where p.event_id = e.id and p.status = 'active' and p.seat is not null);
  update public.events set pods = p_pods, pod_pairing = p_pod_pairing, updated_at = now() where id = e.id;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
  values (e.id, auth.uid(), 'event.pods_updated', 'event', e.id,
          jsonb_build_object('pods', e.pods, 'pod_pairing', e.pod_pairing),
          jsonb_build_object('pods', p_pods, 'pod_pairing', p_pod_pairing, 'reseated', v_reseat));
  if v_reseat then perform public.seat_event(e.id); end if;
  select * into e from public.events where id = p_event_id;
  return jsonb_build_object('event_id', e.id, 'pods', e.pods, 'pod_pairing', e.pod_pairing,
    'number_of_rounds', e.number_of_rounds, 'reseated', v_reseat,
    'seating', t1_private.seating_json(e.id)->'pods');
end $$;

-- ==================================================================== f_joins
-- _seat_account (from 20261027120000_scheduled_events) taking its place from next_slot: in a seated draft a
-- newcomer has no seat until seat_fill (or a re-draw) gives them one, instead of a 9th seat in pod 1.
create or replace function public._seat_account(p_event_id uuid, p_user_id uuid, p_via text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_pid uuid;
  v_name text;
  v_slot record;
begin
  select * into e from public.events where id = p_event_id;
  if e.id is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if e.status = 'cancelled' then raise exception 'That event was cancelled' using errcode = '22023'; end if;
  if e.status in ('completed', 'archived') then raise exception 'That event has already finished' using errcode = '22023'; end if;

  select id into v_pid from public.participants where event_id = e.id and user_id = p_user_id;
  if v_pid is not null then
    return jsonb_build_object('event_id', e.id, 'participant_id', v_pid, 'already_joined', true);
  end if;

  perform pg_advisory_xact_lock(hashtextextended(e.id::text, 0));
  if p_via in ('qr', 'nearby') and e.capacity is not null
     and t1_private.active_players(e.id) >= e.capacity then
    raise exception 'That event is full' using errcode = '53400';
  end if;
  select coalesce(nullif(handle, ''), display_name) into v_name from public.profiles where id = p_user_id;
  select * into v_slot from t1_private.next_slot(e.id, e.status);

  insert into public.participants (event_id, pod_id, user_id, display_name, seat)
  values (e.id, v_slot.pod_id, p_user_id, v_name, v_slot.seat) returning id into v_pid;
  delete from public.event_waitlist where event_id = e.id and user_id = p_user_id;
  update public.event_invites set status = 'accepted', responded_at = now()
   where event_id = e.id and user_id = p_user_id and status = 'pending';
  insert into public.audit_log (event_id, actor_user, actor_label, action, target_type, target_id, after)
  values (e.id, p_user_id, v_name, 'participant.joined', 'participant', v_pid, jsonb_build_object('via', p_via));
  return jsonb_build_object('event_id', e.id, 'participant_id', v_pid, 'seat', v_slot.seat, 'already_joined', false);
end $$;

-- join_event (from 20261027120000_scheduled_events), its place from next_slot too.
create or replace function public.join_event(p_code text, p_display_name text)
returns json language plpgsql security definer set search_path = 'public' as $$
declare
  v_event public.events;
  v_participant_id uuid;
  v_token text;
  v_slot record;
  v_refuse text;
  v_name text;
  v_pos int;
begin
  if length(trim(coalesce(p_display_name,''))) = 0 then
    raise exception 'A name is required';
  end if;
  perform t1_private.rate_hit('join.code', 20, 200, interval '10 minutes');
  if t1_private.rate_over('code.miss', 20, 60, interval '10 minutes') then
    raise exception 'Too many tries, wait a few minutes' using errcode = '53400';
  end if;
  select * into v_event from public.events where upper(short_code) = upper(trim(coalesce(p_code, '')));
  v_refuse := case
    when v_event.id is null then 'not_found'
    when v_event.status = 'cancelled' then 'cancelled'
    when v_event.status in ('completed','archived') then 'finished'
    when v_event.visibility = 'private'
         and t1_private.event_access(v_event.id) not in ('organizer', 'player', 'invited') then 'private'
    end;
  if v_refuse is not null then
    perform t1_private.rate_hit('code.miss', 1000000, 1000000, interval '10 minutes');
    return json_build_object('error', v_refuse, 'message', case v_refuse
      when 'cancelled' then 'That event was cancelled'
      when 'finished' then 'That event has already finished'
      when 'private' then 'Ask the organizer for an invite'
      else 'No event found with that code' end);
  end if;

  if auth.uid() is not null then
    select p.id, t.token into v_participant_id, v_token
      from public.participants p left join public.participant_tokens t on t.participant_id = p.id
     where p.event_id = v_event.id and p.user_id = auth.uid()
     order by p.created_at limit 1;
    if v_participant_id is not null then
      if v_token is null then
        insert into public.participant_tokens (participant_id) values (v_participant_id) returning token into v_token;
      end if;
      return json_build_object('event_id', v_event.id, 'short_code', v_event.short_code,
                               'participant_id', v_participant_id, 'token', v_token, 'already_joined', true);
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_event.id::text, 0));
  if v_event.capacity is not null and t1_private.active_players(v_event.id) >= v_event.capacity then
    if auth.uid() is null or not t1_private.sign_up_open(v_event) then
      return json_build_object('error', 'full', 'message', 'This event is full');
    end if;
    v_name := left(trim(p_display_name), 40);
    insert into public.event_waitlist (event_id, user_id, display_name) values (v_event.id, auth.uid(), v_name)
    on conflict do nothing;
    if found then
      insert into public.audit_log (event_id, actor_user, actor_label, action, target_type, target_id, after)
      values (v_event.id, auth.uid(), v_name, 'waitlist.joined', 'event', v_event.id, jsonb_build_object('via', 'code'));
    end if;
    v_pos := t1_private.waitlist_position(v_event.id, auth.uid());
    return json_build_object('error', 'full', 'waitlisted', true, 'position', v_pos, 'event_id', v_event.id,
      'message', 'This event is full. You''re number ' || v_pos || ' on the waitlist.');
  end if;

  select * into v_slot from t1_private.next_slot(v_event.id, v_event.status);

  insert into public.participants (event_id, pod_id, user_id, display_name, seat)
  values (v_event.id, v_slot.pod_id, auth.uid(), trim(p_display_name), v_slot.seat)
  returning id into v_participant_id;
  if auth.uid() is not null then
    delete from public.event_waitlist where event_id = v_event.id and user_id = auth.uid();
  end if;

  insert into public.participant_tokens (participant_id) values (v_participant_id)
  returning token into v_token;

  insert into public.audit_log (event_id, actor_label, action, target_type, target_id)
  values (v_event.id, trim(p_display_name), 'participant.joined', 'participant', v_participant_id);

  return json_build_object(
    'event_id', v_event.id,
    'short_code', v_event.short_code,
    'participant_id', v_participant_id,
    'token', v_token
  );
end $$;

-- ==================================================================== g_grants
revoke execute on function t1_private.pod_count(integer, integer) from public, anon, authenticated;
revoke execute on function t1_private.auto_round_count(uuid, text, integer, text, text) from public, anon, authenticated;
revoke execute on function t1_private.seating_json(uuid) from public, anon, authenticated;
revoke execute on function t1_private.assert_seating_open(public.events) from public, anon, authenticated;
revoke execute on function public.seat_event(uuid) from public, anon;
revoke execute on function public.seat_fill(uuid) from public, anon;
revoke execute on function public.seat_move(uuid, uuid, integer) from public, anon;
revoke execute on function public.seat_swap(uuid, uuid) from public, anon;
revoke execute on function public.set_event_pods(uuid, integer, text) from public, anon;
grant execute on function public.seat_event(uuid) to authenticated, service_role;
grant execute on function public.seat_fill(uuid) to authenticated, service_role;
grant execute on function public.seat_move(uuid, uuid, integer) to authenticated;
grant execute on function public.seat_swap(uuid, uuid) to authenticated;
grant execute on function public.set_event_pods(uuid, integer, text) to authenticated;
