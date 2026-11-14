-- Public events, kept final places, leagues with seasons and standings, and a rating board per format
-- (contract/public-events-leagues-2026-11-13.md; plan table-1-context/docs/plan-public-events-leagues-2026-11-13.md;
-- John 2026-11-13: "Let's start to put together public events and associated leagues and leaderboards").
--
--   a  events: visibility `public` and `friends`, description, venue address; the format key events are listed and
--      rated under
--   b  event_listing_set / event_about / find_events (the Events tab's list of events you can find, with filters)
--   c  event_placements: where each player finished, written by events-engine when an event completes
--   d  leagues, seasons, league events, follows
--   e  season standings (worked out from the kept places on every read) and qualification
--   f  league RPCs
--   g  league notifications
--   h  format ratings and boards
--   i  moderation checks for the new text
--   j  grants
--
-- Every table is RPC-only: RLS on, no policy, no client grant.

-- ==================================================================== a_events
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.events'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%visibility%' and pg_get_constraintdef(oid) like '%link_only%' loop
    execute format('alter table public.events drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.events add constraint events_visibility_check
  check (visibility in ('public', 'friends', 'nearby', 'link_only', 'private'));
-- Who can find an event (John, 2026-11-13: "events can be created with private, friends, and public visibilty"):
--   public     listed for everyone
--   friends    listed for the organizers' friends
--   nearby     found only by people at the venue (as before)
--   link_only  not listed: QR, code, link or invitation (what Create calls Private)
--   private    invitation only; the link opens for nobody else (as before)
-- Listing is about finding. A friends event's link still opens for whoever has it, as a link_only event's does.

alter table public.events
  add column if not exists description text,
  add column if not exists venue_address text;
alter table public.events drop constraint if exists events_listing_text_check;
alter table public.events add constraint events_listing_text_check check (
  (description is null or char_length(description) between 1 and 2000)
  and (venue_address is null or char_length(venue_address) between 1 and 200));

create index if not exists events_listed_idx on public.events (starts_at) where visibility in ('public', 'friends') and not is_demo;

-- The key an event is listed and rated under: each constructed format by name, `limited` (draft and sealed with a
-- set), `cube` (cube drafts and rotos), `other` (a constructed format we don't name).
create or replace function t1_private.event_format_key(p_format_name text, p_cube_name text)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_format_name in ('standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'premodern',
                           'canadian_highlander') then p_format_name
    when p_format_name = 'roto' then 'cube'
    when p_format_name in ('draft', 'team_draft', 'sealed', 'team_sealed') then
      case when p_cube_name is not null then 'cube' else 'limited' end
    else 'other' end;
$$;

create or replace function t1_private.format_key_label(p_key text)
returns text language sql immutable set search_path = '' as $$
  select case p_key
    when 'standard' then 'Standard' when 'pioneer' then 'Pioneer' when 'modern' then 'Modern'
    when 'legacy' then 'Legacy' when 'vintage' then 'Vintage' when 'pauper' then 'Pauper'
    when 'premodern' then 'Premodern' when 'canadian_highlander' then 'Canadian Highlander'
    when 'limited' then 'Limited' when 'cube' then 'Cube' else 'Other' end;
$$;

-- ==================================================================== d_tables (before b: the listing names leagues)
create table if not exists public.leagues (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$'),
  name text not null check (char_length(name) between 2 and 60),
  description text check (description is null or char_length(description) between 1 and 2000),
  region text check (region is null or char_length(region) between 1 and 80),
  link text check (link is null or (link ~ '^https://' and char_length(link) <= 300)),
  created_by uuid not null references auth.users (id),
  is_demo boolean not null default false,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.league_members (
  league_id uuid not null references public.leagues (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null default 'organizer' check (role in ('owner', 'organizer')),
  created_at timestamptz not null default now(),
  primary key (league_id, user_id)
);
create index if not exists league_members_user_idx on public.league_members (user_id);

-- points: {"places": [{"through": 2, "points": 10}, …], "participation": 1, "match_win": 0}
-- qualify: {"winners": true, "pass_down": true, "top": 10}
create table if not exists public.league_seasons (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  starts_on date not null,
  ends_on date not null,
  points jsonb not null,
  best_n integer check (best_n is null or best_n between 1 and 50),
  qualify jsonb not null default '{}'::jsonb,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  check (ends_on >= starts_on),
  unique (league_id, name)
);

-- An event is in at most one season. `final` marks the season's final (championship): it earns no points.
create table if not exists public.league_events (
  event_id uuid primary key references public.events (id) on delete cascade,
  season_id uuid not null references public.league_seasons (id) on delete cascade,
  league_id uuid not null references public.leagues (id) on delete cascade,
  multiplier numeric(3, 1) not null default 1 check (multiplier between 1 and 5 and multiplier * 2 = floor(multiplier * 2)),
  final boolean not null default false,
  added_by uuid,
  added_at timestamptz not null default now(),
  announced_at timestamptz,
  results_sent_at timestamptz
);
create index if not exists league_events_season_idx on public.league_events (season_id);
create index if not exists league_events_league_idx on public.league_events (league_id);

-- `auto`: followed for you because you played a season event. Unfollowing keeps the row with notify off and
-- following false, so playing again doesn't follow you back.
create table if not exists public.league_follows (
  user_id uuid not null references auth.users (id) on delete cascade,
  league_id uuid not null references public.leagues (id) on delete cascade,
  following boolean not null default true,
  notify boolean not null default true,
  auto boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (user_id, league_id)
);
create index if not exists league_follows_league_idx on public.league_follows (league_id) where following;

-- Who a season has told they qualified, so each hears it once.
create table if not exists t1_private.league_qualified (
  season_id uuid not null references public.league_seasons (id) on delete cascade,
  key text not null,
  how text not null,
  at timestamptz not null default now(),
  primary key (season_id, key)
);

-- ==================================================================== c_placements
-- Where each player finished: a copy of what the engine's standings say once the event is over (the team's place for
-- team events). Rebuildable; never an input to standings.
create table if not exists public.event_placements (
  event_id uuid not null references public.events (id) on delete cascade,
  participant_id uuid not null references public.participants (id) on delete cascade,
  user_id uuid,
  name text not null,
  place integer not null check (place >= 1),
  match_points integer not null default 0,
  match_wins integer not null default 0,
  match_losses integer not null default 0,
  match_draws integer not null default 0,
  playoff text,
  team_id uuid,
  computed_at timestamptz not null default now(),
  primary key (event_id, participant_id)
);
create index if not exists event_placements_user_idx on public.event_placements (user_id) where user_id is not null;

create table if not exists t1_private.placement_jobs (
  event_id uuid primary key references public.events (id) on delete cascade,
  asked_at timestamptz not null default now(),
  tries integer not null default 1,
  done_at timestamptz
);

-- Ask events-engine for an event's final places (once per event per transaction). Never fails the write that asks.
create or replace function t1_private.placements_kick(p_event_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_done text := coalesce(current_setting('t1.placements_kicked', true), '');
begin
  if p_event_id is null or position(p_event_id::text in v_done) > 0 then return; end if;
  if not exists (select 1 from public.events e
                  where e.id = p_event_id and e.status in ('completed', 'archived') and not e.is_demo) then
    return;
  end if;
  perform set_config('t1.placements_kicked', v_done || p_event_id::text || ',', true);
  insert into t1_private.placement_jobs (event_id) values (p_event_id)
  on conflict (event_id) do update set asked_at = now(), tries = 1, done_at = null;
  perform t1_private.insights_post('events-engine', jsonb_build_object('action', 'placements', 'event_id', p_event_id));
exception when others then
  raise warning 'placements_kick skipped: %', sqlerrm;
end $$;

create or replace function t1_private.placements_event_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform t1_private.placements_kick(new.id);
  return null;
end $$;
drop trigger if exists events_placements on public.events;
create trigger events_placements
  after update of status on public.events
  for each row when (new.status = 'completed' and old.status is distinct from new.status)
  execute function t1_private.placements_event_trg();

-- A result corrected after the event finished: the places are asked for again.
create or replace function t1_private.placements_match_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_event uuid;
begin
  if tg_table_name = 'matches' then v_event := new.event_id;
  else select m.event_id into v_event from public.matches m where m.id = new.match_id;
  end if;
  if exists (select 1 from t1_private.placement_jobs j where j.event_id = v_event) then
    perform t1_private.placements_kick(v_event);
  end if;
  return null;
exception when others then
  raise warning 'placements_match_trg skipped: %', sqlerrm;
  return null;
end $$;
drop trigger if exists matches_placements on public.matches;
create trigger matches_placements
  after update of status, game_draws, intentional_draw on public.matches
  for each row execute function t1_private.placements_match_trg();
drop trigger if exists match_sides_placements on public.match_sides;
create trigger match_sides_placements
  after update of game_wins on public.match_sides
  for each row execute function t1_private.placements_match_trg();

-- Asks again for places that never arrived (a refused boot, a timeout): after 2 minutes, five tries.
create or replace function t1_private.placements_sweep()
returns integer language plpgsql security definer set search_path = '' as $$
declare j record; v_n integer := 0;
begin
  for j in select event_id from t1_private.placement_jobs
            where done_at is null and asked_at < now() - interval '2 minutes' and tries < 5
            order by asked_at limit 10 loop
    update t1_private.placement_jobs set asked_at = now(), tries = tries + 1 where event_id = j.event_id;
    perform t1_private.insights_post('events-engine', jsonb_build_object('action', 'placements', 'event_id', j.event_id));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- ==================================================================== b_listing
-- Organizers describe and list an event. p_patch keys (each optional): description, venue_address (null or '' clears),
-- find (`public`: listed for everyone; `friends`: for the organizers' friends; `private`: not listed, link only),
-- lat + lng (where it is, for "near you").
create or replace function public.event_listing_set(p_event_id uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  v_before jsonb;
  v_desc text;
  v_addr text;
  v_vis text;
  v_lat double precision;
  v_lng double precision;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'Say what to change' using errcode = '22023';
  end if;
  select * into e from public.events where id = p_event_id for update;
  if e.id is null or not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can change this' using errcode = '42501';
  end if;
  if e.status = 'cancelled' then raise exception 'That event was cancelled' using errcode = '22023'; end if;
  v_before := jsonb_build_object('description', e.description, 'venue_address', e.venue_address, 'visibility', e.visibility);
  v_desc := e.description; v_addr := e.venue_address; v_vis := e.visibility;

  if p_patch ? 'description' then
    v_desc := nullif(btrim(p_patch->>'description'), '');
    if char_length(v_desc) > 2000 then raise exception 'Keep the description under 2,000 characters' using errcode = '22023'; end if;
  end if;
  if p_patch ? 'venue_address' then
    v_addr := nullif(btrim(regexp_replace(p_patch->>'venue_address', '\s+', ' ', 'g')), '');
    if char_length(v_addr) > 200 then raise exception 'Keep the address under 200 characters' using errcode = '22023'; end if;
  end if;
  if p_patch ? 'find' then
    if coalesce(p_patch->>'find', '') not in ('public', 'friends', 'private') then
      raise exception 'find is public, friends or private' using errcode = '22023';
    end if;
    if p_patch->>'find' = 'private' then
      -- Unlists it. An event that was never listed keeps its own setting (nearby, or invitation only).
      if e.visibility in ('public', 'friends') then v_vis := 'link_only'; end if;
    else
      if e.is_demo then raise exception 'Demo events can''t be listed' using errcode = '22023'; end if;
      if t1_private.is_restricted(v_uid) then raise exception 'Your account can''t list events right now' using errcode = '42501'; end if;
      v_vis := p_patch->>'find';
    end if;
  end if;
  if p_patch ? 'lat' or p_patch ? 'lng' then
    v_lat := (p_patch->>'lat')::double precision; v_lng := (p_patch->>'lng')::double precision;
    if v_lat is null or v_lng is null or v_lat not between -90 and 90 or v_lng not between -180 and 180 then
      raise exception 'Invalid coordinates' using errcode = '22023';
    end if;
    insert into public.event_locations (event_id, location, geohash6)
    values (p_event_id, extensions.st_setsrid(extensions.st_makepoint(v_lng, v_lat), 4326)::extensions.geography,
            extensions.st_geohash(extensions.st_setsrid(extensions.st_makepoint(v_lng, v_lat), 4326), 6))
    on conflict (event_id) do update
      set location = excluded.location, geohash6 = excluded.geohash6, updated_at = now();
  end if;

  if (v_desc, v_addr, v_vis) is distinct from (e.description, e.venue_address, e.visibility) then
    update public.events set description = v_desc, venue_address = v_addr, visibility = v_vis, updated_at = now()
     where id = p_event_id;
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
    values (p_event_id, v_uid, 'event.listing_updated', 'event', p_event_id, v_before,
            jsonb_build_object('description', v_desc, 'venue_address', v_addr, 'visibility', v_vis));
  end if;
  return jsonb_build_object('description', v_desc, 'venue_address', v_addr, 'visibility', v_vis);
end $$;

-- The league an event is in, as the listing and the event page show it.
create or replace function t1_private.event_league_json(p_event_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', l.id, 'slug', l.slug, 'name', l.name, 'season_id', s.id, 'season', s.name,
                            'multiplier', le.multiplier, 'final', le.final)
    from public.league_events le
    join public.leagues l on l.id = le.league_id and l.archived_at is null
    join public.league_seasons s on s.id = le.season_id
   where le.event_id = p_event_id;
$$;

-- What the event page adds for anyone who can open the event: description, address, league, format key.
create or replace function public.event_about(p_event_id uuid, p_token text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare e public.events;
begin
  if t1_private.event_access(p_event_id, p_token) = 'none' then
    raise exception 'That event isn''t available' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id;
  return jsonb_build_object(
    'event_id', e.id, 'description', e.description, 'venue_address', e.venue_address, 'visibility', e.visibility,
    'format_key', t1_private.event_format_key(e.format_name, e.cube_name),
    'league', t1_private.event_league_json(e.id),
    'placed', exists (select 1 from public.event_placements pl where pl.event_id = e.id));
end $$;

-- The events you can find: public ones, and friends-only ones run by a friend of yours (or by you). Soonest first.
-- Signed out: public only. p_filters (each optional), the same choices as Companion's event search:
--   formats  [format keys]         q       text in the name, venue, address or league (2+ characters)
--   lat, lng (never stored), km    from, to  when it starts (default: from 2 days ago, so running events show)
--   team     true | false          league  true | false (in a league or not)
--   open     true: sign-up still open with a seat left
--   scope    all (default) | public | friends
create or replace function public.find_events(p_filters jsonb default '{}'::jsonb, p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  f jsonb := coalesce(p_filters, '{}'::jsonb);
  v_here extensions.geography;
  v_lat double precision; v_lng double precision; v_km integer;
  v_formats text[]; v_q text; v_from timestamptz; v_to timestamptz;
  v_team boolean; v_league boolean; v_open boolean; v_scope text;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  if jsonb_typeof(f) <> 'object' then raise exception 'Filters are an object' using errcode = '22023'; end if;
  begin
    v_lat := (f->>'lat')::double precision; v_lng := (f->>'lng')::double precision; v_km := (f->>'km')::integer;
    v_from := (f->>'from')::timestamptz; v_to := (f->>'to')::timestamptz;
    v_team := (f->>'team')::boolean; v_league := (f->>'league')::boolean; v_open := (f->>'open')::boolean;
    if jsonb_typeof(f->'formats') = 'array' then
      v_formats := array(select jsonb_array_elements_text(f->'formats'));
    end if;
  exception when others then
    raise exception 'Check the filters' using errcode = '22023';
  end;
  v_q := lower(btrim(coalesce(f->>'q', '')));
  v_scope := coalesce(f->>'scope', 'all');
  if v_scope not in ('all', 'public', 'friends') then raise exception 'scope is all, public or friends' using errcode = '22023'; end if;
  if v_lat is not null and v_lng is not null then
    if v_lat not between -90 and 90 or v_lng not between -180 and 180 then
      raise exception 'Invalid coordinates' using errcode = '22023';
    end if;
    v_here := extensions.st_setsrid(extensions.st_makepoint(v_lng, v_lat), 4326)::extensions.geography;
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) - 'sort_at' order by x.sort_at, lower(x.name), x.event_id)
      from (
        select e.id as event_id, e.name, t1_private.event_format_key(e.format_name, e.cube_name) as format_key,
               e.format_label, e.set_name, e.cube_name, e.team_size, e.status, e.current_round, e.starts_at,
               e.venue_name, e.venue_address, e.capacity, e.top_cut, e.visibility, n.players,
               (select p.display_name from public.profiles p where p.id = e.created_by and p.deleted_at is null) as organizer,
               e.description is not null as has_description,
               case when v_here is not null and loc.location is not null
                    then greatest(1, round(extensions.st_distance(loc.location, v_here) / 1000.0))::integer end as km,
               t1_private.event_league_json(e.id) as league,
               case when v_uid is null then null
                    when exists (select 1 from public.event_members m where m.event_id = e.id and m.user_id = v_uid) then 'organizer'
                    when exists (select 1 from public.participants p where p.event_id = e.id and p.user_id = v_uid) then 'player'
                    when exists (select 1 from public.event_waitlist w where w.event_id = e.id and w.user_id = v_uid) then 'waitlisted'
               end as me,
               coalesce(e.starts_at, e.created_at) as sort_at
          from public.events e
          left join public.event_locations loc on loc.event_id = e.id
          cross join lateral (select count(*)::integer as players from public.participants p
                               where p.event_id = e.id and p.status = 'active') n
         where not e.is_demo and e.status in ('setup', 'seated', 'in_progress')
           and (e.visibility = 'public'
                or (e.visibility = 'friends' and v_uid is not null and exists (
                      select 1 from public.event_members m
                       where m.event_id = e.id
                         and (m.user_id = v_uid or exists (
                               select 1 from public.friendships fr
                                where fr.status = 'accepted' and fr.user_lo = least(m.user_id, v_uid)
                                  and fr.user_hi = greatest(m.user_id, v_uid))))))
           and (v_scope = 'all' or e.visibility = v_scope)
           and coalesce(e.starts_at, e.created_at) > coalesce(v_from, now() - interval '2 days')
           and (v_to is null or coalesce(e.starts_at, e.created_at) < v_to)
           and (v_formats is null or cardinality(v_formats) = 0
                or t1_private.event_format_key(e.format_name, e.cube_name) = any (v_formats))
           and (v_km is null or v_here is null
                or (loc.location is not null and extensions.st_dwithin(loc.location, v_here, v_km * 1000.0)))
           and (v_team is null or (e.team_size is not null) = v_team)
           and (v_league is null or exists (select 1 from public.league_events le where le.event_id = e.id) = v_league)
           and (v_open is not true or (e.status = 'setup' and (e.capacity is null or n.players < e.capacity)))
           and (char_length(v_q) < 2
                or position(v_q in lower(e.name)) > 0 or position(v_q in lower(coalesce(e.venue_name, ''))) > 0
                or position(v_q in lower(coalesce(e.venue_address, ''))) > 0
                or exists (select 1 from public.league_events le join public.leagues l on l.id = le.league_id
                            where le.event_id = e.id and position(v_q in lower(l.name)) > 0))
           and (v_uid is null or not exists (
                 select 1 from public.user_blocks b
                  where (b.user_id = e.created_by and b.blocked_id = v_uid)
                     or (b.user_id = v_uid and b.blocked_id = e.created_by)))
         order by coalesce(e.starts_at, e.created_at), lower(e.name), e.id
         limit v_limit) x), '[]'::jsonb);
end $$;

-- ==================================================================== e_standings
-- Normalizes a points rule or refuses it. Brackets: `through` rising, at most 16 of them.
create or replace function t1_private.league_points_clean(p jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  b jsonb; v_last integer := 0; v_through integer; v_points integer; v_out jsonb := '[]'::jsonb;
  v_part integer; v_win integer;
begin
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'Points need a rule' using errcode = '22023'; end if;
  if jsonb_typeof(coalesce(p->'places', '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p->'places', '[]'::jsonb)) > 16 then
    raise exception 'Up to 16 place brackets' using errcode = '22023';
  end if;
  for b in select * from jsonb_array_elements(coalesce(p->'places', '[]'::jsonb)) loop
    v_through := (b->>'through')::integer; v_points := (b->>'points')::integer;
    if v_through is null or v_points is null or v_through <= v_last or v_through > 512 or v_points not between 0 and 1000 then
      raise exception 'Place brackets go up, with 0 to 1,000 points each' using errcode = '22023';
    end if;
    v_last := v_through;
    v_out := v_out || jsonb_build_object('through', v_through, 'points', v_points);
  end loop;
  v_part := coalesce((p->>'participation')::integer, 0);
  v_win := coalesce((p->>'match_win')::integer, 0);
  if v_part not between 0 and 100 or v_win not between 0 and 20 then
    raise exception 'Participation is 0 to 100 points, a match win 0 to 20' using errcode = '22023';
  end if;
  if jsonb_array_length(v_out) = 0 and v_part = 0 and v_win = 0 then
    raise exception 'The rule gives no points' using errcode = '22023';
  end if;
  return jsonb_build_object('places', v_out, 'participation', v_part, 'match_win', v_win);
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception 'Points are whole numbers' using errcode = '22023';
end $$;

create or replace function t1_private.league_qualify_clean(p jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare v_top integer;
begin
  if p is null or jsonb_typeof(p) <> 'object' then return jsonb_build_object('winners', false, 'pass_down', true, 'top', 0); end if;
  v_top := coalesce((p->>'top')::integer, 0);
  if v_top not between 0 and 64 then raise exception 'Top 0 to 64 qualify on points' using errcode = '22023'; end if;
  return jsonb_build_object('winners', coalesce((p->>'winners')::boolean, false),
                            'pass_down', coalesce((p->>'pass_down')::boolean, true), 'top', v_top);
exception when invalid_text_representation then
  raise exception 'Qualification needs winners (true or false) and top (a number)' using errcode = '22023';
end $$;

-- Points for a final place: the first bracket that reaches it, else participation.
create or replace function t1_private.league_place_points(p_rule jsonb, p_place integer)
returns integer language sql immutable set search_path = '' as $$
  select coalesce(
    (select (b->>'points')::integer from jsonb_array_elements(p_rule->'places') b
      where (b->>'through')::integer >= p_place order by (b->>'through')::integer limit 1),
    coalesce((p_rule->>'participation')::integer, 0));
$$;

-- One row per player per finished season event. key: the account, or `g:<name>` for a guest (guests merge by name
-- within a league). counted: inside the season's best N.
create or replace function t1_private.league_points_rows(p_season_id uuid)
returns table (event_id uuid, at timestamptz, key text, user_id uuid, name text, place integer, match_wins integer,
               points integer, counted boolean)
language sql stable security definer set search_path = '' as $$
  with ev as (
    select le.event_id, le.multiplier, s.points as rule, s.best_n, coalesce(e.starts_at, e.updated_at) as at
      from public.league_events le
      join public.league_seasons s on s.id = le.season_id
      join public.events e on e.id = le.event_id
     where le.season_id = p_season_id and not le.final and e.status in ('completed', 'archived') and not e.is_demo),
  r as (
    select ev.event_id, ev.at, ev.best_n,
           coalesce(pl.user_id::text, 'g:' || lower(regexp_replace(btrim(pl.name), '\s+', ' ', 'g'))) as key,
           pl.user_id, pl.name, pl.place, pl.match_wins,
           round(ev.multiplier * (t1_private.league_place_points(ev.rule, pl.place)
                                  + coalesce((ev.rule->>'match_win')::integer, 0) * pl.match_wins))::integer as points
      from ev join public.event_placements pl on pl.event_id = ev.event_id)
  select r.event_id, r.at, r.key, r.user_id, r.name, r.place, r.match_wins, r.points,
         r.best_n is null or row_number() over (partition by r.key order by r.points desc, r.place, r.at, r.event_id) <= r.best_n
    from r;
$$;

-- Who qualified by winning: each event's best-placed player not already qualified by an earlier event (inside its
-- top 8 with pass_down, else only its winner). Everyone at that place qualifies, so a winning team goes together.
create or replace function t1_private.league_winners(p_season_id uuid)
returns table (key text, event_id uuid)
language plpgsql stable security definer set search_path = '' as $$
declare
  q jsonb;
  r record;
  v_keys text[] := '{}';
  v_event uuid;
  v_taken integer;
  v_reach integer;
begin
  select s.qualify into q from public.league_seasons s where s.id = p_season_id;
  if not coalesce((q->>'winners')::boolean, false) then return; end if;
  v_reach := case when coalesce((q->>'pass_down')::boolean, true) then 8 else 1 end;
  for r in select x.event_id, x.key, x.place from t1_private.league_points_rows(p_season_id) x
            order by x.at, x.event_id, x.place, x.key loop
    if v_event is distinct from r.event_id then v_event := r.event_id; v_taken := null; end if;
    continue when r.place > v_reach or r.key = any (v_keys);
    if v_taken is null then v_taken := r.place; end if;
    if r.place = v_taken then
      v_keys := v_keys || r.key;
      key := r.key; event_id := r.event_id;
      return next;
    end if;
  end loop;
end $$;

-- The season's standings. Order: points, then best finish, second best, and so on (a finish beats none), then name.
create or replace function t1_private.league_table(p_season_id uuid)
returns table (key text, user_id uuid, name text, points integer, events integer, wins integer, best integer,
               finishes integer[], qualified text, rank integer, ord integer)
language sql stable security definer set search_path = '' as $$
  with rows as (select * from t1_private.league_points_rows(p_season_id)),
  agg as (
    select r.key, (array_agg(r.user_id))[1] as user_id,
           coalesce(sum(r.points) filter (where r.counted), 0)::integer as points, count(*)::integer as events,
           count(*) filter (where r.place = 1)::integer as wins,
           array_agg(r.place order by r.place) as finishes,
           (array_agg(r.name order by r.at desc))[1] as last_name
      from rows r group by r.key),
  mx as (select coalesce(max(cardinality(a.finishes)), 0) as n from agg a),
  named as (
    select a.*, coalesce(p.display_name, a.last_name) as name,
           a.finishes || array_fill(100000, array[mx.n - cardinality(a.finishes)]) as pad
      from agg a cross join mx
      left join public.profiles p on p.id = a.user_id),
  w as (select lw.key from t1_private.league_winners(p_season_id) lw),
  ranked as (
    select n.*, exists (select 1 from w where w.key = n.key) as won,
           rank() over (order by n.points desc, n.pad)::integer as rank,
           row_number() over (order by n.points desc, n.pad, lower(n.name), n.key)::integer as ord
      from named n),
  q as (
    select r.*, row_number() over (partition by r.won order by r.ord) as among
      from ranked r)
  select q.key, q.user_id, q.name, q.points, q.events, q.wins, q.finishes[1], q.finishes,
         case when q.won then 'winner'
              when q.among <= coalesce((select (s.qualify->>'top')::integer from public.league_seasons s where s.id = p_season_id), 0)
              then 'points' end,
         q.rank, q.ord
    from q;
$$;

-- ==================================================================== f_league_rpcs
create or replace function t1_private.league_role(p_league_id uuid, p_user_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select m.role from public.league_members m where m.league_id = p_league_id and m.user_id = p_user_id;
$$;

create or replace function t1_private.season_state(s public.league_seasons)
returns text language sql stable set search_path = '' as $$
  select case when s.closed_at is not null or current_date > s.ends_on then 'over'
              when current_date < s.starts_on then 'upcoming' else 'active' end;
$$;

create or replace function t1_private.season_json(s public.league_seasons)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('id', s.id, 'name', s.name, 'starts_on', s.starts_on, 'ends_on', s.ends_on,
                            'state', t1_private.season_state(s), 'points', s.points, 'best_n', s.best_n,
                            'qualify', s.qualify, 'closed', s.closed_at is not null);
$$;

create or replace function t1_private.league_json(l public.leagues)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', l.id, 'slug', l.slug, 'name', l.name, 'description', l.description,
                            'region', l.region, 'link', l.link, 'archived', l.archived_at is not null,
                            'organizers', coalesce((
                              select jsonb_agg(p.display_name order by (m.role = 'owner') desc, m.created_at)
                                from public.league_members m join public.profiles p on p.id = m.user_id
                               where m.league_id = l.id and p.deleted_at is null), '[]'::jsonb));
$$;

create or replace function t1_private.league_slug(p_name text)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  v_base text := btrim(left(regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '-', 'g'), 34), '-');
  v_slug text;
  v_n integer := 1;
begin
  if char_length(v_base) < 3 then v_base := btrim('league-' || v_base, '-'); end if;
  v_slug := v_base;
  while v_slug in ('new', 'mine', 'find', 'leagues') or exists (select 1 from public.leagues l where l.slug = v_slug) loop
    v_n := v_n + 1;
    v_slug := v_base || '-' || v_n;
  end loop;
  return v_slug;
end $$;

-- Make a league. You become its owner. Three leagues an account.
create or replace function public.league_create(
  p_name text, p_description text default null, p_region text default null, p_link text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  l public.leagues;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if t1_private.is_restricted(v_uid) then raise exception 'Your account can''t make leagues right now' using errcode = '42501'; end if;
  if char_length(v_name) not between 2 and 60 then raise exception 'Name the league (2 to 60 characters)' using errcode = '22023'; end if;
  if (select count(*) from public.league_members m join public.leagues x on x.id = m.league_id
       where m.user_id = v_uid and m.role = 'owner' and x.archived_at is null) >= 3 then
    raise exception 'You own 3 leagues. Archive one first.' using errcode = '53400';
  end if;
  if p_link is not null and btrim(p_link) <> '' and (btrim(p_link) !~ '^https://' or char_length(btrim(p_link)) > 300) then
    raise exception 'The link starts with https://' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_description, ''))) > 2000 or char_length(btrim(coalesce(p_region, ''))) > 80 then
    raise exception 'Keep the description under 2,000 characters and the region under 80' using errcode = '22023';
  end if;
  insert into public.leagues (slug, name, description, region, link, created_by, is_demo)
  values (t1_private.league_slug(v_name), v_name, nullif(btrim(p_description), ''), nullif(btrim(p_region), ''),
          nullif(btrim(p_link), ''), v_uid,
          coalesce((select p.is_demo from public.profiles p where p.id = v_uid), false))
  returning * into l;
  insert into public.league_members (league_id, user_id, role) values (l.id, v_uid, 'owner');
  insert into public.account_audit (actor, action, target_id, after)
  values (v_uid, 'league.created', l.id, jsonb_build_object('name', l.name, 'slug', l.slug));
  return t1_private.league_json(l);
end $$;

-- Change a league. p_patch keys: name, description, region, link, archived (owner only).
create or replace function public.league_update(p_league_id uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  l public.leagues;
  n public.leagues;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  v_role := t1_private.league_role(p_league_id, v_uid);
  if v_role is null then raise exception 'Only the league''s organizers can change it' using errcode = '42501'; end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception 'Say what to change' using errcode = '22023'; end if;
  select * into l from public.leagues where id = p_league_id for update;
  n := l;
  if p_patch ? 'name' then
    n.name := btrim(regexp_replace(coalesce(p_patch->>'name', ''), '\s+', ' ', 'g'));
    if char_length(n.name) not between 2 and 60 then raise exception 'Name the league (2 to 60 characters)' using errcode = '22023'; end if;
  end if;
  if p_patch ? 'description' then
    n.description := nullif(btrim(p_patch->>'description'), '');
    if char_length(n.description) > 2000 then raise exception 'Keep the description under 2,000 characters' using errcode = '22023'; end if;
  end if;
  if p_patch ? 'region' then
    n.region := nullif(btrim(p_patch->>'region'), '');
    if char_length(n.region) > 80 then raise exception 'Keep the region under 80 characters' using errcode = '22023'; end if;
  end if;
  if p_patch ? 'link' then
    n.link := nullif(btrim(p_patch->>'link'), '');
    if n.link is not null and (n.link !~ '^https://' or char_length(n.link) > 300) then
      raise exception 'The link starts with https://' using errcode = '22023';
    end if;
  end if;
  if p_patch ? 'archived' then
    if v_role <> 'owner' then raise exception 'Only the owner can archive a league' using errcode = '42501'; end if;
    n.archived_at := case when (p_patch->>'archived')::boolean then coalesce(l.archived_at, now()) end;
  end if;
  update public.leagues set name = n.name, description = n.description, region = n.region, link = n.link,
                            archived_at = n.archived_at, updated_at = now()
   where id = p_league_id returning * into n;
  insert into public.account_audit (actor, action, target_id, before, after)
  values (v_uid, 'league.updated', p_league_id,
          jsonb_build_object('name', l.name, 'description', l.description, 'region', l.region, 'link', l.link, 'archived', l.archived_at is not null),
          jsonb_build_object('name', n.name, 'description', n.description, 'region', n.region, 'link', n.link, 'archived', n.archived_at is not null));
  return t1_private.league_json(n);
end $$;

-- The owner adds an organizer, changes a role, or removes one (p_role null). A league always keeps an owner.
create or replace function public.league_member_set(p_league_id uuid, p_user_id uuid, p_role text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_before text;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if t1_private.league_role(p_league_id, v_uid) is distinct from 'owner' then
    raise exception 'Only the owner can change who runs a league' using errcode = '42501';
  end if;
  if p_role is not null and p_role not in ('owner', 'organizer') then raise exception 'Unknown role' using errcode = '22023'; end if;
  if not exists (select 1 from public.profiles p where p.id = p_user_id and p.deleted_at is null) then
    raise exception 'That person isn''t on Table 1' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.user_blocks b
              where (b.user_id = p_user_id and b.blocked_id = v_uid) or (b.user_id = v_uid and b.blocked_id = p_user_id)) then
    raise exception 'That person isn''t available' using errcode = '42501';
  end if;
  v_before := t1_private.league_role(p_league_id, p_user_id);
  if v_before = 'owner' and p_role is distinct from 'owner'
     and (select count(*) from public.league_members m where m.league_id = p_league_id and m.role = 'owner') <= 1 then
    raise exception 'A league keeps an owner. Make someone else the owner first.' using errcode = '22023';
  end if;
  if p_role is null then
    delete from public.league_members where league_id = p_league_id and user_id = p_user_id;
  else
    if v_before is null and (select count(*) from public.league_members m where m.league_id = p_league_id) >= 20 then
      raise exception 'A league has up to 20 organizers' using errcode = '53400';
    end if;
    insert into public.league_members (league_id, user_id, role) values (p_league_id, p_user_id, p_role)
    on conflict (league_id, user_id) do update set role = excluded.role;
  end if;
  if v_before is distinct from p_role then
    insert into public.account_audit (actor, action, target_user, target_id, before, after)
    values (v_uid, 'league.member', p_user_id, p_league_id, jsonb_build_object('role', v_before), jsonb_build_object('role', p_role));
  end if;
  return jsonb_build_object('user_id', p_user_id, 'role', p_role);
end $$;

-- Add a season (p_season_id null) or change one. p_patch keys: name, starts_on, ends_on, points, best_n, qualify,
-- closed. A new season needs name, starts_on, ends_on and points.
create or replace function public.league_season_set(p_league_id uuid, p_season_id uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  s public.league_seasons;
  n public.league_seasons;
  v_was_closed boolean;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if t1_private.league_role(p_league_id, v_uid) is null then
    raise exception 'Only the league''s organizers can change its seasons' using errcode = '42501';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception 'Say what to change' using errcode = '22023'; end if;
  if p_season_id is not null then
    select * into s from public.league_seasons where id = p_season_id and league_id = p_league_id for update;
    if s.id is null then raise exception 'That season isn''t in this league' using errcode = 'P0002'; end if;
  elsif (select count(*) from public.league_seasons x where x.league_id = p_league_id) >= 40 then
    raise exception 'A league has up to 40 seasons' using errcode = '53400';
  end if;
  n := s;
  v_was_closed := s.closed_at is not null;
  begin
    if p_patch ? 'name' then n.name := btrim(regexp_replace(coalesce(p_patch->>'name', ''), '\s+', ' ', 'g')); end if;
    if p_patch ? 'starts_on' then n.starts_on := (p_patch->>'starts_on')::date; end if;
    if p_patch ? 'ends_on' then n.ends_on := (p_patch->>'ends_on')::date; end if;
    if p_patch ? 'best_n' then n.best_n := (p_patch->>'best_n')::integer; end if;
    if p_patch ? 'closed' then n.closed_at := case when (p_patch->>'closed')::boolean then coalesce(s.closed_at, now()) end; end if;
  exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
    raise exception 'Check the dates and numbers' using errcode = '22023';
  end;
  if p_patch ? 'points' then n.points := t1_private.league_points_clean(p_patch->'points'); end if;
  if p_patch ? 'qualify' then n.qualify := t1_private.league_qualify_clean(p_patch->'qualify'); end if;
  if n.qualify is null then n.qualify := t1_private.league_qualify_clean(null); end if;
  if n.name is null or char_length(n.name) not between 1 and 40 then raise exception 'Name the season (up to 40 characters)' using errcode = '22023'; end if;
  if n.starts_on is null or n.ends_on is null or n.ends_on < n.starts_on or n.ends_on - n.starts_on > 1100 then
    raise exception 'A season needs a start and an end, at most three years apart' using errcode = '22023';
  end if;
  if n.points is null then raise exception 'Points need a rule' using errcode = '22023'; end if;
  if n.best_n is not null and n.best_n not between 1 and 50 then raise exception 'Best 1 to 50 results' using errcode = '22023'; end if;
  if exists (select 1 from public.league_seasons x
              where x.league_id = p_league_id and lower(x.name) = lower(n.name) and x.id is distinct from p_season_id) then
    raise exception 'This league has a season with that name' using errcode = '23505';
  end if;
  if p_season_id is null then
    insert into public.league_seasons (league_id, name, starts_on, ends_on, points, best_n, qualify)
    values (p_league_id, n.name, n.starts_on, n.ends_on, n.points, n.best_n, n.qualify) returning * into n;
  else
    update public.league_seasons set name = n.name, starts_on = n.starts_on, ends_on = n.ends_on, points = n.points,
                                     best_n = n.best_n, qualify = n.qualify, closed_at = n.closed_at
     where id = p_season_id returning * into n;
  end if;
  insert into public.account_audit (actor, action, target_id, before, after)
  values (v_uid, case when p_season_id is null then 'league.season_created' else 'league.season_updated' end, n.id,
          case when p_season_id is not null then t1_private.season_json(s) end, t1_private.season_json(n));
  if n.closed_at is not null and not v_was_closed then perform t1_private.league_season_closed(n.id); end if;
  return t1_private.season_json(n);
end $$;

-- Put an event in a season (or take it out: p_season_id null). The caller runs both the event and the league.
create or replace function public.league_event_set(
  p_event_id uuid, p_season_id uuid, p_multiplier numeric default 1, p_final boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  s public.league_seasons;
  le public.league_events;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into e from public.events where id = p_event_id for update;
  if e.id is null or not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can change this' using errcode = '42501';
  end if;
  select * into le from public.league_events where event_id = p_event_id;
  if p_season_id is null then
    if le.event_id is null then return jsonb_build_object('league', null); end if;
    if t1_private.league_role(le.league_id, v_uid) is null then
      raise exception 'Only the league''s organizers can take an event out' using errcode = '42501';
    end if;
    delete from public.league_events where event_id = p_event_id;
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before)
    values (p_event_id, v_uid, 'league.detached', 'event', p_event_id, jsonb_build_object('season_id', le.season_id));
    return jsonb_build_object('league', null);
  end if;
  select * into s from public.league_seasons where id = p_season_id;
  if s.id is null or t1_private.league_role(s.league_id, v_uid) is null then
    raise exception 'Only the league''s organizers can add events to it' using errcode = '42501';
  end if;
  if exists (select 1 from public.leagues l where l.id = s.league_id and l.archived_at is not null) then
    raise exception 'That league is archived' using errcode = '22023';
  end if;
  if s.closed_at is not null then raise exception 'That season is closed' using errcode = '22023'; end if;
  if e.is_demo or e.status = 'cancelled' or e.visibility = 'private' then
    raise exception 'Private, demo and cancelled events can''t be in a league' using errcode = '22023';
  end if;
  if p_multiplier is null or p_multiplier not between 1 and 5 or p_multiplier * 2 <> floor(p_multiplier * 2) then
    raise exception 'The multiplier is 1 to 5, in halves' using errcode = '22023';
  end if;
  if le.event_id is not null and le.league_id <> s.league_id and t1_private.league_role(le.league_id, v_uid) is null then
    raise exception 'That event is in another league' using errcode = '42501';
  end if;
  insert into public.league_events (event_id, season_id, league_id, multiplier, final, added_by)
  values (p_event_id, s.id, s.league_id, p_multiplier, coalesce(p_final, false), v_uid)
  on conflict (event_id) do update
    set season_id = excluded.season_id, league_id = excluded.league_id, multiplier = excluded.multiplier,
        final = excluded.final
  returning * into le;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, v_uid, 'league.attached', 'event', p_event_id,
          jsonb_build_object('season_id', s.id, 'multiplier', le.multiplier, 'final', le.final));
  -- Players already signed up follow the league from here on.
  perform t1_private.league_auto_follow(s.league_id, array(
    select p.user_id from public.participants p where p.event_id = p_event_id and p.user_id is not null));
  if e.status in ('completed', 'archived') then
    if not exists (select 1 from public.event_placements pl where pl.event_id = p_event_id) then
      perform t1_private.placements_kick(p_event_id);
    end if;
  elsif le.announced_at is null then
    perform t1_private.league_announce(p_event_id);
  end if;
  return jsonb_build_object('league', t1_private.event_league_json(p_event_id));
end $$;

-- A league page. p_league: its id or its slug. p_season_id: a season (default: the running one, else the latest
-- started, else the next). Readable signed out (names only) unless archived or demo.
create or replace function public.league_view(p_league text, p_season_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  l public.leagues;
  s public.league_seasons;
  v_role text;
  f public.league_follows;
  v_rows jsonb;
  v_me jsonb;
  v_count integer;
begin
  if p_league ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    select * into l from public.leagues where id = p_league::uuid;
  else
    select * into l from public.leagues where slug = lower(p_league);
  end if;
  v_role := t1_private.league_role(l.id, v_uid);
  if l.id is null
     or ((l.archived_at is not null or (l.is_demo and l.created_by is distinct from v_uid)) and v_role is null) then
    raise exception 'That league isn''t available' using errcode = 'P0002';
  end if;
  if p_season_id is not null then
    select * into s from public.league_seasons where id = p_season_id and league_id = l.id;
    if s.id is null then raise exception 'That season isn''t in this league' using errcode = 'P0002'; end if;
  else
    select * into s from public.league_seasons x where x.league_id = l.id
     order by case t1_private.season_state(x) when 'active' then 0 when 'over' then 1 else 2 end,
              case when t1_private.season_state(x) = 'upcoming' then x.starts_on end,
              x.starts_on desc
     limit 1;
  end if;
  if v_uid is not null then
    select * into f from public.league_follows where user_id = v_uid and league_id = l.id;
  end if;
  if s.id is not null then
    select count(*)::integer,
           coalesce(jsonb_agg(jsonb_build_object(
             'rank', t.rank, 'key', t.key, 'user_id', case when v_uid is not null then t.user_id end, 'name', t.name,
             'points', t.points, 'events', t.events, 'wins', t.wins, 'best', t.best, 'qualified', t.qualified)
             order by t.ord) filter (where t.ord <= 50), '[]'::jsonb),
           (jsonb_agg(jsonb_build_object(
             'rank', t.rank, 'key', t.key, 'name', t.name, 'points', t.points, 'events', t.events, 'wins', t.wins,
             'best', t.best, 'qualified', t.qualified)) filter (where v_uid is not null and t.user_id = v_uid))->0
      into v_count, v_rows, v_me
      from t1_private.league_table(s.id) t;
  end if;
  return jsonb_build_object(
    'league', t1_private.league_json(l),
    'me', jsonb_build_object('role', v_role, 'following', coalesce(f.following, false),
                             'notify', coalesce(f.following and f.notify, false)),
    -- Who runs it, with accounts: for the league's own organizers only (the owner removes or promotes from here).
    'members', case when v_role is not null then (
      select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'name', p.display_name, 'role', m.role)
                       order by (m.role = 'owner') desc, m.created_at, m.user_id)
        from public.league_members m join public.profiles p on p.id = m.user_id
       where m.league_id = l.id and p.deleted_at is null) end,
    'seasons', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'starts_on', x.starts_on,
                                                              'ends_on', x.ends_on, 'state', t1_private.season_state(x))
                                           order by x.starts_on desc, x.name)
                           from public.league_seasons x where x.league_id = l.id), '[]'::jsonb),
    'season', case when s.id is not null then t1_private.season_json(s) end,
    'events', case when s.id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
               'event_id', e.id, 'name', e.name, 'format_label', e.format_label,
               'format_key', t1_private.event_format_key(e.format_name, e.cube_name),
               'starts_at', e.starts_at, 'venue_name', e.venue_name, 'status', e.status,
               'multiplier', le.multiplier, 'final', le.final,
               'players', (select count(*) from public.participants p where p.event_id = e.id)::integer,
               'winner', (select string_agg(pl.name, ', ' order by pl.name) from public.event_placements pl
                           where pl.event_id = e.id and pl.place = 1 and e.status in ('completed', 'archived')))
             order by coalesce(e.starts_at, e.created_at), e.id)
        from public.league_events le join public.events e on e.id = le.event_id
       where le.season_id = s.id and e.status <> 'cancelled' and not e.is_demo), '[]'::jsonb) end,
    'standings', coalesce(v_rows, '[]'::jsonb),
    'standings_count', coalesce(v_count, 0),
    'my_row', v_me);
