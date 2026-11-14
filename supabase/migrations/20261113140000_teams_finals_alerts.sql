-- Phase 2 of leagues: teams that sign themselves up with a captain, Team Trios, a top 4 cut, championship
-- invitations, and alerts for new public events (contract/teams-finals-alerts-2026-11-13.md; plan
-- table-1-context/docs/plan-public-events-leagues-2026-11-13.md § Phase 2).
--
--   a  formats: team_trios (three seats, a constructed format each), top cut 4, the cut rule by format
--   b  create_event_v2 / update_event_details with team_trios (from 20261027120000, otherwise unchanged)
--   c  team sign-up: captains, team codes, team_create / team_join / team_update / team_mine
--   d  a season's final: who qualified and where each stands, Invite the qualified
--   e  alerts for new public events by format and area
--   f  grants, cron

-- ==================================================================== a_formats
alter table public.events
  add column if not exists seat_formats text[],
  add column if not exists team_signup boolean not null default false;

alter table public.events drop constraint if exists events_format_name_check;
alter table public.events add constraint events_format_name_check check (format_name = any (array[
  'standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'premodern', 'canadian_highlander',
  'other_constructed', 'draft', 'team_draft', 'sealed', 'team_sealed', 'roto', 'team_trios']));
alter table public.events drop constraint if exists events_team_size_check;
alter table public.events add constraint events_team_size_check
  check ((format_name in ('team_draft', 'team_sealed', 'team_trios')) = (team_size is not null)
         and (team_size is null or team_size in (3, 4))
         and (format_name <> 'team_trios' or team_size = 3));
