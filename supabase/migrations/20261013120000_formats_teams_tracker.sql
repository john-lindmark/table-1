-- Event types and formats, set/cube product, team events, life tracker sync, per-user settings.
-- Everything here is additive: existing columns and RPCs keep working for older app builds.

-- ==================================================================== a_formats
alter table public.events
  add column if not exists format_name text,
  add column if not exists format_other text,
  add column if not exists set_code text,
  add column if not exists set_name text,
  add column if not exists cube_name text,
  add column if not exists cube_url text,
  add column if not exists team_size integer;

-- The coarse `format` column stays (older builds read it) and is derived from format_name.
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
      else 'constructed' end;
  end if;
  if new.format_name not in ('team_draft', 'team_sealed') then new.team_size := null; end if;
  return new;
end $$;

create trigger events_format_sync before insert or update of format, format_name, cube_name, team_size
  on public.events for each row execute function public.events_format_sync();

-- Fill format_name for every existing event (the trigger derives it from `format`).
update public.events set format = format where format_name is null;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'events_format_name_check') then
    alter table public.events add constraint events_format_name_check check (format_name = any (array[
      'standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'premodern', 'canadian_highlander',
      'other_constructed', 'draft', 'team_draft', 'sealed', 'team_sealed']));
    alter table public.events add constraint events_team_size_check
      check ((format_name in ('team_draft', 'team_sealed')) = (team_size is not null)
             and (team_size is null or team_size in (3, 4)));
    alter table public.events add constraint events_product_check check (
      (set_code is null or set_code ~ '^[a-z0-9]{2,6}$')
      and (set_name is null or char_length(set_name) <= 80)
      and (cube_name is null or char_length(cube_name) between 1 and 80)
      and (cube_url is null or (cube_url ~ '^https://' and char_length(cube_url) <= 300))
      and (format_other is null or char_length(format_other) between 1 and 40));
  end if;
end $$;

alter table public.events
  add column if not exists event_type text generated always as
    (case when format = 'constructed' then 'constructed' else 'limited' end) stored,
  add column if not exists format_label text generated always as (
    case format_name
      when 'standard' then 'Standard' when 'pioneer' then 'Pioneer' when 'modern' then 'Modern'
      when 'legacy' then 'Legacy' when 'vintage' then 'Vintage' when 'pauper' then 'Pauper'
      when 'premodern' then 'Premodern' when 'canadian_highlander' then 'Canadian Highlander'
      when 'other_constructed' then coalesce(format_other, 'Constructed')
      when 'draft' then 'Draft' when 'team_draft' then 'Team draft'
      when 'sealed' then 'Sealed' when 'team_sealed' then 'Team sealed'
      else 'Event' end
    || case when cube_name is not null then ' · ' || cube_name
            when set_name is not null then ' · ' || set_name else '' end) stored;

-- ==================================================================== b_sets
-- Scryfall's set list, refreshed daily by the sets-sync edge function.
create table if not exists public.mtg_sets (
  code text primary key,
  name text not null,
  set_type text not null,
  released_at date,
  icon_svg_uri text,
  card_count integer,
  digital boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.mtg_sets enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'mtg_sets' and policyname = 'mtg_sets_read') then
    create policy mtg_sets_read on public.mtg_sets for select to anon, authenticated using (true);
  end if;
end $$;

create or replace function public.draftable_sets(p_query text default null, p_limit integer default 80)
returns table (code text, name text, set_type text, released_at date, icon_svg_uri text)
language sql stable set search_path = '' as $$
  select s.code, s.name, s.set_type, s.released_at, s.icon_svg_uri
    from public.mtg_sets s
   where not s.digital
     and s.set_type in ('expansion', 'core', 'masters', 'draft_innovation', 'funny')
     and (s.released_at is null or s.released_at <= current_date + 60)
     and coalesce(s.card_count, 0) >= 150
     and s.name !~* '(commander|jumpstart|timeshifts)'
     and (coalesce(trim(p_query), '') = ''
          or s.name ilike '%' || trim(p_query) || '%' or s.code = lower(trim(p_query)))
   order by s.released_at desc nulls last, s.name
   limit least(greatest(coalesce(p_limit, 80), 1), 400);
$$;
grant execute on function public.draftable_sets(text, integer) to anon, authenticated;

-- Daily refresh, through the same shared secret the live-activity function uses.
create or replace function t1_private.sync_sets()
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  select value into v_secret from t1_private.settings where name = 'live_push_secret';
  perform net.http_post(
    url := 'https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/sets-sync',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-t1-secret', v_secret),
    timeout_milliseconds := 30000);
