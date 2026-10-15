-- Create event and Setup changes (2026-10-14, plan-create-event-2026-10-14.md):
--   automatic event names, "show clocks" switch (rounds always 50 min), organizer plays by default,
--   add a guest by name, remove a player before round 1 (closing the seat gap), recent cubes.

-- ==================================================================== a_columns
alter table public.events add column if not exists auto_name boolean not null default false;
alter table public.events add column if not exists name_date date;
alter table public.events add column if not exists show_clock boolean not null default true;

-- ==================================================================== b_auto_name
-- "<format label> · <Tue 14 Oct>", e.g. "Draft · Duskmourn · Fri 17 Oct". format_label is a generated column,
-- which a BEFORE trigger can't read yet, so the label is rebuilt here from the same fields.
create or replace function t1_private.event_label(p_format_name text, p_format_other text, p_set_name text, p_cube_name text)
returns text language sql immutable set search_path = '' as $$
  select case p_format_name
           when 'standard' then 'Standard' when 'pioneer' then 'Pioneer' when 'modern' then 'Modern'
           when 'legacy' then 'Legacy' when 'vintage' then 'Vintage' when 'pauper' then 'Pauper'
           when 'premodern' then 'Premodern' when 'canadian_highlander' then 'Canadian Highlander'
           when 'other_constructed' then coalesce(p_format_other, 'Constructed')
           when 'draft' then 'Draft' when 'team_draft' then 'Team draft'
           when 'sealed' then 'Sealed' when 'team_sealed' then 'Team sealed' else 'Event' end
      || case when p_cube_name is not null then ' · ' || p_cube_name
              when p_set_name is not null then ' · ' || p_set_name else '' end
$$;

create or replace function t1_private.events_auto_name() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.auto_name then
    new.name_date := coalesce(new.name_date, (coalesce(new.created_at, now()) at time zone 'utc')::date);
    new.name := left(t1_private.event_label(new.format_name, new.format_other, new.set_name, new.cube_name)
                     || ' · ' || to_char(new.name_date, 'Dy FMDD Mon'), 80);
  end if;
  return new;
end $$;

drop trigger if exists events_auto_name on public.events;
create trigger events_auto_name
  before insert or update of name, auto_name, name_date, format_name, format_other, set_name, cube_name
  on public.events for each row execute function t1_private.events_auto_name();

-- ==================================================================== c_create
-- Same wire names as before plus p_include_me, p_show_clock, p_local_date. p_name and p_round_seconds are kept
-- for older builds and ignored: the name is automatic and rounds are always 50 minutes.
drop function if exists public.create_event_v2(text, text, integer, integer, text, text, text, text, integer, text, text[]);
create or replace function public.create_event_v2(
  p_name text default null,
  p_format_name text default null,
  p_rounds integer default null,
  p_round_seconds integer default 3000,
  p_set_code text default null,
  p_set_name text default null,
  p_cube_name text default null,
  p_cube_url text default null,
  p_team_size integer default null,
  p_format_other text default null,
  p_player_names text[] default '{}',
  p_include_me boolean default true,
  p_show_clock boolean default true,
  p_local_date date default null
) returns json language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_team boolean := p_format_name in ('team_draft', 'team_sealed');
  v_limited boolean := p_format_name in ('draft', 'team_draft', 'sealed', 'team_sealed');
  v_set_name text;
  v_res json;
  v_id uuid;
  v_pod uuid;
  v_me text;
begin
  if v_uid is null then raise exception 'Sign in required to create an event' using errcode = '28000'; end if;
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
  if p_set_code is not null then
    select s.name into v_set_name from public.mtg_sets s where s.code = lower(p_set_code);
    v_set_name := coalesce(v_set_name, nullif(trim(p_set_name), ''), upper(p_set_code));
  elsif v_limited and p_cube_name is null then
    v_set_name := left(nullif(trim(p_set_name), ''), 80);
  end if;

  -- Placeholder name; the auto-name trigger replaces it once the format fields are set below.
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

  -- The organizer plays by default: first in the list, guests after.
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
revoke execute on function public.create_event_v2(text, text, integer, integer, text, text, text, text, integer, text, text[], boolean, boolean, date) from public, anon;
grant execute on function public.create_event_v2(text, text, integer, integer, text, text, text, text, integer, text, text[], boolean, boolean, date) to authenticated;