alter table public.events drop constraint if exists events_seat_formats_check;
alter table public.events add constraint events_seat_formats_check
  check ((format_name = 'team_trios') = (seat_formats is not null)
         and (seat_formats is null or (cardinality(seat_formats) = 3 and seat_formats <@ array[
           'standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'premodern', 'canadian_highlander',
           'duel_commander', 'other'])));
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.events'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%top_cut%' loop
    execute format('alter table public.events drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.events add constraint events_top_cut_check check (top_cut in (0, 4, 8));

alter table public.events alter column format_label set expression as (
  case format_name
    when 'standard' then 'Standard' when 'pioneer' then 'Pioneer' when 'modern' then 'Modern'
    when 'legacy' then 'Legacy' when 'vintage' then 'Vintage' when 'pauper' then 'Pauper'
    when 'premodern' then 'Premodern' when 'canadian_highlander' then 'Canadian Highlander'
    when 'other_constructed' then coalesce(format_other, 'Constructed')
    when 'draft' then 'Draft' when 'team_draft' then 'Team draft'
    when 'sealed' then 'Sealed' when 'team_sealed' then 'Team sealed' when 'roto' then 'Roto'
    when 'team_trios' then 'Team Trios'
    else 'Event' end
  || case when cube_name is not null then ' · ' || cube_name
          when set_name is not null then ' · ' || set_name else '' end);

-- events_format_sync (from 20261016220000_roto) plus team_trios: three players a team, a format a seat
-- (Modern / Standard / Pioneer until the organizer picks), and no seat formats or team sign-up on other formats.
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
  if new.format_name = 'team_trios' then
    new.team_size := 3;
    new.seat_formats := coalesce(new.seat_formats, array['modern', 'standard', 'pioneer']);
  else
    new.seat_formats := null;
  end if;
  if new.format_name not in ('team_draft', 'team_sealed', 'team_trios') then
    new.team_size := null;
    new.team_signup := false;
  end if;
  if new.format_name is distinct from 'roto' then new.pairing := 'swiss'; end if;
  return new;
end $$;
drop trigger if exists events_format_sync on public.events;
create trigger events_format_sync before insert or update of format, format_name, cube_name, team_size, seat_formats, team_signup
  on public.events for each row execute function public.events_format_sync();

-- The cut by format: top 8 for Swiss events of players; top 4 for those and for team sealed and Team Trios (never a
-- team draft, which is two teams). Automatic rounds stay for Swiss events of players.
create or replace function t1_private.check_cut_format(p_format_name text, p_pairing text, p_top_cut integer,
  p_auto_rounds boolean)
returns void language plpgsql immutable set search_path = '' as $$
declare v_team boolean := p_format_name in ('team_draft', 'team_sealed', 'team_trios');
begin
  if coalesce(p_top_cut, 0) not in (0, 4, 8) then
    raise exception 'Top cut is none, top 4 or top 8' using errcode = '22023';
  end if;
  if coalesce(p_top_cut, 0) > 0 and (p_pairing <> 'swiss' or p_format_name = 'team_draft') then
    raise exception 'A top cut is for Swiss events' using errcode = '22023';
  end if;
  if coalesce(p_top_cut, 0) = 8 and v_team then
    raise exception 'Team events cut to top 4' using errcode = '22023';
  end if;
  if coalesce(p_auto_rounds, false) and (v_team or p_pairing <> 'swiss') then
    raise exception 'Automatic rounds are for Swiss events' using errcode = '22023';
  end if;
end $$;

-- Team Trios: which constructed format each seat plays (A, B, C). Before round 1.
create or replace function public.set_event_trios(p_event_id uuid, p_seat_formats text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e public.events;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into e from public.events where id = p_event_id for update;
  if e.id is null or not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can change this' using errcode = '42501';
  end if;
  if e.format_name <> 'team_trios' then raise exception 'Seat formats are for Team Trios' using errcode = '22023'; end if;
  if e.current_round > 0 or e.status not in ('setup', 'seated') then
    raise exception 'Details lock once round 1 is paired' using errcode = '55000';
  end if;
  if p_seat_formats is null or cardinality(p_seat_formats) <> 3 or not p_seat_formats <@ array[
       'standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'premodern', 'canadian_highlander',
       'duel_commander', 'other'] then
    raise exception 'Pick a format for each of the three seats' using errcode = '22023';
  end if;
  if p_seat_formats is distinct from e.seat_formats then
    update public.events set seat_formats = p_seat_formats, updated_at = now() where id = p_event_id;
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
    values (p_event_id, auth.uid(), 'event.seat_formats', 'event', p_event_id,
            jsonb_build_object('seat_formats', e.seat_formats), jsonb_build_object('seat_formats', p_seat_formats));
  end if;
  return jsonb_build_object('seat_formats', p_seat_formats);
end $$;

-- ==================================================================== b_create
-- create_event_v2 (from 20261027120000_scheduled_events) with team_trios: a team event of three, constructed.
create or replace function public.create_event_v2(p_name text default null, p_format_name text default null,
  p_rounds integer default null, p_round_seconds integer default 3000, p_set_code text default null,
  p_set_name text default null, p_cube_name text default null, p_cube_url text default null,
  p_team_size integer default null, p_format_other text default null, p_player_names text[] default '{}',
  p_include_me boolean default true, p_show_clock boolean default true, p_local_date date default null,
  p_pairing text default null, p_starts_at timestamptz default null, p_venue_name text default null,
  p_capacity integer default null, p_top_cut integer default 0, p_auto_rounds boolean default false,
  p_decklists text default 'off')
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_team boolean := p_format_name in ('team_draft', 'team_sealed', 'team_trios');
  v_limited boolean := p_format_name in ('draft', 'team_draft', 'sealed', 'team_sealed', 'roto');
  v_roto boolean := p_format_name = 'roto';
  v_pairing text := case when p_format_name = 'roto' then coalesce(p_pairing, 'round_robin') else 'swiss' end;
  v_name text := nullif(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), '');
  v_set_name text;
  v_res json;
  v_id uuid;
  v_pod uuid;
  v_me text;
begin
  if v_uid is null then raise exception 'Sign in required to create an event' using errcode = '28000'; end if;
  if p_format_name is null or p_format_name not in ('standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper',
      'premodern', 'canadian_highlander', 'other_constructed', 'draft', 'team_draft', 'sealed', 'team_sealed', 'roto',
      'team_trios') then
    raise exception 'Pick a format' using errcode = '22023';
  end if;
  if v_team and p_format_name <> 'team_trios' and coalesce(p_team_size, 0) not in (3, 4) then
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
  if v_name is not null and char_length(v_name) > 80 then
    raise exception 'Name the event (up to 80 characters)' using errcode = '22023';
  end if;
  perform t1_private.check_cut_format(p_format_name, v_pairing, p_top_cut, p_auto_rounds);
  perform t1_private.check_schedule(p_starts_at, p_venue_name, p_capacity);
  perform t1_private.check_decklists(v_limited, p_decklists);
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
         team_size = case when p_format_name = 'team_trios' then 3 when v_team then p_team_size end,
         show_clock = coalesce(p_show_clock, true),
         name_date = coalesce(p_local_date, (coalesce(p_starts_at, now()) at time zone 'utc')::date),
         auto_name = v_name is null,
         name = coalesce(v_name, name),
         starts_at = p_starts_at,
         venue_name = nullif(trim(p_venue_name), ''),
         capacity = p_capacity,
         top_cut = coalesce(p_top_cut, 0),
         auto_rounds = coalesce(p_auto_rounds, false),
         decklists = coalesce(p_decklists, 'off')
   where id = v_id;
  if v_roto then
    update public.events set pairing = v_pairing where id = v_id;
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

-- update_event_details (from 20261027120000_scheduled_events) with team_trios and the cut rule by format.
create or replace function public.update_event_details(p_event_id uuid, p_name text, p_format_name text,
  p_rounds integer, p_round_seconds integer default 3000, p_set_code text default null, p_set_name text default null,
  p_cube_name text default null, p_cube_url text default null, p_team_size integer default null,
  p_format_other text default null, p_show_clock boolean default null, p_pairing text default null,
  p_top_cut integer default null, p_auto_rounds boolean default null, p_auto_name boolean default null,
  p_decklists text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  v_team boolean := p_format_name in ('team_draft', 'team_sealed', 'team_trios');
  v_limited boolean := p_format_name in ('draft', 'team_draft', 'sealed', 'team_sealed', 'roto');
  v_roto boolean := p_format_name = 'roto';
  v_set_name text;
  v_name text := nullif(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), '');
  v_auto boolean;
  v_pairing text;
  v_top_cut integer;
  v_auto_rounds boolean;
  v_decklists text;
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
  v_auto := case when p_auto_name is not null then p_auto_name else e.auto_name end;
  if not v_auto and (v_name is null or char_length(v_name) > 80) then
    raise exception 'Name the event (up to 80 characters)' using errcode = '22023';
  end if;
  if p_format_name is null or p_format_name not in ('standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper',
      'premodern', 'canadian_highlander', 'other_constructed', 'draft', 'team_draft', 'sealed', 'team_sealed', 'roto',
      'team_trios') then
    raise exception 'Pick a format' using errcode = '22023';
  end if;
  if v_team and p_format_name <> 'team_trios' and coalesce(p_team_size, 0) not in (3, 4) then
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
  v_pairing := case when v_roto then coalesce(p_pairing, case when e.format_name = 'roto' then e.pairing end, 'round_robin')
                    else 'swiss' end;
  -- Kept values that no longer fit the format (a roto or team event) quietly fall back; sent ones are checked.
  v_top_cut := coalesce(p_top_cut, case when v_pairing <> 'swiss' or p_format_name = 'team_draft' then 0
                                         when v_team then least(e.top_cut, 4) else e.top_cut end);
  v_auto_rounds := coalesce(p_auto_rounds, e.auto_rounds and not v_team and v_pairing = 'swiss');
  perform t1_private.check_cut_format(p_format_name, v_pairing, v_top_cut, v_auto_rounds);
  v_decklists := coalesce(p_decklists, case when v_limited then 'off' else e.decklists end);
  perform t1_private.check_decklists(v_limited, v_decklists);
  if p_set_code is not null then
    select s.name into v_set_name from public.mtg_sets s where s.code = lower(p_set_code);
    v_set_name := coalesce(v_set_name, nullif(trim(p_set_name), ''), upper(p_set_code));
  elsif v_limited and p_cube_name is null then
    v_set_name := left(nullif(trim(p_set_name), ''), 80);
  end if;

  v_before := jsonb_build_object('name', e.name, 'auto_name', e.auto_name, 'decklists', e.decklists, 'format_name', e.format_name,
    'rounds', e.number_of_rounds, 'show_clock', e.show_clock, 'set_code', e.set_code, 'cube_name', e.cube_name,
    'team_size', e.team_size, 'pairing', e.pairing, 'top_cut', e.top_cut, 'auto_rounds', e.auto_rounds);

  update public.events
     set name = case when v_auto then e.name else v_name end,
         auto_name = v_auto,
         format_name = p_format_name,
         format_other = case when p_format_name = 'other_constructed' then left(nullif(trim(p_format_other), ''), 40) end,
         set_code = lower(p_set_code),
         set_name = v_set_name,
         cube_name = case when v_limited then nullif(trim(p_cube_name), '') end,
         cube_url = case when v_limited and nullif(trim(p_cube_name), '') is not null then nullif(trim(p_cube_url), '') end,
         team_size = case when p_format_name = 'team_trios' then 3 when v_team then p_team_size end,
         number_of_rounds = p_rounds,
         round_length_seconds = 3000,
         show_clock = coalesce(p_show_clock, e.show_clock),
         pairing = v_pairing,
         top_cut = v_top_cut,
         auto_rounds = v_auto_rounds,
         decklists = v_decklists,
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
          jsonb_build_object('name', e.name, 'auto_name', e.auto_name, 'decklists', e.decklists, 'format_name', e.format_name,
            'rounds', e.number_of_rounds, 'show_clock', e.show_clock, 'set_code', e.set_code, 'cube_name', e.cube_name,
            'team_size', e.team_size, 'pairing', e.pairing, 'top_cut', e.top_cut, 'auto_rounds', e.auto_rounds));

  return jsonb_build_object('event_id', e.id, 'name', e.name, 'format_name', e.format_name, 'format_label', e.format_label,
    'number_of_rounds', e.number_of_rounds, 'round_length_seconds', e.round_length_seconds, 'set_code', e.set_code,
    'set_name', e.set_name, 'cube_name', e.cube_name, 'cube_url', e.cube_url, 'team_size', e.team_size,
    'format_other', e.format_other, 'show_clock', e.show_clock, 'pairing', e.pairing, 'top_cut', e.top_cut,
    'auto_rounds', e.auto_rounds, 'auto_name', e.auto_name, 'decklists', e.decklists);