end $$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-sets-sync') then
      perform cron.schedule('t1-sets-sync', '41 9 * * *', 'select t1_private.sync_sets()');
    end if;
  end if;
end $$;

-- ==================================================================== c_create
create or replace function public.create_event_v2(
  p_name text,
  p_format_name text,
  p_rounds integer default null,
  p_round_seconds integer default 3000,
  p_set_code text default null,
  p_set_name text default null,
  p_cube_name text default null,
  p_cube_url text default null,
  p_team_size integer default null,
  p_format_other text default null,
  p_player_names text[] default '{}'
) returns json language plpgsql security definer set search_path = '' as $$
declare
  v_team boolean := p_format_name in ('team_draft', 'team_sealed');
  v_limited boolean := p_format_name in ('draft', 'team_draft', 'sealed', 'team_sealed');
  v_set_name text;
  v_res json;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in required to create an event' using errcode = '28000'; end if;
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
    -- No set list yet: keep the name the organizer typed.
    v_set_name := left(nullif(trim(p_set_name), ''), 80);
  end if;

  v_res := public.create_event(
    p_name,
    case when not v_limited then 'constructed' when p_format_name in ('sealed', 'team_sealed') then 'sealed'
         when p_cube_name is not null then 'cube' else 'draft' end,
    coalesce(p_rounds, 3), greatest(60, coalesce(p_round_seconds, 3000)), coalesce(p_player_names, '{}'));
  v_id := (v_res->>'event_id')::uuid;

  update public.events
     set format_name = p_format_name,
         format_other = case when p_format_name = 'other_constructed' then nullif(trim(p_format_other), '') end,
         set_code = lower(p_set_code), set_name = v_set_name,
         cube_name = nullif(trim(p_cube_name), ''), cube_url = nullif(trim(p_cube_url), ''),
         team_size = case when v_team then p_team_size end
   where id = v_id;
  return v_res;
end $$;
revoke execute on function public.create_event_v2(text, text, integer, integer, text, text, text, text, integer, text, text[]) from public, anon;
grant execute on function public.create_event_v2(text, text, integer, integer, text, text, text, text, integer, text, text[]) to authenticated;

-- ==================================================================== d_teams
create table if not exists public.event_teams (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null,
  display_order integer not null,
  name text not null check (char_length(name) between 1 and 40),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (event_id, display_order)
);
alter table public.event_teams enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'event_teams' and policyname = 'event_teams_public_read') then
    create policy event_teams_public_read on public.event_teams for select using (true);
  end if;
end $$;

alter table public.participants
  add column if not exists team_id uuid,
  add column if not exists team_slot integer;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'participants_team_slot_check') then
    alter table public.participants add constraint participants_team_slot_check
      check (team_slot is null or team_slot between 1 and 4);
  end if;
end $$;
create index if not exists participants_team_idx on public.participants (team_id) where team_id is not null;

-- Teams of an event with their members, in slot order. Inactive (emptied) teams are left out.
create or replace function public.get_event_teams(p_event_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'name', t.name, 'order', t.display_order,
           'members', (select coalesce(jsonb_agg(jsonb_build_object(
                          'participant_id', p.id, 'display_name', p.display_name, 'slot', p.team_slot,
                          'user_id', p.user_id, 'status', p.status) order by p.team_slot), '[]'::jsonb)
                         from public.participants p where p.team_id = t.id)
         ) order by t.display_order), '[]'::jsonb)
    from public.event_teams t
   where t.event_id = p_event_id and t.active;
$$;
grant execute on function public.get_event_teams(uuid) to anon, authenticated;