-- ==================================================================== d_details
-- p_name is ignored for auto-named events; p_round_seconds is ignored (always 50 minutes). p_show_clock null = keep.
drop function if exists public.update_event_details(uuid, text, text, integer, integer, text, text, text, text, integer, text);
create or replace function public.update_event_details(
  p_event_id uuid, p_name text, p_format_name text, p_rounds integer, p_round_seconds integer default 3000,
  p_set_code text default null, p_set_name text default null, p_cube_name text default null, p_cube_url text default null,
  p_team_size integer default null, p_format_other text default null, p_show_clock boolean default null
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
  if not e.auto_name and (v_name is null or char_length(v_name) > 80) then
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
  if p_set_code is not null then
    select s.name into v_set_name from public.mtg_sets s where s.code = lower(p_set_code);
    v_set_name := coalesce(v_set_name, nullif(trim(p_set_name), ''), upper(p_set_code));
  elsif v_limited and p_cube_name is null then
    v_set_name := left(nullif(trim(p_set_name), ''), 80);
  end if;

  v_before := jsonb_build_object('name', e.name, 'format_name', e.format_name, 'rounds', e.number_of_rounds,
    'show_clock', e.show_clock, 'set_code', e.set_code, 'cube_name', e.cube_name, 'team_size', e.team_size);

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
         updated_at = now()
   where id = p_event_id
  returning * into e;

  if not v_team then
    update public.participants set team_id = null, team_slot = null where event_id = p_event_id and team_id is not null;
    update public.event_teams set active = false where event_id = p_event_id and active;
  end if;

  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, reason, before, after)
  values (p_event_id, v_uid, 'event.details_updated', 'event', p_event_id, null, v_before,
          jsonb_build_object('name', e.name, 'format_name', e.format_name, 'rounds', e.number_of_rounds,
            'show_clock', e.show_clock, 'set_code', e.set_code, 'cube_name', e.cube_name, 'team_size', e.team_size));

  return jsonb_build_object('event_id', e.id, 'name', e.name, 'format_name', e.format_name, 'format_label', e.format_label,
    'number_of_rounds', e.number_of_rounds, 'round_length_seconds', e.round_length_seconds, 'set_code', e.set_code,
    'set_name', e.set_name, 'cube_name', e.cube_name, 'cube_url', e.cube_url, 'team_size', e.team_size,
    'format_other', e.format_other, 'show_clock', e.show_clock);
end $$;
revoke execute on function public.update_event_details(uuid, text, text, integer, integer, text, text, text, text, integer, text, boolean) from public, anon;
grant execute on function public.update_event_details(uuid, text, text, integer, integer, text, text, text, text, integer, text, boolean) to authenticated;

-- ==================================================================== e_players
-- Shared checks for adding/removing players: organizer, and nothing paired yet.
create or replace function t1_private.assert_setup_organizer(p_event_id uuid) returns public.events
language plpgsql security definer set search_path = '' as $$
declare e public.events;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into e from public.events where id = p_event_id for update;
  if e.id is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can change the players' using errcode = '42501';
  end if;
  if e.status not in ('setup', 'seated') or exists (select 1 from public.rounds r where r.event_id = p_event_id) then
    raise exception 'Players can only be added or removed before round 1' using errcode = '55000';
  end if;
  return e;
end $$;
revoke execute on function t1_private.assert_setup_organizer(uuid) from public, anon, authenticated;

-- Where a new player goes: the end of the list. In a seated draft they wait unseated; pairing round 1 (or
-- Re-seat) seats everyone.
create or replace function t1_private.next_slot(p_event_id uuid, p_status text, out pod_id uuid, out seat integer)
language sql stable security definer set search_path = '' as $$
  select (select d.id from public.pods d where d.event_id = p_event_id order by d.display_order limit 1),
         case when p_status = 'seated' then null
              else coalesce((select max(p.seat) from public.participants p where p.event_id = p_event_id), 0) + 1 end
$$;
revoke execute on function t1_private.next_slot(uuid, text) from public, anon, authenticated;

create or replace function public.add_self_to_event(p_event_id uuid)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  v_slot record;
  v_name text;
  v_id uuid;