end $$;

-- The whole table, a page at a time.
create or replace function public.league_standings(p_season_id uuid, p_after integer default 0, p_limit integer default 100)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); l public.leagues;
begin
  select x.* into l from public.leagues x join public.league_seasons s on s.league_id = x.id where s.id = p_season_id;
  if l.id is null or ((l.archived_at is not null or (l.is_demo and l.created_by is distinct from v_uid))
                      and t1_private.league_role(l.id, v_uid) is null) then
    raise exception 'That league isn''t available' using errcode = 'P0002';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'rank', t.rank, 'key', t.key, 'user_id', case when v_uid is not null then t.user_id end, 'name', t.name,
             'points', t.points, 'events', t.events, 'wins', t.wins, 'best', t.best, 'qualified', t.qualified)
           order by t.ord)
      from t1_private.league_table(p_season_id) t
     where t.ord > greatest(coalesce(p_after, 0), 0)
       and t.ord <= greatest(coalesce(p_after, 0), 0) + least(greatest(coalesce(p_limit, 100), 1), 200)), '[]'::jsonb);
end $$;

-- One player's season, event by event.
create or replace function public.league_player(p_season_id uuid, p_key text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); l public.leagues; v_row jsonb;
begin
  select x.* into l from public.leagues x join public.league_seasons s on s.league_id = x.id where s.id = p_season_id;
  if l.id is null or ((l.archived_at is not null or (l.is_demo and l.created_by is distinct from v_uid))
                      and t1_private.league_role(l.id, v_uid) is null) then
    raise exception 'That league isn''t available' using errcode = 'P0002';
  end if;
  select jsonb_build_object('rank', t.rank, 'key', t.key, 'user_id', case when v_uid is not null then t.user_id end,
                            'name', t.name, 'points', t.points, 'events', t.events, 'wins', t.wins, 'best', t.best,
                            'qualified', t.qualified)
    into v_row from t1_private.league_table(p_season_id) t where t.key = p_key;
  if v_row is null then raise exception 'That player isn''t in this season' using errcode = 'P0002'; end if;
  return jsonb_build_object('player', v_row, 'events', coalesce((
    select jsonb_agg(jsonb_build_object('event_id', r.event_id, 'name', e.name, 'format_label', e.format_label,
                                        'starts_at', e.starts_at, 'place', r.place, 'match_wins', r.match_wins,
                                        'points', r.points, 'counted', r.counted,
                                        'players', (select count(*) from public.event_placements pl where pl.event_id = r.event_id)::integer)
                     order by r.at desc, r.event_id)
      from t1_private.league_points_rows(p_season_id) r join public.events e on e.id = r.event_id
     where r.key = p_key), '[]'::jsonb));