-- p_teams: [{"name": "Team 1", "members": ["<participant id>", ...]}, ...]; member order is the slot order.
create or replace function public.set_teams(p_event_id uuid, p_teams jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_team jsonb;
  v_ord integer := 0;
  v_tid uuid;
  v_slot integer;
  v_pid uuid;
  v_seen uuid[] := '{}';
begin
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can set teams' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id for update;
  if e.team_size is null then raise exception 'This is not a team event' using errcode = '22023'; end if;
  if e.status not in ('setup', 'seated') or e.current_round > 0 then
    raise exception 'Teams are locked once round 1 is paired' using errcode = '22023';
  end if;
  if jsonb_typeof(p_teams) <> 'array' or jsonb_array_length(p_teams) > 64 then
    raise exception 'Teams must be a list' using errcode = '22023';
  end if;
  if e.format_name = 'team_draft' and jsonb_array_length(p_teams) > 2 then
    raise exception 'A team draft has two teams' using errcode = '22023';
  end if;

  update public.participants set team_id = null, team_slot = null where event_id = p_event_id and team_id is not null;
  update public.event_teams set active = false where event_id = p_event_id;

  for v_team in select value from jsonb_array_elements(p_teams) loop
    v_ord := v_ord + 1;
    if jsonb_array_length(coalesce(v_team->'members', '[]'::jsonb)) > e.team_size then
      raise exception 'Teams have % players', e.team_size using errcode = '22023';
    end if;
    insert into public.event_teams (event_id, display_order, name, active)
    values (p_event_id, v_ord, coalesce(nullif(trim(v_team->>'name'), ''), 'Team ' || v_ord), true)
    on conflict (event_id, display_order) do update set name = excluded.name, active = true
    returning id into v_tid;
    v_slot := 0;
    for v_pid in select (value #>> '{}')::uuid from jsonb_array_elements(coalesce(v_team->'members', '[]'::jsonb)) loop
      v_slot := v_slot + 1;
      if v_pid = any (v_seen) then raise exception 'A player is on two teams' using errcode = '22023'; end if;
      v_seen := v_seen || v_pid;
      update public.participants set team_id = v_tid, team_slot = v_slot
       where id = v_pid and event_id = p_event_id and status = 'active';
      if not found then raise exception 'That player is not in this event' using errcode = '22023'; end if;
    end loop;
  end loop;

  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, auth.uid(), 'event.teams_set', 'event', p_event_id, jsonb_build_object('teams', v_ord));
  return public.get_event_teams(p_event_id);
end $$;

-- Shuffle everyone active into full teams. Anyone left over stays unassigned (the organizer places them).
create or replace function public.randomize_teams(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_ids uuid[];
  v_count integer;
  v_teams integer;
  v_names text[];
  v_payload jsonb := '[]'::jsonb;
  i integer;
begin
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can set teams' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id;
  if e.team_size is null then raise exception 'This is not a team event' using errcode = '22023'; end if;
  select array_agg(id order by random()) into v_ids
    from public.participants where event_id = p_event_id and status = 'active';
  v_count := coalesce(array_length(v_ids, 1), 0);
  v_teams := v_count / e.team_size;
  if e.format_name = 'team_draft' then v_teams := least(v_teams, 2); end if;
  if v_teams < 2 then
    raise exception 'Need at least % players for two teams', 2 * e.team_size using errcode = '22023';
  end if;
  select array_agg(t.name order by t.display_order) into v_names
    from public.event_teams t where t.event_id = p_event_id;
  for i in 1 .. v_teams loop
    v_payload := v_payload || jsonb_build_array(jsonb_build_object(
      'name', coalesce(v_names[i], 'Team ' || i),
      'members', to_jsonb(v_ids[(i - 1) * e.team_size + 1 : i * e.team_size])));
  end loop;
  return public.set_teams(p_event_id, v_payload);
end $$;
revoke execute on function public.set_teams(uuid, jsonb) from public, anon;
revoke execute on function public.randomize_teams(uuid) from public, anon;
grant execute on function public.set_teams(uuid, jsonb) to authenticated;
grant execute on function public.randomize_teams(uuid) to authenticated;

-- ==================================================================== e_tracker
create table if not exists public.tracker_sessions (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null unique,
  event_id uuid not null,
  user0 uuid,
  user1 uuid,
  starting_life integer not null default 20 check (starting_life between 1 and 999),
  created_by uuid,
  created_at timestamptz not null default now()
);
create table if not exists public.tracker_ops (
  id bigint generated always as identity primary key,
  session_id uuid not null references public.tracker_sessions (id),
  client_op_id uuid not null,
  actor uuid,
  game_no integer not null check (game_no between 1 and 9),
  side smallint not null check (side in (0, 1)),
  counter text not null check (counter in ('life', 'poison', 'energy', 'experience', 'rad', 'speed')),
  delta integer not null check (delta between -999 and 999 and delta <> 0),
  tapped_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (session_id, client_op_id)
);
create index if not exists tracker_ops_session_idx on public.tracker_ops (session_id, id);
create table if not exists public.tracker_games (
  session_id uuid not null references public.tracker_sessions (id),
  game_no integer not null check (game_no between 1 and 9),
  winner_side smallint check (winner_side in (0, 1)),
  is_draw boolean not null default false,
  recorded_by uuid,
  recorded_at timestamptz not null default now(),
  primary key (session_id, game_no),
  check (is_draw = (winner_side is null))
);
alter table public.tracker_sessions enable row level security;
alter table public.tracker_ops enable row level security;
alter table public.tracker_games enable row level security;

create or replace function public.tracker_visible(p_session_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.tracker_sessions s
     where s.id = p_session_id
       and ((select auth.uid()) in (s.user0, s.user1) or public.is_event_organizer(s.event_id)));
$$;
grant execute on function public.tracker_visible(uuid) to authenticated;

do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'tracker_sessions' and policyname = 'tracker_sessions_read') then
    create policy tracker_sessions_read on public.tracker_sessions for select to authenticated
      using ((select auth.uid()) in (user0, user1) or public.is_event_organizer(event_id));
    create policy tracker_ops_read on public.tracker_ops for select to authenticated
      using (public.tracker_visible(session_id));
    create policy tracker_games_read on public.tracker_games for select to authenticated
      using (public.tracker_visible(session_id));
  end if;
end $$;

-- Live updates to both phones (RLS above decides who receives each row).
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'tracker_ops') then
    alter publication supabase_realtime add table public.tracker_ops, public.tracker_games;
  end if;