begin
  e := t1_private.assert_setup_organizer(p_event_id);
  if exists (select 1 from public.participants p where p.event_id = p_event_id and p.user_id = v_uid) then
    raise exception 'You''re already playing' using errcode = '23505';
  end if;
  select coalesce(nullif(trim(pr.display_name), ''), nullif(trim(pr.handle), ''), 'Organizer') into v_name
    from public.profiles pr where pr.id = v_uid;
  select * into v_slot from t1_private.next_slot(p_event_id, e.status);
  insert into public.participants (event_id, pod_id, user_id, display_name, seat)
  values (p_event_id, v_slot.pod_id, v_uid, left(coalesce(v_name, 'Organizer'), 40), v_slot.seat)
  returning id into v_id;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, v_uid, 'participant.added', 'participant', v_id, jsonb_build_object('name', v_name, 'self', true));
  return json_build_object('participant_id', v_id, 'display_name', v_name);
end $$;
revoke execute on function public.add_self_to_event(uuid) from public, anon;
grant execute on function public.add_self_to_event(uuid) to authenticated;

create or replace function public.add_guest(p_event_id uuid, p_name text)
returns json language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_name text := nullif(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), '');
  v_slot record;
  v_id uuid;
begin
  e := t1_private.assert_setup_organizer(p_event_id);
  if v_name is null or char_length(v_name) > 40 then
    raise exception 'Names are 1 to 40 characters' using errcode = '22023';
  end if;
  if exists (select 1 from public.participants p where p.event_id = p_event_id and lower(p.display_name) = lower(v_name)) then
    raise exception '% is already in this event', v_name using errcode = '23505';
  end if;
  select * into v_slot from t1_private.next_slot(p_event_id, e.status);
  insert into public.participants (event_id, pod_id, display_name, seat)
  values (p_event_id, v_slot.pod_id, v_name, v_slot.seat)
  returning id into v_id;
  insert into public.participant_tokens (participant_id) values (v_id);
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, auth.uid(), 'participant.added', 'participant', v_id, jsonb_build_object('name', v_name, 'guest', true));
  return json_build_object('participant_id', v_id, 'display_name', v_name);
end $$;
revoke execute on function public.add_guest(uuid, text) from public, anon;
grant execute on function public.add_guest(uuid, text) to authenticated;

-- Before round 1 only (after that, Drop). Seats after the removed one in the same pod move up one.
create or replace function public.remove_participant(p_participant_id uuid)
returns json language plpgsql security definer set search_path = '' as $$
declare
  p public.participants;
begin
  select * into p from public.participants where id = p_participant_id;
  if p.id is null then raise exception 'That player isn''t in the event' using errcode = 'P0002'; end if;
  perform t1_private.assert_setup_organizer(p.event_id);
  delete from public.participants where id = p.id;
  if p.seat is not null then
    update public.participants set seat = seat - 1
     where event_id = p.event_id and seat > p.seat and pod_id is not distinct from p.pod_id;
  end if;
  if p.user_id is not null then
    delete from public.event_invites where event_id = p.event_id and user_id = p.user_id and status = 'pending';
  end if;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before)
  values (p.event_id, auth.uid(), 'participant.removed', 'participant', p.id,
          jsonb_build_object('name', p.display_name, 'user_id', p.user_id, 'seat', p.seat, 'pod_id', p.pod_id));
  return json_build_object('event_id', p.event_id, 'participant_id', p.id);
end $$;
revoke execute on function public.remove_participant(uuid) from public, anon;
grant execute on function public.remove_participant(uuid) to authenticated;

-- ==================================================================== f_cubes
-- Cubes this account has run, newest first, one row per name + link.
create or replace function public.recent_cubes(p_limit integer default 5)
returns table (cube_name text, cube_url text, last_used_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select x.cube_name, x.cube_url, x.last_used_at from (
    select distinct on (lower(e.cube_name), coalesce(e.cube_url, ''))
           e.cube_name, e.cube_url, e.created_at as last_used_at
      from public.events e
     where e.created_by = auth.uid() and e.cube_name is not null and not e.is_demo
     order by lower(e.cube_name), coalesce(e.cube_url, ''), e.created_at desc
  ) x
  order by x.last_used_at desc
  limit least(greatest(coalesce(p_limit, 5), 1), 20)
$$;
revoke execute on function public.recent_cubes(integer) from public, anon;
grant execute on function public.recent_cubes(integer) to authenticated;