end $$;

-- Leagues for the Events home: the ones you run, the ones you follow, and (with p_query, 2+ characters) leagues by
-- name or region. Signed out: only the search.
create or replace function public.leagues_home(p_query text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_q text := lower(btrim(coalesce(p_query, '')));
begin
  return jsonb_build_object(
    'mine', coalesce((
      select jsonb_agg(t1_private.league_card_json(l) || jsonb_build_object('role', m.role) order by lower(l.name))
        from public.league_members m join public.leagues l on l.id = m.league_id
       where m.user_id = v_uid and l.archived_at is null), '[]'::jsonb),
    'following', coalesce((
      select jsonb_agg(t1_private.league_card_json(l) || jsonb_build_object('notify', f.notify) order by lower(l.name))
        from public.league_follows f join public.leagues l on l.id = f.league_id
       where f.user_id = v_uid and f.following and l.archived_at is null and not l.is_demo
         and not exists (select 1 from public.league_members m where m.league_id = l.id and m.user_id = v_uid)), '[]'::jsonb),
    'found', case when char_length(v_q) < 2 then '[]'::jsonb else coalesce((
      select jsonb_agg(t1_private.league_card_json(x) order by lower(x.name))
        from (select l.* from public.leagues l
               where l.archived_at is null and not l.is_demo
                 and (position(v_q in lower(l.name)) > 0 or position(v_q in lower(coalesce(l.region, ''))) > 0)
               order by lower(l.name) limit 30) x), '[]'::jsonb) end);
end $$;

create or replace function t1_private.league_card_json(l public.leagues)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', l.id, 'slug', l.slug, 'name', l.name, 'region', l.region,
    'season', (select x.name from public.league_seasons x where x.league_id = l.id
                order by case t1_private.season_state(x) when 'active' then 0 when 'over' then 1 else 2 end, x.starts_on desc limit 1),
    'next_event', (select jsonb_build_object('event_id', e.id, 'name', e.name, 'starts_at', e.starts_at, 'format_label', e.format_label)
                     from public.league_events le join public.events e on e.id = le.event_id
                    where le.league_id = l.id and e.status in ('setup', 'seated', 'in_progress') and not e.is_demo
                    order by coalesce(e.starts_at, e.created_at) limit 1));