end $$;

-- ==================================================================== c_teams
alter table public.event_teams
  add column if not exists captain_id uuid,
  add column if not exists join_code text;
create unique index if not exists event_teams_join_code_idx on public.event_teams (join_code) where join_code is not null;

-- Teams sign themselves up (on) or the organizer builds them (off, as before). Before round 1.
create or replace function public.team_signup_set(p_event_id uuid, p_on boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e public.events;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into e from public.events where id = p_event_id for update;
  if e.id is null or not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can change this' using errcode = '42501';
  end if;
  if e.team_size is null then raise exception 'This is not a team event' using errcode = '22023'; end if;
  if e.current_round > 0 or e.status not in ('setup', 'seated') then
    raise exception 'Details lock once round 1 is paired' using errcode = '55000';
  end if;
  if coalesce(p_on, false) is distinct from e.team_signup then
    update public.events set team_signup = coalesce(p_on, false), updated_at = now() where id = p_event_id;
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
    values (p_event_id, auth.uid(), 'event.team_signup', 'event', p_event_id, jsonb_build_object('on', coalesce(p_on, false)));
  end if;
  return jsonb_build_object('team_signup', coalesce(p_on, false));
end $$;

-- Seats a team sign-up event has spoken for: every active team counts whole, plus players on no team.
create or replace function t1_private.team_seats_taken(p_event_id uuid, p_team_size integer)
returns integer language sql stable security definer set search_path = '' as $$
  select ((select count(*) from public.event_teams t where t.event_id = p_event_id and t.active) * p_team_size
        + (select count(*) from public.participants p where p.event_id = p_event_id and p.status = 'active' and p.team_id is null))::integer;
$$;

create or replace function t1_private.team_json(t public.event_teams, p_with_code boolean)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', t.id, 'name', t.name, 'captain_id', t.captain_id,
    'join_code', case when p_with_code then t.join_code end,
    'members', coalesce((select jsonb_agg(jsonb_build_object('participant_id', p.id, 'user_id', p.user_id,
                                                              'name', p.display_name, 'slot', p.team_slot)
                                           order by p.team_slot, p.created_at)
                           from public.participants p where p.team_id = t.id), '[]'::jsonb),
    'complete', (select count(*) from public.participants p where p.team_id = t.id)
                = (select e.team_size from public.events e where e.id = t.event_id));