end $$;

create or replace function public.tracker_state(p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s public.tracker_sessions;
  v_uid uuid := auth.uid();
begin
  select * into s from public.tracker_sessions where id = p_session_id;
  if s.id is null or not public.tracker_visible(p_session_id) then
    raise exception 'Tracker not found' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'session_id', s.id, 'match_id', s.match_id, 'event_id', s.event_id, 'starting_life', s.starting_life,
    'my_side', case when v_uid = s.user0 then 0 when v_uid = s.user1 then 1 end,
    'names', (select jsonb_agg(coalesce(p.display_name, 'Opponent') order by ms.side)
                from public.match_sides ms left join public.participants p on p.id = ms.participant_id
               where ms.match_id = s.match_id),
    'event_name', (select e.name from public.events e where e.id = s.event_id),
    'round', (select r.number from public.matches m join public.rounds r on r.id = m.round_id where m.id = s.match_id),
    'table', (select m.table_number from public.matches m where m.id = s.match_id),
    'games', (select coalesce(jsonb_agg(jsonb_build_object('game_no', g.game_no, 'winner_side', g.winner_side,
                 'is_draw', g.is_draw, 'recorded_at', g.recorded_at) order by g.game_no), '[]'::jsonb)
                from public.tracker_games g where g.session_id = s.id),
    'ops', (select coalesce(jsonb_agg(jsonb_build_object('client_op_id', o.client_op_id, 'game_no', o.game_no,
               'side', o.side, 'counter', o.counter, 'delta', o.delta, 'tapped_at', o.tapped_at,
               'mine', o.actor = v_uid) order by o.id), '[]'::jsonb)
              from (select * from public.tracker_ops where session_id = s.id order by id desc limit 5000) o));
end $$;

-- Opens (or joins) the shared tracker for a match. Only the two players write; the organizer can watch.
create or replace function public.tracker_open(p_match_id uuid, p_starting_life integer default 20)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  m public.matches;
  v_u0 uuid;
  v_u1 uuid;
  v_sid uuid;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into m from public.matches where id = p_match_id;
  if m.id is null then raise exception 'Match not found' using errcode = 'P0002'; end if;
  if m.is_bye then raise exception 'A bye has no opponent to track' using errcode = '22023'; end if;
  select max(ms.user_id::text) filter (where ms.side = 0)::uuid, max(ms.user_id::text) filter (where ms.side = 1)::uuid
    into v_u0, v_u1 from public.match_sides ms where ms.match_id = p_match_id;
  if v_uid is distinct from v_u0 and v_uid is distinct from v_u1 and not public.is_event_organizer(m.event_id) then
    raise exception 'Only the players in this match can track it' using errcode = '42501';
  end if;
  insert into public.tracker_sessions (match_id, event_id, user0, user1, starting_life, created_by)
  values (p_match_id, m.event_id, v_u0, v_u1, least(greatest(coalesce(p_starting_life, 20), 1), 999), v_uid)
  on conflict (match_id) do nothing;
  select id into v_sid from public.tracker_sessions where match_id = p_match_id;
  return public.tracker_state(v_sid);
end $$;