$$;

-- Follow or unfollow a league; p_notify turns its notifications on or off (null keeps).
create or replace function public.league_follow_set(p_league_id uuid, p_follow boolean, p_notify boolean default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); f public.league_follows;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_league_id is null or p_follow is null then raise exception 'Say which league and whether to follow it' using errcode = '22023'; end if;
  if not exists (select 1 from public.leagues l where l.id = p_league_id and l.archived_at is null and not l.is_demo) then
    raise exception 'That league isn''t available' using errcode = 'P0002';
  end if;
  if p_follow and (select count(*) from public.league_follows x where x.user_id = v_uid and x.following) >= 100
     and not exists (select 1 from public.league_follows x where x.user_id = v_uid and x.league_id = p_league_id and x.following) then
    raise exception 'You''re following 100 leagues. Unfollow one first.' using errcode = '53400';
  end if;
  insert into public.league_follows as lf (user_id, league_id, following, notify, auto)
  values (v_uid, p_league_id, p_follow, p_follow and coalesce(p_notify, true), false)
  on conflict (user_id, league_id) do update
    set following = excluded.following,
        notify = excluded.following and coalesce(p_notify, case when lf.following then lf.notify else true end),
        auto = false
  returning * into f;
  insert into public.account_audit (actor, action, target_id, after)
  values (v_uid, case when p_follow then 'league.followed' else 'league.unfollowed' end, p_league_id,
          jsonb_build_object('notify', f.notify));
  return jsonb_build_object('following', f.following, 'notify', f.following and f.notify);
