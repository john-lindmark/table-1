-- Table 1 — organizer event screen in three phases (2026-10-12). Applied live as migration organizer_phases.
-- Setup: edit details until round 1. Live: one server call for the round clock (pause, resume, add time).

-- Edit an event's details while it's in setup (no rounds yet). Every field is sent each time (full state).
create or replace function public.update_event_details(
  p_event_id uuid,
  p_name text,
  p_format_name text,
  p_rounds integer,
  p_round_seconds integer,
  p_set_code text default null,
  p_set_name text default null,
  p_cube_name text default null,
  p_cube_url text default null,
  p_team_size integer default null,
  p_format_other text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  v_team boolean := p_format_name in ('team_draft', 'team_sealed');
  v_limited boolean := p_format_name in ('draft', 'team_draft', 'sealed', 'team_sealed');
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
  if v_name is null or char_length(v_name) > 80 then
    raise exception 'Name the event (up to 80 characters)' using errcode = '22023';
  end if;
  if p_format_name is null or p_format_name not in ('standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper',
      'premodern', 'canadian_highlander', 'other_constructed', 'draft', 'team_draft', 'sealed', 'team_sealed') then
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
  if coalesce(p_rounds, 0) not between 1 and 15 then
    raise exception 'Rounds must be 1 to 15' using errcode = '22023';
  end if;
  if coalesce(p_round_seconds, 0) not between 600 and 14400 then
    raise exception 'Rounds last 10 minutes to 4 hours' using errcode = '22023';
  end if;
  if p_set_code is not null then
    select s.name into v_set_name from public.mtg_sets s where s.code = lower(p_set_code);
    v_set_name := coalesce(v_set_name, nullif(trim(p_set_name), ''), upper(p_set_code));
  elsif v_limited and p_cube_name is null then
    v_set_name := left(nullif(trim(p_set_name), ''), 80);
  end if;

  v_before := jsonb_build_object('name', e.name, 'format_name', e.format_name, 'rounds', e.number_of_rounds,
    'round_seconds', e.round_length_seconds, 'set_code', e.set_code, 'cube_name', e.cube_name, 'team_size', e.team_size);

  -- format_name first so the format trigger re-derives the legacy column and team_size rules.
  update public.events
     set name = v_name,
         format_name = p_format_name,
         format_other = case when p_format_name = 'other_constructed' then left(nullif(trim(p_format_other), ''), 40) end,
         set_code = lower(p_set_code),
         set_name = v_set_name,
         cube_name = case when v_limited then nullif(trim(p_cube_name), '') end,
         cube_url = case when v_limited and nullif(trim(p_cube_name), '') is not null then nullif(trim(p_cube_url), '') end,
         team_size = case when v_team then p_team_size end,
         number_of_rounds = p_rounds,
         round_length_seconds = p_round_seconds,
         updated_at = now()
   where id = p_event_id
  returning * into e;

  -- No longer a team event: release everyone from their teams.
  if not v_team then
    update public.participants set team_id = null, team_slot = null where event_id = p_event_id and team_id is not null;
    update public.event_teams set active = false where event_id = p_event_id and active;
  end if;

  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, reason, before, after)
  values (p_event_id, v_uid, 'event.details_updated', 'event', p_event_id, null, v_before,
          jsonb_build_object('name', e.name, 'format_name', e.format_name, 'rounds', e.number_of_rounds,
            'round_seconds', e.round_length_seconds, 'set_code', e.set_code, 'cube_name', e.cube_name, 'team_size', e.team_size));

  return jsonb_build_object('event_id', e.id, 'name', e.name, 'format_name', e.format_name, 'format_label', e.format_label,
    'number_of_rounds', e.number_of_rounds, 'round_length_seconds', e.round_length_seconds, 'set_code', e.set_code,
    'set_name', e.set_name, 'cube_name', e.cube_name, 'cube_url', e.cube_url, 'team_size', e.team_size,
    'format_other', e.format_other);
end $$;
revoke execute on function public.update_event_details(uuid, text, text, integer, integer, text, text, text, text, integer, text) from public, anon;
grant execute on function public.update_event_details(uuid, text, text, integer, integer, text, text, text, text, integer, text) to authenticated;

-- The round clock, kept consistent in one place: running → ends_at = last_started_at + remaining_at_change;
-- paused → remaining_at_change holds what's left and ends_at is null.
-- p_action: 'pause' | 'resume' | 'add' (p_seconds, may be negative; never below 0 left).
create or replace function public.set_round_clock(p_round_id uuid, p_action text, p_seconds integer default 300)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r public.rounds;
  v_left integer;
  v_now timestamptz := now();
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into r from public.rounds where id = p_round_id for update;
  if r.id is null then raise exception 'Round not found' using errcode = 'P0002'; end if;
  if not public.is_event_organizer(r.event_id) then
    raise exception 'Only organizers can change the clock' using errcode = '42501';
  end if;
  if r.status <> 'active' then raise exception 'This round is over' using errcode = '55000'; end if;
  if p_action not in ('pause', 'resume', 'add') then raise exception 'Unknown clock action' using errcode = '22023'; end if;

  v_left := case
    when r.timer_status = 'running' and r.timer_last_started_at is not null then
      greatest(0, ceil(extract(epoch from (r.timer_last_started_at
        + make_interval(secs => coalesce(r.timer_remaining_at_change, r.timer_duration_seconds)) - v_now)))::integer)
    when r.timer_status = 'running' and r.timer_ends_at is not null then
      greatest(0, ceil(extract(epoch from (r.timer_ends_at - v_now)))::integer)
    else coalesce(r.timer_remaining_at_change, r.timer_duration_seconds) end;

  if p_action = 'add' then
    v_left := greatest(0, v_left + coalesce(p_seconds, 300));
    update public.rounds
       set timer_duration_seconds = greatest(60, timer_duration_seconds + coalesce(p_seconds, 300)),
           timer_remaining_at_change = v_left,
           timer_last_started_at = case when timer_status = 'running' then v_now end,
           timer_ends_at = case when timer_status = 'running' then v_now + make_interval(secs => v_left) end
     where id = r.id returning * into r;
  elsif p_action = 'pause' and r.timer_status = 'running' then
    update public.rounds
       set timer_status = 'paused', timer_remaining_at_change = v_left, timer_last_started_at = null, timer_ends_at = null
     where id = r.id returning * into r;
  elsif p_action = 'resume' and r.timer_status = 'paused' then
    update public.rounds
       set timer_status = 'running', timer_remaining_at_change = v_left, timer_last_started_at = v_now,
           timer_ends_at = v_now + make_interval(secs => v_left)
     where id = r.id returning * into r;
  end if;

  return jsonb_build_object('round_id', r.id, 'timer_status', r.timer_status, 'remaining_seconds', v_left,
    'duration_seconds', r.timer_duration_seconds, 'ends_at', r.timer_ends_at);
end $$;
revoke execute on function public.set_round_clock(uuid, text, integer) from public, anon;
grant execute on function public.set_round_clock(uuid, text, integer) to authenticated;