-- p_ops: [{"client_op_id", "game_no", "side", "counter", "delta", "tapped_at"}]. Idempotent; replays are ignored,
-- and changes for a game that's already been recorded are ignored.
create or replace function public.tracker_push(p_session_id uuid, p_ops jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  s public.tracker_sessions;
  v_uid uuid := auth.uid();
  v_current integer;
  v_n integer;
begin
  select * into s from public.tracker_sessions where id = p_session_id;
  if s.id is null or v_uid is null or v_uid not in (coalesce(s.user0, '00000000-0000-0000-0000-000000000000'),
                                                   coalesce(s.user1, '00000000-0000-0000-0000-000000000000')) then
    raise exception 'Only the players in this match can change life totals' using errcode = '42501';
  end if;
  if jsonb_typeof(p_ops) <> 'array' or jsonb_array_length(p_ops) > 200 then
    raise exception 'Send up to 200 changes at a time' using errcode = '22023';
  end if;
  select coalesce(max(game_no), 0) + 1 into v_current from public.tracker_games where session_id = s.id;
  insert into public.tracker_ops (session_id, client_op_id, actor, game_no, side, counter, delta, tapped_at)
  select s.id, o.client_op_id, v_uid, o.game_no, o.side, o.counter, o.delta,
         least(greatest(coalesce(o.tapped_at, now()), now() - interval '1 day'), now() + interval '1 minute')
    from jsonb_to_recordset(p_ops) as o(client_op_id uuid, game_no integer, side smallint, counter text,
                                        delta integer, tapped_at timestamptz)
   where o.game_no = v_current and o.delta <> 0
  on conflict (session_id, client_op_id) do nothing;
  get diagnostics v_n = row_count;
  return jsonb_build_object('inserted', v_n, 'game_no', v_current);
end $$;

-- Records who won a game (after the player confirmed it in the app). Same result twice is a no-op.
create or replace function public.tracker_record_game(p_session_id uuid, p_game_no integer, p_winner_side integer,
                                                      p_draw boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  s public.tracker_sessions;
  v_uid uuid := auth.uid();
  g public.tracker_games;
  v_next integer;
begin
  select * into s from public.tracker_sessions where id = p_session_id for update;
  if s.id is null or v_uid is null or v_uid not in (coalesce(s.user0, '00000000-0000-0000-0000-000000000000'),
                                                   coalesce(s.user1, '00000000-0000-0000-0000-000000000000')) then
    raise exception 'Only the players in this match can record games' using errcode = '42501';
  end if;
  if not coalesce(p_draw, false) and p_winner_side not in (0, 1) then
    raise exception 'Pick who won' using errcode = '22023';
  end if;
  select * into g from public.tracker_games where session_id = s.id and game_no = p_game_no;
  if g.session_id is not null then
    if g.is_draw = coalesce(p_draw, false) and g.winner_side is not distinct from
         (case when coalesce(p_draw, false) then null else p_winner_side end) then
      return public.tracker_state(s.id);
    end if;
    raise exception 'Game % was already recorded', p_game_no using errcode = '23505';
  end if;
  select coalesce(max(game_no), 0) + 1 into v_next from public.tracker_games where session_id = s.id;
  if p_game_no <> v_next then raise exception 'Record game % first', v_next using errcode = '22023'; end if;
  if v_next > 5 then raise exception 'A match has at most 5 games' using errcode = '22023'; end if;
  insert into public.tracker_games (session_id, game_no, winner_side, is_draw, recorded_by)
  values (s.id, p_game_no, case when coalesce(p_draw, false) then null else p_winner_side end, coalesce(p_draw, false), v_uid);
  return public.tracker_state(s.id);
end $$;

revoke execute on function public.tracker_state(uuid) from public, anon;
revoke execute on function public.tracker_open(uuid, integer) from public, anon;
revoke execute on function public.tracker_push(uuid, jsonb) from public, anon;
revoke execute on function public.tracker_record_game(uuid, integer, integer, boolean) from public, anon;
grant execute on function public.tracker_state(uuid) to authenticated;
grant execute on function public.tracker_open(uuid, integer) to authenticated;
grant execute on function public.tracker_push(uuid, jsonb) to authenticated;
grant execute on function public.tracker_record_game(uuid, integer, integer, boolean) to authenticated;

-- ==================================================================== f_settings
create table if not exists public.user_settings (
  user_id uuid primary key,
  tracker_mode text not null default 'elsewhere' check (tracker_mode in ('elsewhere', 'tracker')),
  updated_at timestamptz not null default now()
);
alter table public.user_settings enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'user_settings' and policyname = 'user_settings_own') then
    create policy user_settings_own on public.user_settings for all to authenticated
      using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
  end if;
end $$;
grant select, insert, update on public.user_settings to authenticated;

-- ==================================================================== g_home
-- Events home now carries the format label and team size.
create or replace function public.events_home(p_include_demo boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_events jsonb;
  v_invites jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;

  with links as (
    select em.event_id, true as org, false as play from public.event_members em where em.user_id = v_uid
    union all
    select p.event_id, false, true from public.participants p where p.user_id = v_uid
  ), mine as (
    select l.event_id, bool_or(l.org) as organizing, bool_or(l.play) as playing
      from links l group by l.event_id
  ), evs as (
    select e.*, mine.organizing, mine.playing,
           case when e.status in ('seated', 'in_progress') then 'live'
                when e.status = 'setup' then 'upcoming' else 'past' end as bucket,
           (select r from public.rounds r where r.event_id = e.id and r.status = 'active'
             order by r.number desc limit 1) as open_round
      from mine join public.events e on e.id = mine.event_id
     where p_include_demo or not e.is_demo
  ), ranked as (
    select evs.*, row_number() over (partition by bucket
             order by case when bucket = 'past' then coalesce(cancelled_at, updated_at) end desc nulls last,
                      case when bucket <> 'past' then coalesce(starts_at, created_at) end asc nulls last) as n
      from evs
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'name', x.name, 'short_code', x.short_code, 'format', x.format, 'status', x.status,
           'format_name', x.format_name, 'format_label', x.format_label, 'event_type', x.event_type,
           'team_size', x.team_size,
           'bucket', x.bucket, 'organizing', x.organizing, 'playing', x.playing,
           'venue_name', x.venue_name, 'starts_at', x.starts_at, 'created_at', x.created_at,
           'number_of_rounds', x.number_of_rounds, 'current_round', x.current_round,
           'round_length_seconds', x.round_length_seconds, 'is_demo', x.is_demo,
           'cancelled_at', x.cancelled_at, 'cancel_reason', x.cancel_reason,
           'players', (select count(*) from public.participants p where p.event_id = x.id and p.status = 'active'),
           'my_status', (select p.status from public.participants p where p.event_id = x.id and p.user_id = v_uid),
           'round', case when (x.open_round).id is null then null else jsonb_build_object(
               'number', (x.open_round).number,
               'timer_status', (x.open_round).timer_status,
               'duration_seconds', (x.open_round).timer_duration_seconds,
               'ends_at', case when (x.open_round).timer_status = 'running' and (x.open_round).timer_last_started_at is not null
                               then (x.open_round).timer_last_started_at
                                    + make_interval(secs => (x.open_round).timer_remaining_at_change) end,
               'remaining_seconds', case when (x.open_round).timer_status = 'paused'
                                         then (x.open_round).timer_remaining_at_change end,
               'results_in', (select count(*) from public.matches m
                               where m.round_id = (x.open_round).id and not m.is_bye and m.status <> 'pending'),
               'matches', (select count(*) from public.matches m
                            where m.round_id = (x.open_round).id and not m.is_bye),
               'disputed', (select count(*) from public.matches m
                             where m.round_id = (x.open_round).id and m.disputed and m.status = 'reported')) end
         ) order by case x.bucket when 'live' then 0 when 'upcoming' then 1 else 2 end, x.n), '[]'::jsonb)
    into v_events
    from ranked x
   where x.bucket <> 'past' or x.n <= 50;

  select coalesce(jsonb_agg(jsonb_build_object(
           'event_id', e.id, 'name', e.name, 'format', e.format, 'format_label', e.format_label, 'status', e.status,
           'venue_name', e.venue_name, 'starts_at', e.starts_at, 'source', i.source,
           'invited_by', (select coalesce(nullif(pr.handle, ''), pr.display_name) from public.profiles pr where pr.id = i.invited_by),
           'players', (select count(*) from public.participants p where p.event_id = e.id and p.status = 'active'),
           'is_demo', e.is_demo, 'created_at', i.created_at
         ) order by i.created_at desc), '[]'::jsonb)
    into v_invites
    from public.event_invites i join public.events e on e.id = i.event_id
   where i.user_id = v_uid and i.status = 'pending'
     and e.status in ('setup', 'seated', 'in_progress')
     and (p_include_demo or not e.is_demo);

  return jsonb_build_object('events', v_events, 'invites', v_invites);
end $$;