end $$;

-- ==================================================================== g_notifications
-- Players of a league event follow the league unless they've unfollowed it.
create or replace function t1_private.league_auto_follow(p_league_id uuid, p_user_ids uuid[])
returns void language sql security definer set search_path = '' as $$
  insert into public.league_follows (user_id, league_id, following, notify, auto)
  select distinct u, p_league_id, true, true, true
    from unnest(coalesce(p_user_ids, '{}')) u
   where u is not null and exists (select 1 from public.profiles p where p.id = u and p.deleted_at is null)
     and not exists (select 1 from public.league_members m where m.league_id = p_league_id and m.user_id = u)
  on conflict (user_id, league_id) do nothing;
$$;

create or replace function t1_private.league_participant_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_league uuid;
begin
  if new.user_id is null then return null; end if;
  select le.league_id into v_league from public.league_events le where le.event_id = new.event_id;
  if v_league is not null then perform t1_private.league_auto_follow(v_league, array[new.user_id]); end if;
  return null;
exception when others then
  raise warning 'league_participant_trg skipped: %', sqlerrm;
  return null;
end $$;
drop trigger if exists participants_league_follow on public.participants;
create trigger participants_league_follow
  after insert or update of user_id on public.participants
  for each row execute function t1_private.league_participant_trg();