$$;

-- Teams as the event page shows them: every team with its size, your own team in full (with its code when you're on
-- it or run the event), and whether you could start one.
create or replace function public.team_mine(p_event_id uuid, p_token text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  v_access text := t1_private.event_access(p_event_id, p_token);
  t public.event_teams;
  v_on_team boolean;
begin
  if v_access = 'none' then raise exception 'That event isn''t available' using errcode = '42501'; end if;
  select * into e from public.events where id = p_event_id;
  if v_uid is not null then
    select x.* into t from public.event_teams x
      join public.participants p on p.team_id = x.id and p.user_id = v_uid
     where x.event_id = p_event_id and x.active limit 1;
  end if;
  v_on_team := t.id is not null;
  return jsonb_build_object(
    'team_signup', e.team_signup, 'team_size', e.team_size, 'seat_formats', e.seat_formats,
    'team', case when v_on_team then t1_private.team_json(t, true) end,
    'captain', v_on_team and t.captain_id = v_uid,
    'can_create', v_uid is not null and e.team_signup and not v_on_team and t1_private.sign_up_open(e)
                  and (e.capacity is null or t1_private.team_seats_taken(e.id, e.team_size) + e.team_size <= e.capacity),
    'teams', coalesce((
      select jsonb_agg(case when v_access = 'organizer' then t1_private.team_json(x, true)
                            else jsonb_build_object('id', x.id, 'name', x.name,
                                   'members', (select count(*) from public.participants p where p.team_id = x.id),
                                   'complete', (select count(*) from public.participants p where p.team_id = x.id) = e.team_size) end
                       order by x.display_order)
        from public.event_teams x where x.event_id = p_event_id and x.active), '[]'::jsonb));
end $$;

-- Sign up a team: you become its captain and take seat A. Teammates join with the team's code.
create or replace function public.team_create(p_event_id uuid, p_name text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_res jsonb;
  t public.event_teams;
begin
  if v_uid is null then raise exception 'Sign in to sign up' using errcode = '28000'; end if;
  select * into e from public.events where id = p_event_id;
  if e.id is null or e.is_demo or t1_private.event_access(e.id) = 'none' then
    raise exception 'That event isn''t available' using errcode = '42501';
  end if;
  if e.team_size is null or not e.team_signup then
    raise exception 'The organizer builds the teams for this event' using errcode = '22023';
  end if;
  if not t1_private.sign_up_open(e) then raise exception 'Sign-ups are closed' using errcode = '55000'; end if;
  if char_length(v_name) not between 1 and 40 then raise exception 'Name the team (up to 40 characters)' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(e.id::text, 0));
  if exists (select 1 from public.participants p where p.event_id = e.id and p.user_id = v_uid and p.team_id is not null) then
    raise exception 'You''re on a team already' using errcode = '22023';
  end if;
  if exists (select 1 from public.event_teams x where x.event_id = e.id and x.active and lower(x.name) = lower(v_name)) then
    raise exception 'A team has that name' using errcode = '23505';
  end if;
  if e.capacity is not null and t1_private.team_seats_taken(e.id, e.team_size)
       - (case when exists (select 1 from public.participants p where p.event_id = e.id and p.user_id = v_uid) then 1 else 0 end)
       + e.team_size > e.capacity then
    raise exception 'The event is full' using errcode = '55000';
  end if;
  v_res := public.event_sign_up(p_event_id);
  if v_res->>'status' not in ('joined', 'already_joined') then
    raise exception 'The event is full' using errcode = '55000';
  end if;
  insert into public.event_teams (event_id, display_order, name, captain_id, join_code)
  values (e.id, coalesce((select max(x.display_order) from public.event_teams x where x.event_id = e.id), 0) + 1, v_name, v_uid,
          upper(substr(translate(encode(extensions.gen_random_bytes(12), 'base64'), '+/=O0Il1', ''), 1, 8)))
  returning * into t;
  update public.participants set team_id = t.id, team_slot = 1 where id = (v_res->>'participant_id')::uuid;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (e.id, v_uid, 'team.created', 'team', t.id, jsonb_build_object('name', t.name));
  return public.team_mine(p_event_id);
end $$;

-- Join a team with its code: you take its next free seat.
create or replace function public.team_join(p_event_id uuid, p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  t public.event_teams;
  v_res jsonb;
  v_slot integer;
begin
  if v_uid is null then raise exception 'Sign in to sign up' using errcode = '28000'; end if;
  perform t1_private.rate_hit('team.join', 20, 200, interval '10 minutes');
  select * into e from public.events where id = p_event_id;
  if e.id is null or e.is_demo or t1_private.event_access(e.id) = 'none' then
    raise exception 'That event isn''t available' using errcode = '42501';
  end if;
  if not t1_private.sign_up_open(e) then raise exception 'Sign-ups are closed' using errcode = '55000'; end if;
  perform pg_advisory_xact_lock(hashtextextended(e.id::text, 0));
  select * into t from public.event_teams x
   where x.event_id = e.id and x.active and x.join_code = upper(btrim(coalesce(p_code, '')));
  if t.id is null then raise exception 'That team code isn''t right' using errcode = 'P0002'; end if;
  if exists (select 1 from public.participants p where p.event_id = e.id and p.user_id = v_uid and p.team_id is not null) then
    raise exception 'You''re on a team already' using errcode = '22023';
  end if;
  if (select count(*) from public.participants p where p.team_id = t.id) >= e.team_size then
    raise exception 'That team is full' using errcode = '22023';
  end if;
  v_res := public.event_sign_up(p_event_id);
  if v_res->>'status' not in ('joined', 'already_joined') then
    raise exception 'The event is full' using errcode = '55000';
  end if;
  select min(s) into v_slot from generate_series(1, e.team_size) s
   where not exists (select 1 from public.participants p where p.team_id = t.id and p.team_slot = s);
  update public.participants set team_id = t.id, team_slot = v_slot where id = (v_res->>'participant_id')::uuid;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (e.id, v_uid, 'team.joined', 'team', t.id, jsonb_build_object('slot', v_slot));
  return public.team_mine(p_event_id);
end $$;

-- The captain (or an organizer) changes a team before round 1. p_patch keys: name; order [participant ids, every
-- member once: seat A first]; captain (a member's user id); remove (a member's participant id: they leave the event).
create or replace function public.team_update(p_team_id uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  t public.event_teams;
  e public.events;
  v_name text;
  v_ids uuid[];
  v_cap uuid;
  p public.participants;
  i integer;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into t from public.event_teams where id = p_team_id and active for update;
  if t.id is null then raise exception 'That team isn''t in this event' using errcode = 'P0002'; end if;
  select * into e from public.events where id = t.event_id;
  if t.captain_id is distinct from v_uid and not public.is_event_organizer(t.event_id) then
    raise exception 'Only the captain can change the team' using errcode = '42501';
  end if;
  if e.current_round > 0 or e.status not in ('setup', 'seated') then
    raise exception 'Teams lock once round 1 is paired' using errcode = '55000';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception 'Say what to change' using errcode = '22023'; end if;

  if p_patch ? 'name' then
    v_name := btrim(regexp_replace(coalesce(p_patch->>'name', ''), '\s+', ' ', 'g'));
    if char_length(v_name) not between 1 and 40 then raise exception 'Name the team (up to 40 characters)' using errcode = '22023'; end if;
    if exists (select 1 from public.event_teams x where x.event_id = t.event_id and x.active and x.id <> t.id and lower(x.name) = lower(v_name)) then
      raise exception 'A team has that name' using errcode = '23505';
    end if;
    update public.event_teams set name = v_name where id = t.id;
  end if;
  if p_patch ? 'remove' then
    select * into p from public.participants where id = (p_patch->>'remove')::uuid and team_id = t.id;
    if p.id is null then raise exception 'That player isn''t on this team' using errcode = 'P0002'; end if;
    if p.user_id = t.captain_id then raise exception 'Hand the captaincy on first' using errcode = '22023'; end if;
    delete from public.participants where id = p.id;
    if p.seat is not null then
      update public.participants set seat = seat - 1
       where event_id = p.event_id and seat > p.seat and pod_id is not distinct from p.pod_id;
    end if;
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before)
    values (t.event_id, v_uid, 'team.removed', 'participant', p.id, jsonb_build_object('name', p.display_name, 'team_id', t.id));
    perform t1_private.waitlist_move_up(t.event_id);
  end if;
  if p_patch ? 'order' then
    v_ids := array(select (x)::uuid from jsonb_array_elements_text(p_patch->'order') x);
    if (select array_agg(m.id order by m.id) from public.participants m where m.team_id = t.id)
       is distinct from (select array_agg(x order by x) from unnest(v_ids) x) then
      raise exception 'List every member of the team once' using errcode = '22023';
    end if;
    update public.participants set team_slot = null where team_id = t.id;
    for i in 1..cardinality(v_ids) loop
      update public.participants set team_slot = i where id = v_ids[i];
    end loop;
  end if;
  if p_patch ? 'captain' then
    v_cap := (p_patch->>'captain')::uuid;
    if not exists (select 1 from public.participants m where m.team_id = t.id and m.user_id = v_cap) then
      raise exception 'The captain is a member of the team' using errcode = '22023';
    end if;
    update public.event_teams set captain_id = v_cap where id = t.id;
  end if;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (t.event_id, v_uid, 'team.updated', 'team', t.id, p_patch);
  return public.team_mine(t.event_id);
exception when invalid_text_representation then
  raise exception 'Check the ids' using errcode = '22023';
end $$;

-- A member leaves (event_leave, a removal, an organizer's change): an empty sign-up team closes, and a team whose
-- captain left passes the captaincy to its first remaining member with an account.
create or replace function t1_private.team_member_gone_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
declare t public.event_teams;
begin
  if old.team_id is null or (tg_op = 'UPDATE' and new.team_id is not distinct from old.team_id) then return null; end if;
  select * into t from public.event_teams where id = old.team_id;
  if t.id is null or t.captain_id is null then return null; end if;
  if not exists (select 1 from public.participants p where p.team_id = t.id) then
    update public.event_teams set active = false, join_code = null where id = t.id;
  elsif old.user_id is not distinct from t.captain_id then
    update public.event_teams
       set captain_id = (select p.user_id from public.participants p
                          where p.team_id = t.id and p.user_id is not null order by p.team_slot, p.created_at limit 1)
     where id = t.id;
  end if;
  return null;
exception when others then
  raise warning 'team_member_gone_trg skipped: %', sqlerrm;
  return null;
end $$;
drop trigger if exists participants_team_gone on public.participants;
create trigger participants_team_gone
  after delete or update of team_id on public.participants
  for each row execute function t1_private.team_member_gone_trg();

-- ==================================================================== d_finals
-- A season's final, for whoever runs both it and the league: everyone who qualified with where they stand for this
-- event (in | invited | declined | guest | none), and the next eight on points in case an invitation passes down.
create or replace function public.league_final_status(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); le public.league_events;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into le from public.league_events where event_id = p_event_id and final;
  if le.event_id is null or not public.is_event_organizer(p_event_id) or t1_private.league_role(le.league_id, v_uid) is null then
    raise exception 'Only the organizers of a season''s final can see this' using errcode = '42501';
  end if;
  return (
    with t as (
      select x.*,
             case when x.user_id is null then 'guest'
                  when exists (select 1 from public.participants p where p.event_id = p_event_id and p.user_id = x.user_id) then 'in'
                  else coalesce((select case i.status when 'pending' then 'invited' when 'declined' then 'declined' end
                                   from public.event_invites i where i.event_id = p_event_id and i.user_id = x.user_id), 'none') end as state
        from t1_private.league_table(le.season_id) x)
    select jsonb_build_object(
      'season_id', le.season_id,
      'qualified', coalesce((select jsonb_agg(jsonb_build_object('key', t.key, 'user_id', t.user_id, 'name', t.name, 'rank', t.rank,
                                                                   'points', t.points, 'how', t.qualified, 'state', t.state) order by t.ord)
                               from t where t.qualified is not null), '[]'::jsonb),
      'next', coalesce((select jsonb_agg(jsonb_build_object('key', n.key, 'user_id', n.user_id, 'name', n.name, 'rank', n.rank,
                                                              'points', n.points, 'how', null, 'state', n.state) order by n.ord)
                          from (select * from t where t.qualified is null order by t.ord limit 8) n), '[]'::jsonb)));
end $$;

-- Invite the qualified (p_keys null: everyone qualified with an account who isn't in or invited yet), or the named
-- players (to pass an invitation down). Goes through invite_players, so its limits, blocks and pushes apply.
create or replace function public.league_final_invite(p_event_id uuid, p_keys text[] default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); le public.league_events; v_ids uuid[];
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into le from public.league_events where event_id = p_event_id and final;
  if le.event_id is null or not public.is_event_organizer(p_event_id) or t1_private.league_role(le.league_id, v_uid) is null then
    raise exception 'Only the organizers of a season''s final can invite to it' using errcode = '42501';
  end if;
  select array_agg(x.user_id) into v_ids
    from t1_private.league_table(le.season_id) x
   where x.user_id is not null and x.user_id <> v_uid
     and ((p_keys is null and x.qualified is not null) or x.key = any (p_keys))
     and not exists (select 1 from public.participants p where p.event_id = p_event_id and p.user_id = x.user_id)
     and not exists (select 1 from public.event_invites i where i.event_id = p_event_id and i.user_id = x.user_id and i.status = 'pending');
  if coalesce(cardinality(v_ids), 0) = 0 then return jsonb_build_object('ok', true, 'invited', 0); end if;
  return public.invite_players(p_event_id, v_ids);
end $$;

-- ==================================================================== e_alerts
-- Alerts for new public events: the formats you want and, if you like, a rough home area you chose (rounded to
-- 0.1 degree, about 10 km) with a distance. Nothing here is read from the phone's location without your pick.
create table if not exists public.event_alerts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  enabled boolean not null default true,
  formats text[] not null default '{}',
  place extensions.geography(Point, 4326),
  km integer check (km is null or km between 5 and 500),
  updated_at timestamptz not null default now()
);
alter table public.event_alerts enable row level security;
revoke all on public.event_alerts from anon, authenticated;

create table if not exists t1_private.event_alert_queue (
  event_id uuid primary key references public.events (id) on delete cascade,
  due_at timestamptz not null,
  sent_at timestamptz
);
create table if not exists t1_private.event_alert_log (
  user_id uuid not null,
  event_id uuid not null,
  at timestamptz not null default now(),
  primary key (user_id, event_id)
);
create index if not exists event_alert_log_user_idx on t1_private.event_alert_log (user_id, at desc);
alter table t1_private.event_alert_queue enable row level security;
alter table t1_private.event_alert_log enable row level security;

create or replace function t1_private.event_alerts_json(a public.event_alerts)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'on', coalesce(a.enabled, false), 'formats', coalesce(to_jsonb(a.formats), '[]'::jsonb), 'km', a.km,
    'lat', case when a.place is not null then round(extensions.st_y(a.place::extensions.geometry)::numeric, 1) end,
    'lng', case when a.place is not null then round(extensions.st_x(a.place::extensions.geometry)::numeric, 1) end);
$$;

create or replace function public.event_alerts_get()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.event_alerts;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into a from public.event_alerts where user_id = auth.uid();
  return t1_private.event_alerts_json(a);
end $$;

-- p_patch keys: on; formats [format keys, empty = every format]; km (null = anywhere); lat + lng (your area; kept
-- rounded to 0.1 degree), or place: null to forget it.
create or replace function public.event_alerts_set(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  a public.event_alerts;
  v_lat double precision; v_lng double precision;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception 'Say what to change' using errcode = '22023'; end if;
  select * into a from public.event_alerts where user_id = v_uid;
  if a.user_id is null then a.user_id := v_uid; a.enabled := true; a.formats := '{}'; end if;
  begin
    if p_patch ? 'on' then a.enabled := (p_patch->>'on')::boolean; end if;
    if p_patch ? 'formats' then a.formats := array(select jsonb_array_elements_text(p_patch->'formats')); end if;
    if p_patch ? 'km' then a.km := (p_patch->>'km')::integer; end if;
    if p_patch ? 'lat' or p_patch ? 'lng' then
      v_lat := round((p_patch->>'lat')::numeric, 1); v_lng := round((p_patch->>'lng')::numeric, 1);
    end if;
  exception when others then
    raise exception 'Check the alert settings' using errcode = '22023';
  end;
  if a.enabled is null or not a.formats <@ array['standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'premodern',
                                                  'canadian_highlander', 'limited', 'cube', 'other'] then
    raise exception 'Unknown format' using errcode = '22023';
  end if;
  if a.km is not null and a.km not between 5 and 500 then raise exception 'A distance is 5 to 500 km' using errcode = '22023'; end if;
  if p_patch ? 'lat' or p_patch ? 'lng' then
    if v_lat is null or v_lng is null or v_lat not between -90 and 90 or v_lng not between -180 and 180 then
      raise exception 'Invalid coordinates' using errcode = '22023';
    end if;
    a.place := extensions.st_setsrid(extensions.st_makepoint(v_lng, v_lat), 4326)::extensions.geography;
  elsif p_patch ? 'place' and jsonb_typeof(p_patch->'place') = 'null' then
    a.place := null;
  end if;
  if a.km is not null and a.place is null then raise exception 'A distance needs an area' using errcode = '22023'; end if;
  insert into public.event_alerts (user_id, enabled, formats, place, km, updated_at)
  values (v_uid, a.enabled, a.formats, a.place, a.km, now())
  on conflict (user_id) do update set enabled = excluded.enabled, formats = excluded.formats, place = excluded.place,
                                      km = excluded.km, updated_at = now()
  returning * into a;
  insert into public.account_audit (actor, action, after)
  values (v_uid, 'alerts.events', jsonb_build_object('on', a.enabled, 'formats', a.formats, 'km', a.km, 'place', a.place is not null));
  return t1_private.event_alerts_json(a);
end $$;

-- An event became public: its alert waits ten minutes so the details settle.
create or replace function t1_private.event_alert_queue_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.visibility = 'public' and not new.is_demo and new.status in ('setup', 'seated')
     and (tg_op = 'INSERT' or old.visibility is distinct from 'public') then
    insert into t1_private.event_alert_queue (event_id, due_at) values (new.id, now() + interval '10 minutes')
    on conflict (event_id) do nothing;
  end if;
  return null;
exception when others then
  raise warning 'event_alert_queue_trg skipped: %', sqlerrm;
  return null;
end $$;
drop trigger if exists events_alert_queue on public.events;
create trigger events_alert_queue
  after insert or update of visibility on public.events
  for each row execute function t1_private.event_alert_queue_trg();

-- Sends due alerts: once per event, to accounts whose formats and area match, who aren't in it or running it, with
-- no block with its creator, at most five alerts an account a week.
create or replace function t1_private.event_alerts_send()
returns integer language plpgsql security definer set search_path = '' as $$
declare q record; e public.events; v_key text; v_loc extensions.geography; v_ids uuid[]; v_n integer := 0;
begin
  for q in select event_id from t1_private.event_alert_queue where sent_at is null and due_at <= now() order by due_at limit 20 loop
    update t1_private.event_alert_queue set sent_at = now() where event_id = q.event_id;
    select * into e from public.events where id = q.event_id;
    continue when e.id is null or e.visibility <> 'public' or e.is_demo or e.status not in ('setup', 'seated')
               or (e.starts_at is not null and e.starts_at < now());
    v_key := t1_private.event_format_key(e.format_name, e.cube_name);
    select l.location into v_loc from public.event_locations l where l.event_id = e.id;
    select array_agg(a.user_id) into v_ids
      from public.event_alerts a
      join public.profiles p on p.id = a.user_id and p.deleted_at is null and not p.is_demo
     where a.enabled and a.user_id <> e.created_by
       and (cardinality(a.formats) = 0 or v_key = any (a.formats))
       and (a.km is null or (v_loc is not null and extensions.st_dwithin(v_loc, a.place, a.km * 1000.0)))
       and not exists (select 1 from public.event_members m where m.event_id = e.id and m.user_id = a.user_id)
       and not exists (select 1 from public.participants x where x.event_id = e.id and x.user_id = a.user_id)
       and not exists (select 1 from public.user_blocks b
                        where (b.user_id = e.created_by and b.blocked_id = a.user_id)
                           or (b.user_id = a.user_id and b.blocked_id = e.created_by))
       and (select count(*) from t1_private.event_alert_log g where g.user_id = a.user_id and g.at > now() - interval '7 days') < 5;
    continue when v_ids is null;
    insert into t1_private.event_alert_log (user_id, event_id) select u, e.id from unnest(v_ids) u on conflict do nothing;
    perform public.enqueue_notification('event.public_new', e.id, v_ids,
      jsonb_build_object('event_name', e.name, 'format_label', e.format_label, 'venue_name', e.venue_name,
                         'starts_at', e.starts_at, 'near', v_loc is not null));
    v_n := v_n + cardinality(v_ids);
  end loop;
  return v_n;
end $$;

-- ==================================================================== f_grants
do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 't1_private' and p.proname in (
              'check_cut_format', 'team_seats_taken', 'team_json', 'team_member_gone_trg', 'event_alerts_json',
              'event_alert_queue_trg', 'event_alerts_send') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.set_event_trios(uuid, text[])', 'public.team_signup_set(uuid, boolean)', 'public.team_create(uuid, text)',
    'public.team_join(uuid, text)', 'public.team_update(uuid, jsonb)', 'public.league_final_status(uuid)',
    'public.league_final_invite(uuid, text[])', 'public.event_alerts_get()', 'public.event_alerts_set(jsonb)',
    'public.create_event_v2(text, text, integer, integer, text, text, text, text, integer, text, text[], boolean, boolean, date, text, timestamptz, text, integer, integer, boolean, text)',
    'public.update_event_details(uuid, text, text, integer, integer, text, text, text, text, integer, text, boolean, text, integer, boolean, boolean, text)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  execute 'revoke execute on function public.team_mine(uuid, text) from public';
  execute 'grant execute on function public.team_mine(uuid, text) to anon, authenticated';
  execute 'revoke execute on function public.events_format_sync() from public, anon, authenticated';
end $$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-event-alerts') then
      perform cron.schedule('t1-event-alerts', '* * * * *',
        $c$select t1_private.event_alerts_send() where exists (select 1 from t1_private.event_alert_queue where sent_at is null and due_at <= now())$c$);
    end if;
  end if;
end $$;