-- Who hears about a league: followers with notifications on and its organizers, minus anyone in a block with p_about.
create or replace function t1_private.league_audience(p_league_id uuid, p_about uuid default null)
returns uuid[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct u.user_id), '{}')
    from (select f.user_id from public.league_follows f where f.league_id = p_league_id and f.following and f.notify
          union
          select m.user_id from public.league_members m where m.league_id = p_league_id) u
    join public.profiles p on p.id = u.user_id and p.deleted_at is null
   where p_about is null or not exists (
           select 1 from public.user_blocks b
            where (b.user_id = p_about and b.blocked_id = u.user_id) or (b.user_id = u.user_id and b.blocked_id = p_about));
$$;

-- "MMS 2026 · Modern Open · Sun 29 Mar": once per event, to the league's audience except whoever added it.
create or replace function t1_private.league_announce(p_event_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare le public.league_events; e public.events; l public.leagues; s public.league_seasons;
begin
  select * into le from public.league_events where event_id = p_event_id;
  select * into e from public.events where id = p_event_id;
  if le.event_id is null or le.announced_at is not null or e.is_demo or e.status not in ('setup', 'seated') then return; end if;
  select * into l from public.leagues where id = le.league_id;
  select * into s from public.league_seasons where id = le.season_id;
  update public.league_events set announced_at = now() where event_id = p_event_id;
  if l.is_demo or l.archived_at is not null then return; end if;
  perform public.enqueue_notification('league.event', p_event_id,
    array(select u from unnest(t1_private.league_audience(l.id, e.created_by)) u where u is distinct from le.added_by),
    jsonb_build_object('league_id', l.id, 'league_slug', l.slug, 'league_name', l.name, 'season_name', s.name,
                       'event_name', e.name, 'format_label', e.format_label, 'starts_at', e.starts_at,
                       'venue_name', e.venue_name, 'final', le.final));
exception when others then
  raise warning 'league_announce skipped: %', sqlerrm;
end $$;

-- An event's places are in: results to the league (once per event), and anyone newly qualified hears it once.
create or replace function t1_private.league_event_placed(p_event_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  le public.league_events; e public.events; l public.leagues; s public.league_seasons;
  v_winner text; v_new uuid[];
begin
  select * into le from public.league_events where event_id = p_event_id;
  if le.event_id is null then return; end if;
  select * into e from public.events where id = p_event_id;
  select * into l from public.leagues where id = le.league_id;
  select * into s from public.league_seasons where id = le.season_id;
  if e.is_demo or l.is_demo or l.archived_at is not null then return; end if;
  perform t1_private.league_auto_follow(l.id, array(
    select pl.user_id from public.event_placements pl where pl.event_id = p_event_id and pl.user_id is not null));
  if le.results_sent_at is null then
    update public.league_events set results_sent_at = now() where event_id = p_event_id;
    select string_agg(pl.name, ', ' order by pl.name) into v_winner
      from public.event_placements pl where pl.event_id = p_event_id and pl.place = 1;
    perform public.enqueue_notification('league.results', p_event_id, t1_private.league_audience(l.id, e.created_by),
      jsonb_build_object('league_id', l.id, 'league_slug', l.slug, 'league_name', l.name, 'season_id', s.id,
                         'season_name', s.name, 'event_name', e.name, 'winner', v_winner, 'final', le.final));
  end if;
  with fresh as (
    insert into t1_private.league_qualified (season_id, key, how)
    select s.id, t.key, t.qualified from t1_private.league_table(s.id) t where t.qualified = 'winner'
    on conflict (season_id, key) do nothing
    returning key)
  select array_agg(t.user_id) into v_new
    from fresh f join t1_private.league_table(s.id) t on t.key = f.key where t.user_id is not null;
  if v_new is not null then
    perform public.enqueue_notification('league.qualified', p_event_id, v_new,
      jsonb_build_object('league_id', l.id, 'league_slug', l.slug, 'league_name', l.name, 'season_id', s.id,
                         'season_name', s.name, 'how', 'winner', 'event_name', e.name));
  end if;
exception when others then
  raise warning 'league_event_placed skipped: %', sqlerrm;
end $$;

-- A season closed: final standings to the audience, and those who qualified on points hear it.
create or replace function t1_private.league_season_closed(p_season_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.league_seasons; l public.leagues; v_first text; v_new uuid[];
begin
  select * into s from public.league_seasons where id = p_season_id;
  select * into l from public.leagues where id = s.league_id;
  if l.is_demo or l.archived_at is not null then return; end if;
  select string_agg(t.name, ', ' order by t.ord) into v_first from t1_private.league_table(p_season_id) t where t.rank = 1;
  perform public.enqueue_notification('league.season', null, t1_private.league_audience(l.id),
    jsonb_build_object('league_id', l.id, 'league_slug', l.slug, 'league_name', l.name, 'season_id', s.id,
                       'season_name', s.name, 'first', v_first));
  with fresh as (
    insert into t1_private.league_qualified (season_id, key, how)
    select s.id, t.key, t.qualified from t1_private.league_table(s.id) t where t.qualified = 'points'
    on conflict (season_id, key) do nothing
    returning key)
  select array_agg(t.user_id) into v_new
    from fresh f join t1_private.league_table(s.id) t on t.key = f.key where t.user_id is not null;
  if v_new is not null then
    perform public.enqueue_notification('league.qualified', null, v_new,
      jsonb_build_object('league_id', l.id, 'league_slug', l.slug, 'league_name', l.name, 'season_id', s.id,
                         'season_name', s.name, 'how', 'points'));
  end if;
exception when others then
  raise warning 'league_season_closed skipped: %', sqlerrm;
end $$;

-- events-engine hands in an event's final places (service role). p_rows: [{participant_id, place, match_points,
-- match_wins, match_losses, match_draws, playoff, team_id}]. Names and accounts come from participants, not the caller.
create or replace function public.event_placements_put(p_event_id uuid, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e public.events; v_n integer;
begin
  select * into e from public.events where id = p_event_id for update;
  if e.id is null then raise exception 'No such event' using errcode = 'P0002'; end if;
  if e.status not in ('completed', 'archived') or e.is_demo then
    return jsonb_build_object('placed', 0, 'skipped', true);
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Rows are a list' using errcode = '22023'; end if;
  delete from public.event_placements where event_id = p_event_id;
  insert into public.event_placements (event_id, participant_id, user_id, name, place, match_points, match_wins,
                                       match_losses, match_draws, playoff, team_id)
  select p_event_id, p.id, p.user_id, btrim(regexp_replace(p.display_name, '\s+', ' ', 'g')), (r->>'place')::integer,
         coalesce((r->>'match_points')::integer, 0), coalesce((r->>'match_wins')::integer, 0),
         coalesce((r->>'match_losses')::integer, 0), coalesce((r->>'match_draws')::integer, 0),
         nullif(r->>'playoff', ''), p.team_id
    from jsonb_array_elements(p_rows) r
    join public.participants p on p.id = (r->>'participant_id')::uuid and p.event_id = p_event_id
   where (r->>'place')::integer >= 1
  on conflict (event_id, participant_id) do nothing;
  get diagnostics v_n = row_count;
  update t1_private.placement_jobs set done_at = now() where event_id = p_event_id;
  perform t1_private.league_event_placed(p_event_id);
  perform t1_private.ratings_rebuild_event(p_event_id);
  return jsonb_build_object('placed', v_n);
end $$;

-- ==================================================================== h_ratings
-- An Elo-style rating per player per format board, rebuilt from match_outcomes: a cache with nothing of its own.
create table if not exists t1_private.format_ratings (
  board text not null,
  user_id uuid not null,
  rating double precision not null,
  matches integer not null,
  wins integer not null,
  losses integer not null,
  draws integer not null,
  events integer not null,
  last_played_at timestamptz not null,
  primary key (board, user_id)
);
create index if not exists format_ratings_board_idx on t1_private.format_ratings (board, rating desc);

-- Accounts that took themselves off the boards (Sharing → Leaderboards).
create table if not exists t1_private.leaderboard_hidden (
  user_id uuid primary key references auth.users (id) on delete cascade,
  at timestamptz not null default now()
);
alter table t1_private.format_ratings enable row level security;
alter table t1_private.leaderboard_hidden enable row level security;
alter table t1_private.league_qualified enable row level security;
alter table t1_private.placement_jobs enable row level security;

-- Is this event rated? Finished, real, public or in a league, 6+ players, a format with a board.
create or replace function t1_private.event_rated_board(e public.events)
returns text language sql stable security definer set search_path = '' as $$
  select case when e.status in ('completed', 'archived') and not e.is_demo and e.format_name <> 'roto'
                   and (e.visibility = 'public' or exists (select 1 from public.league_events le where le.event_id = e.id))
                   and t1_private.event_format_key(e.format_name, e.cube_name) <> 'other'
                   and (select count(*) from public.participants p where p.event_id = e.id) >= 6
              then t1_private.event_format_key(e.format_name, e.cube_name) end;
$$;

-- Replays every rated match of a board in the order played. Start 1500; K 40 for a player's first 10 matches on the
-- board, then 24; a draw is half a win. Matches against guests and byes aren't rated.
create or replace function t1_private.ratings_rebuild(p_board text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  m record;
  ra double precision; rb double precision; na integer; nb integer;
  ea double precision; sa double precision; ka double precision; kb double precision;
  v_n integer := 0;
begin
  perform pg_advisory_xact_lock(hashtext('t1.ratings:' || p_board));
  create temporary table if not exists t1_rating_work (
    user_id uuid primary key, rating double precision not null, n integer not null, won integer not null,
    lost integer not null, drew integer not null, last_at timestamptz not null) on commit drop;
  truncate pg_temp.t1_rating_work;
  for m in
    with ev as materialized (select e.id from public.events e where t1_private.event_rated_board(e) = p_board)
    select mo.user_id as a, mo.opponent_id as b, mo.mw, mo.ml, mo.md, mo.played_at
      from public.match_outcomes mo
      join ev on ev.id = mo.event_id
     where mo.opponent_id is not null and mo.user_id < mo.opponent_id and mo.bye = 0 and not mo.is_demo
       and mo.mw + mo.ml + mo.md = 1
     order by mo.played_at, mo.match_id
  loop
    select t.rating, t.n into ra, na from pg_temp.t1_rating_work t where t.user_id = m.a;
    if not found then ra := 1500; na := 0; end if;
    select t.rating, t.n into rb, nb from pg_temp.t1_rating_work t where t.user_id = m.b;
    if not found then rb := 1500; nb := 0; end if;
    ea := 1.0 / (1.0 + power(10.0, (rb - ra) / 400.0));
    sa := case when m.mw = 1 then 1.0 when m.ml = 1 then 0.0 else 0.5 end;
    ka := case when na < 10 then 40 else 24 end;
    kb := case when nb < 10 then 40 else 24 end;
    insert into pg_temp.t1_rating_work as t (user_id, rating, n, won, lost, drew, last_at)
    values (m.a, ra + ka * (sa - ea), 1, m.mw, m.ml, m.md, m.played_at)
    on conflict (user_id) do update
      set rating = excluded.rating, n = t.n + 1, won = t.won + excluded.won, lost = t.lost + excluded.lost,
          drew = t.drew + excluded.drew, last_at = greatest(t.last_at, excluded.last_at);
    insert into pg_temp.t1_rating_work as t (user_id, rating, n, won, lost, drew, last_at)
    values (m.b, rb + kb * (ea - sa), 1, m.ml, m.mw, m.md, m.played_at)
    on conflict (user_id) do update
      set rating = excluded.rating, n = t.n + 1, won = t.won + excluded.won, lost = t.lost + excluded.lost,
          drew = t.drew + excluded.drew, last_at = greatest(t.last_at, excluded.last_at);
    v_n := v_n + 1;
  end loop;
  delete from t1_private.format_ratings where board = p_board;
  insert into t1_private.format_ratings (board, user_id, rating, matches, wins, losses, draws, events, last_played_at)
  with ev as materialized (select e.id from public.events e where t1_private.event_rated_board(e) = p_board)
  select p_board, t.user_id, t.rating, t.n, t.won, t.lost, t.drew,
         (select count(distinct mo.event_id) from public.match_outcomes mo join ev on ev.id = mo.event_id
           where mo.user_id = t.user_id and mo.opponent_id is not null and mo.bye = 0 and not mo.is_demo)::integer,
         t.last_at
    from pg_temp.t1_rating_work t;
  return v_n;
end $$;

create or replace function t1_private.ratings_rebuild_event(p_event_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_board text;
begin
  select t1_private.event_rated_board(e) into v_board from public.events e where e.id = p_event_id;
  if v_board is not null then perform t1_private.ratings_rebuild(v_board); end if;
exception when others then
  raise warning 'ratings_rebuild_event skipped: %', sqlerrm;
end $$;

create or replace function t1_private.ratings_rebuild_all()
returns integer language plpgsql security definer set search_path = '' as $$
declare b text; v_n integer := 0;
begin
  foreach b in array array['standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'premodern',
                           'canadian_highlander', 'limited', 'cube'] loop
    v_n := v_n + t1_private.ratings_rebuild(b);
  end loop;
  return v_n;
end $$;

-- Who a board lists: 10+ rated matches, one in the last 12 months, a live account that hasn't hidden itself.
create or replace function t1_private.board_rows(p_board text)
returns table (user_id uuid, name text, avatar_url text, rating integer, matches integer, wins integer,
               losses integer, draws integer, events integer, last_played_at timestamptz, rank integer, ord integer)
language sql stable security definer set search_path = '' as $$
  select r.user_id, p.display_name, p.avatar_url, round(r.rating)::integer, r.matches, r.wins, r.losses, r.draws,
         r.events, r.last_played_at,
         rank() over (order by round(r.rating) desc)::integer,
         row_number() over (order by round(r.rating) desc, r.matches desc, lower(p.display_name), r.user_id)::integer
    from t1_private.format_ratings r
    join public.profiles p on p.id = r.user_id and p.deleted_at is null and not p.is_demo
   where r.board = p_board and r.matches >= 10 and r.last_played_at > now() - interval '365 days'
     and not exists (select 1 from t1_private.leaderboard_hidden h where h.user_id = r.user_id)
     and not t1_private.is_restricted(r.user_id);
$$;

-- Your own standing on a board (null with no rated match): rating, matches, rank when listed, else why not.
create or replace function t1_private.board_me(p_board text, p_user_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
           'rating', round(r.rating)::integer, 'matches', r.matches, 'wins', r.wins, 'losses', r.losses,
           'draws', r.draws, 'events', r.events,
           'rank', (select b.rank from t1_private.board_rows(p_board) b where b.user_id = p_user_id),
           'to_go', greatest(0, 10 - r.matches))
    from t1_private.format_ratings r where r.board = p_board and r.user_id = p_user_id;
$$;

-- The boards: every format with how many it lists, and your rating on each. `listed`: whether you show on boards.
create or replace function public.format_boards()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  return jsonb_build_object(
    'listed', v_uid is not null and not exists (select 1 from t1_private.leaderboard_hidden h where h.user_id = v_uid),
    'boards', (
      select jsonb_agg(jsonb_build_object(
               'board', b.key, 'label', t1_private.format_key_label(b.key),
               'players', (select count(*) from t1_private.board_rows(b.key))::integer,
               'me', case when v_uid is not null then t1_private.board_me(b.key, v_uid) end) order by b.n)
        from unnest(array['standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'premodern',
                          'canadian_highlander', 'limited', 'cube']) with ordinality as b(key, n)));
end $$;

-- One board, a page at a time. Signed out: names only. People in a block with you aren't shown to you.
create or replace function public.format_leaderboard(p_board text, p_after integer default 0, p_limit integer default 100)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_after integer := greatest(coalesce(p_after, 0), 0);
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 200);
begin
  if t1_private.format_key_label(p_board) = 'Other' then raise exception 'No such board' using errcode = '22023'; end if;
  return jsonb_build_object(
    'board', p_board, 'label', t1_private.format_key_label(p_board),
    'count', (select count(*) from t1_private.board_rows(p_board))::integer,
    'me', case when v_uid is not null then t1_private.board_me(p_board, v_uid) end,
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'rank', b.rank, 'user_id', case when v_uid is not null then b.user_id end, 'name', b.name,
               'avatar_url', case when v_uid is not null then b.avatar_url end, 'rating', b.rating,
               'matches', b.matches, 'wins', b.wins, 'losses', b.losses, 'draws', b.draws, 'events', b.events)
             order by b.ord)
        from t1_private.board_rows(p_board) b
       where b.ord > v_after and b.ord <= v_after + v_limit
         and (v_uid is null or not exists (
               select 1 from public.user_blocks x
                where (x.user_id = v_uid and x.blocked_id = b.user_id) or (x.user_id = b.user_id and x.blocked_id = v_uid)))),
      '[]'::jsonb));
end $$;

-- Show or hide yourself on the format boards. Your matches still count for the people you played.
create or replace function public.leaderboards_listed_set(p_listed boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_n integer;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_listed is null then raise exception 'Listed is true or false' using errcode = '22023'; end if;
  if p_listed then
    delete from t1_private.leaderboard_hidden where user_id = v_uid;
  else
    insert into t1_private.leaderboard_hidden (user_id) values (v_uid) on conflict do nothing;
  end if;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into public.account_audit (actor, action, after) values (v_uid, 'leaderboards.listed', jsonb_build_object('listed', p_listed));
  end if;
  return jsonb_build_object('listed', p_listed);
end $$;

-- ==================================================================== i_moderation
-- The new text others can read is checked like names are. Checks are queued and reviewed; what a block does to a
-- description or a league (clear it, unlist it) is still to add to moderation_enforce before enforce mode.
do $$
declare v_def text;
begin
  select pg_get_constraintdef(oid) into v_def from pg_constraint
   where conrelid = 'public.moderation_checks'::regclass and conname = 'moderation_checks_subject_kind_check';
  if v_def is not null and v_def not like '%league_name%' then
    v_def := replace(v_def, 'ARRAY[', 'ARRAY[''event_description''::text, ''league_name''::text, ''league_description''::text, ');
    alter table public.moderation_checks drop constraint moderation_checks_subject_kind_check;
    execute 'alter table public.moderation_checks add constraint moderation_checks_subject_kind_check ' || v_def;
  end if;
end $$;

create or replace function t1_private.mod_listing_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'events' then
    if new.description is not null and (tg_op = 'INSERT' or new.description is distinct from old.description) then
      perform t1_private.moderation_enqueue('event_description', new.id, new.created_by, new.description, null);
    end if;
  else
    if tg_op = 'INSERT' or new.name is distinct from old.name then
      perform t1_private.moderation_enqueue('league_name', new.id, new.created_by, new.name, null);
    end if;
    if new.description is not null and (tg_op = 'INSERT' or new.description is distinct from old.description) then
      perform t1_private.moderation_enqueue('league_description', new.id, new.created_by, new.description, null);
    end if;
  end if;
  return null;
exception when others then
  raise warning 'mod_listing_trg skipped: %', sqlerrm;
  return null;
end $$;
drop trigger if exists events_description_moderation on public.events;
create trigger events_description_moderation after insert or update of description on public.events
  for each row execute function t1_private.mod_listing_trg();
drop trigger if exists leagues_moderation on public.leagues;
create trigger leagues_moderation after insert or update of name, description on public.leagues
  for each row execute function t1_private.mod_listing_trg();

-- ==================================================================== j_grants
alter table public.leagues enable row level security;
alter table public.league_members enable row level security;
alter table public.league_seasons enable row level security;
alter table public.league_events enable row level security;
alter table public.league_follows enable row level security;
alter table public.event_placements enable row level security;
revoke all on public.leagues, public.league_members, public.league_seasons, public.league_events,
              public.league_follows, public.event_placements from anon, authenticated;

do $$
declare f text;
begin
  -- Private helpers and trigger functions: nobody but the owner.
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 't1_private' and p.proname in (
              'event_format_key', 'format_key_label', 'placements_kick', 'placements_event_trg', 'placements_match_trg',
              'placements_sweep', 'event_league_json', 'league_points_clean', 'league_qualify_clean',
              'league_place_points', 'league_points_rows', 'league_winners', 'league_table', 'league_role',
              'season_state', 'season_json', 'league_json', 'league_slug', 'league_card_json', 'league_auto_follow',
              'league_participant_trg', 'league_audience', 'league_announce', 'league_event_placed',
              'league_season_closed', 'event_rated_board', 'ratings_rebuild', 'ratings_rebuild_event',
              'ratings_rebuild_all', 'board_rows', 'board_me', 'mod_listing_trg') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
  -- Signed in only.
  foreach f in array array[
    'public.event_listing_set(uuid, jsonb)', 'public.league_create(text, text, text, text)',
    'public.league_update(uuid, jsonb)', 'public.league_member_set(uuid, uuid, text)',
    'public.league_season_set(uuid, uuid, jsonb)', 'public.league_event_set(uuid, uuid, numeric, boolean)',
    'public.league_follow_set(uuid, boolean, boolean)', 'public.leaderboards_listed_set(boolean)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  -- Readable signed out too: public listings, league pages and boards (names only).
  foreach f in array array[
    'public.event_about(uuid, text)', 'public.find_events(jsonb, integer)',
    'public.league_view(text, uuid)', 'public.league_standings(uuid, integer, integer)',
    'public.league_player(uuid, text)', 'public.leagues_home(text)', 'public.format_boards()',
    'public.format_leaderboard(text, integer, integer)'] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;
revoke execute on function public.event_placements_put(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.event_placements_put(uuid, jsonb) to service_role;

-- ==================================================================== k_cron
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-placements-sweep') then
      perform cron.schedule('t1-placements-sweep', '*/5 * * * *',
        $c$select t1_private.placements_sweep() where exists (select 1 from t1_private.placement_jobs where done_at is null and asked_at < now() - interval '2 minutes' and tries < 5)$c$);
    end if;
    if not exists (select 1 from cron.job where jobname = 't1-ratings') then
      perform cron.schedule('t1-ratings', '20 4 * * *', $c$select t1_private.ratings_rebuild_all()$c$);
    end if;
  end if;
end $$;
