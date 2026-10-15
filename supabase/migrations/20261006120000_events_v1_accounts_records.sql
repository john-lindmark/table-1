-- Table 1 Events V1: accounts, nearby join, results v2, lifetime records, head-to-head, devices.
-- Builds on events_core_schema .. events_enable_realtime (2026-09-08). All tables involved are empty today.
--
-- Invariants kept:
--   * standings are computed from results, never stored as truth
--   * matches hold sides, not player_a / player_b
--   * every result mutation writes an audit row
--   * participant_tokens stay unreadable
-- New invariants:
--   * player_records / head_to_head are a cache of match_outcomes, which is derived from match_sides;
--     rebuild_all_records() reproduces them exactly from results
--   * player coordinates are never stored; only an event's own point is, and it is never exposed to clients
--   * every client write is an RPC; clients do not write result tables directly

-- ---------------------------------------------------------------------------
-- 0. Extensions and helpers
-- ---------------------------------------------------------------------------
-- Extensions (postgis, pgmq, pg_cron) are enabled by 20261006115900_events_v1_extensions.sql.

-- Time-ordered UUIDs keep inserts at the right edge of each B-tree during a report burst.
create or replace function public.uuid_v7() returns uuid
language plpgsql volatile set search_path = '' as $$
declare
  ts bigint := floor(extract(epoch from clock_timestamp()) * 1000);
  b bytea := extensions.gen_random_bytes(16);
begin
  b := overlay(b placing substring(int8send(ts) from 3) from 1 for 6);
  b := set_byte(b, 6, (get_byte(b, 6) & 15) | 112);   -- version 7
  b := set_byte(b, 8, (get_byte(b, 8) & 63) | 128);   -- RFC 4122 variant
  return encode(b, 'hex')::uuid;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Profiles (one per account; survives account deletion as "Deleted player")
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key,                       -- = auth.users.id; no FK so deletion can scrub, not cascade
  handle text,
  display_name text not null,
  avatar_url text,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_handle_format check (handle is null or handle ~ '^[A-Za-z0-9_]{3,24}$'),
  constraint profiles_display_name_len check (char_length(display_name) between 1 and 40)
);
create unique index profiles_handle_lower_uniq on public.profiles (lower(handle)) where handle is not null;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_name text := coalesce(
    nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
    nullif(trim(new.raw_user_meta_data->>'name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'Player');
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (new.id, left(v_name, 40), new.raw_user_meta_data->>'avatar_url')
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Backfill any accounts that already exist.
insert into public.profiles (id, display_name)
select u.id, left(coalesce(nullif(split_part(coalesce(u.email, ''), '@', 1), ''), 'Player'), 40)
from auth.users u
on conflict (id) do nothing;

-- Let auth identities be deleted without losing match history.
alter table public.participants  drop constraint participants_user_id_fkey,
  add constraint participants_user_id_fkey foreign key (user_id) references public.profiles(id);
alter table public.event_members drop constraint event_members_user_id_fkey,
  add constraint event_members_user_id_fkey foreign key (user_id) references auth.users(id) on delete cascade;
alter table public.events        drop constraint events_created_by_fkey,
  add constraint events_created_by_fkey foreign key (created_by) references auth.users(id) on delete set null;
alter table public.matches       drop constraint matches_reported_by_user_fkey,
  add constraint matches_reported_by_user_fkey foreign key (reported_by_user) references auth.users(id) on delete set null;
alter table public.audit_log     drop constraint audit_log_actor_user_fkey,
  add constraint audit_log_actor_user_fkey foreign key (actor_user) references auth.users(id) on delete set null;

-- ---------------------------------------------------------------------------
-- 2. Events: location and discovery
-- ---------------------------------------------------------------------------
alter table public.events
  add column venue_name text check (venue_name is null or char_length(venue_name) <= 80),
  add column join_radius_m int not null default 150 check (join_radius_m between 25 and 2000),
  add column visibility text not null default 'link_only' check (visibility in ('nearby', 'link_only', 'private')),
  add column starts_at timestamptz,
  add column capacity int check (capacity is null or capacity between 2 and 10000),
  add column discoverable_until timestamptz,
  add column nearby_alerts_sent_at timestamptz;

-- The event's exact point lives here, readable only by security-definer functions (RLS on, no policy).
-- Kept off `events` so public `select *` reads keep working and never include coordinates.
create table public.event_locations (
  event_id uuid primary key references public.events(id) on delete cascade,
  location extensions.geography(Point, 4326) not null,
  geohash6 text not null,
  updated_at timestamptz not null default now()
);
create index event_locations_gix on public.event_locations using gist (location);
create index event_locations_cell_idx on public.event_locations (geohash6);

-- QR join secret per event (RLS on, no policy). The QR encodes short code + secret.
create table public.event_join_secrets (
  event_id uuid primary key references public.events(id) on delete cascade,
  secret text not null default encode(extensions.gen_random_bytes(12), 'hex'),
  rotated_at timestamptz not null default now()
);
insert into public.event_join_secrets (event_id) select id from public.events on conflict do nothing;

create or replace function public.events_create_join_secret() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.event_join_secrets (event_id) values (new.id) on conflict do nothing;
  return null;
end $$;
create trigger events_create_join_secret
  after insert on public.events
  for each row execute function public.events_create_join_secret();

-- Invitations: owner taps a nearby player, or a nearby alert goes out when an event opens. Join or decline.
create table public.event_invites (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  source text not null check (source in ('nearby_alert', 'owner_invite')),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  invited_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  primary key (event_id, user_id)
);
create index event_invites_user_pending_idx on public.event_invites (user_id, created_at desc) where status = 'pending';

-- Opt-in coarse presence for nearby alerts: a ~1.2 x 0.6 km geohash cell, never coordinates; stale after 3 hours.
create table public.presence_cells (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  geohash6 text not null,
  seen_at timestamptz not null default now()
);
create index presence_cells_cell_idx on public.presence_cells (geohash6, seen_at desc);

-- The 3 x 3 block of geohash-6 cells around a point (~3.6 x 1.8 km).
create or replace function public._geohash6_block(p_lat double precision, p_lng double precision) returns text[]
language sql immutable set search_path = '' as $$
  select array_agg(extensions.st_geohash(
           extensions.st_setsrid(extensions.st_makepoint(
             p_lng + dx * (360.0 / 32768), greatest(-89.99, least(89.99, p_lat + dy * (180.0 / 32768)))), 4326), 6))
    from generate_series(-1, 1) dx, generate_series(-1, 1) dy;
$$;

-- ---------------------------------------------------------------------------
-- 3. Participants, rounds, matches, sides
-- ---------------------------------------------------------------------------
create unique index participants_event_user_uniq on public.participants (event_id, user_id) where user_id is not null;
create index participants_event_status_idx on public.participants (event_id, status);

alter table public.rounds
  add column pairings_published_at timestamptz,
  add column timer_ends_at timestamptz;

alter table public.matches
  add column version int not null default 0,
  add column result_source text check (result_source in ('player', 'organizer')),
  add column disputed boolean not null default false,
  add column updated_at timestamptz not null default now();
create index matches_round_pending_idx on public.matches (round_id) where status = 'pending';
create index matches_event_updated_idx on public.matches (event_id, updated_at);
create index matches_open_reports_idx on public.matches (event_id, round_id)
  where status = 'reported' and not disputed;               -- round-end auto-confirm

alter table public.match_sides
  add column event_id uuid,
  add column user_id uuid;
update public.match_sides s set event_id = m.event_id from public.matches m where m.id = s.match_id;
update public.match_sides s set user_id = p.user_id from public.participants p where p.id = s.participant_id;
alter table public.match_sides
  alter column event_id set not null,
  add constraint match_sides_event_id_fkey foreign key (event_id) references public.events(id) on delete cascade,
  add constraint match_sides_user_id_fkey foreign key (user_id) references public.profiles(id);
create unique index match_sides_match_side_uniq on public.match_sides (match_id, side);
create index match_sides_event_participant_idx on public.match_sides (event_id, participant_id);
create index match_sides_user_idx on public.match_sides (user_id) where user_id is not null;

create index audit_log_event_at_idx on public.audit_log (event_id, at desc);
create index audit_log_actor_at_idx on public.audit_log (actor_user, at desc) where actor_user is not null;

-- Keep the denormalized partition key and account id on every side row.
create or replace function public.match_sides_fill() returns trigger
language plpgsql set search_path = '' as $$
begin
  select m.event_id into new.event_id from public.matches m where m.id = new.match_id;
  if new.participant_id is null then
    new.user_id := null;
  else
    select p.user_id into new.user_id from public.participants p where p.id = new.participant_id;
  end if;
  return new;
end $$;
create trigger match_sides_fill
  before insert or update of match_id, participant_id on public.match_sides
  for each row execute function public.match_sides_fill();

-- Every change to a match bumps its version: the client's optimistic-concurrency token and delta-sync cursor.
create or replace function public.matches_bump_version() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.version := old.version + 1;
  new.updated_at := now();
  return new;
end $$;
create trigger matches_bump_version
  before update on public.matches
  for each row execute function public.matches_bump_version();

-- ---------------------------------------------------------------------------
-- 4. Records: lifetime and head-to-head (a cache of match_outcomes)
-- ---------------------------------------------------------------------------
create table public.player_records (
  user_id uuid primary key references public.profiles(id),
  match_wins int not null default 0,
  match_losses int not null default 0,
  match_draws int not null default 0,
  byes int not null default 0,
  game_wins int not null default 0,
  game_losses int not null default 0,
  game_draws int not null default 0,
  events_played int not null default 0,
  last_played_at timestamptz,
  updated_at timestamptz not null default now()
);

create table public.head_to_head (
  user_id uuid not null references public.profiles(id),
  opponent_id uuid not null references public.profiles(id),
  match_wins int not null default 0,
  match_losses int not null default 0,
  match_draws int not null default 0,
  game_wins int not null default 0,
  game_losses int not null default 0,
  game_draws int not null default 0,
  last_played_at timestamptz,
  primary key (user_id, opponent_id),
  constraint head_to_head_not_self check (user_id <> opponent_id)
);
create index head_to_head_recent_idx on public.head_to_head (user_id, last_played_at desc);

-- What was last applied to the aggregates for each (match, account). Edits reverse the old row and apply the new.
create table public.match_outcomes (
  match_id uuid not null references public.matches(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  opponent_id uuid references public.profiles(id),
  event_id uuid not null,
  mw int not null default 0, ml int not null default 0, md int not null default 0, bye int not null default 0,
  gw int not null default 0, gl int not null default 0, gd int not null default 0,
  played_at timestamptz not null,
  primary key (match_id, user_id)
);
create index match_outcomes_user_idx on public.match_outcomes (user_id, played_at desc);

-- Final placement per event, written by complete_event (next migration).
create table public.event_results (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  final_rank int not null,
  match_points int not null,
  match_wins int not null, match_losses int not null, match_draws int not null,
  primary key (event_id, user_id)
);
create index event_results_user_idx on public.event_results (user_id);

-- Computed standings per round; a cache, rebuildable from results.
create table public.standings_snapshots (
  event_id uuid not null references public.events(id) on delete cascade,
  round_number int not null,
  standings jsonb not null,
  computed_at timestamptz not null default now(),
  primary key (event_id, round_number)
);

create or replace function public._add_outcome(
  p_user uuid, p_opp uuid, p_mw int, p_ml int, p_md int, p_bye int, p_gw int, p_gl int, p_gd int, p_at timestamptz)
returns void language plpgsql set search_path = '' as $$
begin
  insert into public.player_records as pr
    (user_id, match_wins, match_losses, match_draws, byes, game_wins, game_losses, game_draws, last_played_at)
  values (p_user, p_mw, p_ml, p_md, p_bye, p_gw, p_gl, p_gd, p_at)
  on conflict (user_id) do update set
    match_wins = pr.match_wins + excluded.match_wins,
    match_losses = pr.match_losses + excluded.match_losses,
    match_draws = pr.match_draws + excluded.match_draws,
    byes = pr.byes + excluded.byes,
    game_wins = pr.game_wins + excluded.game_wins,
    game_losses = pr.game_losses + excluded.game_losses,
    game_draws = pr.game_draws + excluded.game_draws,
    last_played_at = greatest(pr.last_played_at, excluded.last_played_at),
    updated_at = now();

  if p_opp is not null then
    insert into public.head_to_head as h
      (user_id, opponent_id, match_wins, match_losses, match_draws, game_wins, game_losses, game_draws, last_played_at)
    values (p_user, p_opp, p_mw, p_ml, p_md, p_gw, p_gl, p_gd, p_at)
    on conflict (user_id, opponent_id) do update set
      match_wins = h.match_wins + excluded.match_wins,
      match_losses = h.match_losses + excluded.match_losses,
      match_draws = h.match_draws + excluded.match_draws,
      game_wins = h.game_wins + excluded.game_wins,
      game_losses = h.game_losses + excluded.game_losses,
      game_draws = h.game_draws + excluded.game_draws,
      last_played_at = greatest(h.last_played_at, excluded.last_played_at);
  end if;
end $$;

-- Reverse whatever was applied for this match, then apply what the match says now. Idempotent.
create or replace function public.apply_match_outcomes(p_match_id uuid, p_reverse_only boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare
  m public.matches;
  r record;
begin
  for r in delete from public.match_outcomes where match_id = p_match_id returning * loop
    perform public._add_outcome(r.user_id, r.opponent_id, -r.mw, -r.ml, -r.md, -r.bye, -r.gw, -r.gl, -r.gd, null);
  end loop;

  if p_reverse_only then return; end if;
  select * into m from public.matches where id = p_match_id;
  if m.id is null or not (m.is_bye or m.status in ('reported', 'confirmed')) then return; end if;

  for r in
    select s.user_id,
           (select o.user_id from public.match_sides o
             where o.match_id = s.match_id and o.side <> s.side and o.user_id is not null
             order by o.side limit 1) as opponent_id,
           s.game_wins as gw,
           coalesce((select sum(o.game_wins) from public.match_sides o
                      where o.match_id = s.match_id and o.side <> s.side), 0)::int as gl
      from public.match_sides s
     where s.match_id = p_match_id and s.user_id is not null
  loop
    if m.is_bye then
      -- A bye is 3 match points in the event, but never a lifetime win or a head-to-head result.
      insert into public.match_outcomes (match_id, user_id, opponent_id, event_id, bye, played_at)
      values (m.id, r.user_id, null, m.event_id, 1, coalesce(m.reported_at, m.created_at));
      perform public._add_outcome(r.user_id, null, 0, 0, 0, 1, 0, 0, 0, coalesce(m.reported_at, m.created_at));
    else
      insert into public.match_outcomes (match_id, user_id, opponent_id, event_id, mw, ml, md, gw, gl, gd, played_at)
      values (m.id, r.user_id, r.opponent_id, m.event_id,
              (r.gw > r.gl)::int, (r.gw < r.gl)::int, (r.gw = r.gl)::int,
              r.gw, r.gl, m.game_draws, coalesce(m.reported_at, m.created_at));
      perform public._add_outcome(r.user_id, r.opponent_id,
              (r.gw > r.gl)::int, (r.gw < r.gl)::int, (r.gw = r.gl)::int, 0,
              r.gw, r.gl, m.game_draws, coalesce(m.reported_at, m.created_at));
    end if;
  end loop;
end $$;

-- Triggers keep records right for any write path. RPCs set t1.in_rpc and call apply once themselves.
create or replace function public.matches_records_sync() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    -- BEFORE DELETE: reverse first, then let the delete proceed (returning null would cancel it).
    perform public.apply_match_outcomes(old.id, true);
    return old;
  end if;
  if coalesce(current_setting('t1.in_rpc', true), '') = 'on' then return null; end if;
  if tg_op = 'INSERT'
     or old.status is distinct from new.status
     or old.game_draws is distinct from new.game_draws
     or old.is_bye is distinct from new.is_bye then
    -- reported -> confirmed changes nothing that counts
    if not (tg_op = 'UPDATE' and old.status = 'reported' and new.status = 'confirmed'
            and old.game_draws = new.game_draws and old.is_bye = new.is_bye) then
      perform public.apply_match_outcomes(new.id);
    end if;
  end if;
  return null;
end $$;
create trigger matches_records_sync_del
  before delete on public.matches
  for each row execute function public.matches_records_sync();
create trigger matches_records_sync
  after insert or update on public.matches
  for each row execute function public.matches_records_sync();

create or replace function public.match_sides_records_sync() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(current_setting('t1.in_rpc', true), '') = 'on' then return null; end if;
  perform public.apply_match_outcomes(new.match_id);
  return null;
end $$;
create trigger match_sides_records_sync
  after insert or update of game_wins, participant_id, user_id on public.match_sides
  for each row execute function public.match_sides_records_sync();

-- Claiming a walk-in seat (or any change of account on a participant) flows to sides, then to records.
create or replace function public.participants_user_sync() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.match_sides set user_id = new.user_id where participant_id = new.id;
  return null;
end $$;
create trigger participants_user_sync
  after update of user_id on public.participants
  for each row when (old.user_id is distinct from new.user_id)
  execute function public.participants_user_sync();

-- Full rebuild from results: the proof that records are only a cache.
create or replace function public.rebuild_all_records() returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  -- Reverse every applied outcome (per match), zero any residue, then re-apply from results.
  for r in select distinct match_id from public.match_outcomes loop
    perform public.apply_match_outcomes(r.match_id, true);
  end loop;
  update public.player_records
     set match_wins = 0, match_losses = 0, match_draws = 0, byes = 0,
         game_wins = 0, game_losses = 0, game_draws = 0, last_played_at = null, updated_at = now()
   where (match_wins, match_losses, match_draws, byes, game_wins, game_losses, game_draws) <> (0, 0, 0, 0, 0, 0, 0)
      or last_played_at is not null;
  update public.head_to_head
     set match_wins = 0, match_losses = 0, match_draws = 0, game_wins = 0, game_losses = 0, game_draws = 0
   where (match_wins, match_losses, match_draws, game_wins, game_losses, game_draws) <> (0, 0, 0, 0, 0, 0);
  for r in select id from public.matches where is_bye or status in ('reported', 'confirmed') loop
    perform public.apply_match_outcomes(r.id);
  end loop;
end $$;

-- Accounts whose cached lifetime record disagrees with their match_outcomes rows. Nightly job; expect zero rows.
create or replace function public.records_drift()
returns table (user_id uuid, cached jsonb, derived jsonb)
language sql stable security definer set search_path = '' as $$
  with d as (
    select o.user_id, sum(o.mw)::int mw, sum(o.ml)::int ml, sum(o.md)::int md, sum(o.bye)::int bye,
           sum(o.gw)::int gw, sum(o.gl)::int gl, sum(o.gd)::int gd
      from public.match_outcomes o group by o.user_id)
  select coalesce(p.user_id, d.user_id),
         jsonb_build_array(p.match_wins, p.match_losses, p.match_draws, p.byes, p.game_wins, p.game_losses, p.game_draws),
         jsonb_build_array(d.mw, d.ml, d.md, d.bye, d.gw, d.gl, d.gd)
    from public.player_records p
    full join d on d.user_id = p.user_id
   where (coalesce(p.match_wins, 0), coalesce(p.match_losses, 0), coalesce(p.match_draws, 0), coalesce(p.byes, 0),
          coalesce(p.game_wins, 0), coalesce(p.game_losses, 0), coalesce(p.game_draws, 0))
         is distinct from
         (coalesce(d.mw, 0), coalesce(d.ml, 0), coalesce(d.md, 0), coalesce(d.bye, 0),
          coalesce(d.gw, 0), coalesce(d.gl, 0), coalesce(d.gd, 0));
$$;

-- ---------------------------------------------------------------------------
-- 5. Realtime: small diffs on per-match topics (Broadcast, not Postgres Changes)
-- ---------------------------------------------------------------------------
create or replace function public.matches_broadcast() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform realtime.send(
    jsonb_build_object(
      'match_id', new.id, 'event_id', new.event_id, 'round_id', new.round_id,
      'version', new.version, 'status', new.status, 'disputed', new.disputed,
      'game_draws', new.game_draws, 'result_source', new.result_source,
      'sides', (select jsonb_agg(jsonb_build_object('side', s.side, 'participant_id', s.participant_id,
                                                    'game_wins', s.game_wins) order by s.side)
                  from public.match_sides s where s.match_id = new.id)),
    'match_changed', 'match:' || new.id::text, false);
  return null;
end $$;
create trigger matches_broadcast
  after update on public.matches
  for each row execute function public.matches_broadcast();

-- ---------------------------------------------------------------------------
-- 6. Notifications: devices, preferences, outbox
-- ---------------------------------------------------------------------------
create table public.devices (
  id uuid primary key default public.uuid_v7(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  platform text not null check (platform in ('ios', 'android', 'web')),
  push_token text not null,
  live_activity_token text,
  app_version text,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (platform, push_token)
);
create index devices_user_idx on public.devices (user_id);

create table public.notification_prefs (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  nearby_alerts boolean not null default false,       -- opt-in, asked during onboarding
  muted_kinds text[] not null default '{}',
  quiet_start time,
  quiet_end time,
  time_zone text not null default 'UTC',
  updated_at timestamptz not null default now()
);

-- One message per audience; the notify-worker expands audiences into device tokens.
create or replace function public.enqueue_notification(p_kind text, p_event_id uuid, p_user_ids uuid[], p_data jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_user_ids is null or cardinality(p_user_ids) = 0 then return; end if;
  perform pgmq.send('notify', jsonb_build_object(
    'kind', p_kind, 'event_id', p_event_id, 'user_ids', to_jsonb(p_user_ids),
    'data', coalesce(p_data, '{}'::jsonb), 'enqueued_at', now()));
end $$;

-- Idempotency keys make client retries after a dropped connection safe.
create table public.rpc_idempotency (
  key uuid primary key,
  user_id uuid not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 7. RPCs
-- ---------------------------------------------------------------------------
create or replace function public._match_sides_json(p_match_id uuid) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('side', s.side, 'game_wins', s.game_wins) order by s.side), '[]'::jsonb)
    from public.match_sides s where s.match_id = p_match_id;
$$;

create or replace function public._validate_score(p_side0 int, p_side1 int, p_draws int) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if p_side0 is null or p_side1 is null or p_draws is null
     or p_side0 < 0 or p_side1 < 0 or p_draws < 0
     or p_side0 > 2 or p_side1 > 2 or (p_side0 + p_side1 + p_draws) > 3 then
    raise exception 'That is not a valid match result' using errcode = '22023';
  end if;
end $$;

create or replace function public._rate_limit(p_action text, p_max int, p_window interval) returns void
language plpgsql set search_path = '' as $$
begin
  if (select count(*) from public.audit_log
       where actor_user = auth.uid() and action = p_action and at > now() - p_window) >= p_max then
    raise exception 'Too many requests, try again in a moment' using errcode = '53400';
  end if;
end $$;

-- Player reports (or corrects) their own match. Counts immediately; never blocks the round.
create or replace function public.report_match(
  p_match_id uuid, p_side0_wins int, p_side1_wins int, p_draws int default 0,
  p_expected_version int default null, p_idempotency_key uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  m public.matches;
  e public.events;
  v_part uuid;
  v_is_org boolean;
  v_before jsonb;
  v_same boolean;
  v_others uuid[];
  v_res jsonb;
begin
  if v_uid is null then raise exception 'Sign in to report results' using errcode = '28000'; end if;
  if p_idempotency_key is not null then
    select result into v_res from public.rpc_idempotency where key = p_idempotency_key and user_id = v_uid;
    if found then return v_res; end if;
  end if;
  perform public._validate_score(p_side0_wins, p_side1_wins, p_draws);
  perform public._rate_limit('result.reported', 10, interval '1 minute');

  select * into m from public.matches where id = p_match_id for update;
  if m.id is null then raise exception 'Match not found' using errcode = 'P0002'; end if;
  if m.is_bye then raise exception 'A bye has no result to report' using errcode = '22023'; end if;
  select * into e from public.events where id = m.event_id;
  v_is_org := exists (select 1 from public.event_members em where em.event_id = e.id and em.user_id = v_uid);
  select s.participant_id into v_part from public.match_sides s where s.match_id = m.id and s.user_id = v_uid;
  if v_part is null and not v_is_org then raise exception 'You are not playing in that match' using errcode = '42501'; end if;
  if not e.allow_player_reporting and not v_is_org then
    raise exception 'The organizer is recording results for this event' using errcode = '42501';
  end if;
  if m.status = 'confirmed' and not v_is_org then
    raise exception 'That result is final; ask the organizer to change it' using errcode = '42501';
  end if;

  v_before := jsonb_build_object('sides', public._match_sides_json(m.id), 'draws', m.game_draws, 'status', m.status);
  v_same := (select coalesce(bool_and(case s.side when 0 then s.game_wins = p_side0_wins
                                                  when 1 then s.game_wins = p_side1_wins end), false)
               from public.match_sides s where s.match_id = m.id) and m.game_draws = p_draws;
  select array_agg(s.user_id) into v_others
    from public.match_sides s where s.match_id = m.id and s.user_id is not null and s.user_id <> v_uid;

  perform set_config('t1.in_rpc', 'on', true);

  if m.status <> 'pending' and p_expected_version is not null and p_expected_version <> m.version
     and not (v_part is not null and m.reported_by_user is distinct from v_uid) then
    -- The caller edited a stale copy: return the current state instead of overwriting it.
    v_res := jsonb_build_object('ok', false, 'conflict', true, 'status', m.status, 'version', m.version,
                                'sides', public._match_sides_json(m.id), 'draws', m.game_draws);
  elsif m.status = 'reported' and v_part is not null and m.reported_by_user is distinct from v_uid then
    -- The opponent never overwrites: the same score confirms, a different score disputes.
    if v_same then
      -- The opponent entered the same score: that is a confirmation.
      update public.matches set status = 'confirmed', disputed = false where id = m.id returning * into m;
      insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
      values (m.event_id, v_uid, 'result.confirmed', 'match', m.id, v_before, v_before);
      v_res := jsonb_build_object('ok', true, 'status', 'confirmed', 'version', m.version);
    else
      -- Conflicting score: the first result stands, the organizer decides.
      update public.matches set disputed = true where id = m.id returning * into m;
      insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
      values (m.event_id, v_uid, 'result.disputed', 'match', m.id, v_before,
              jsonb_build_object('side0', p_side0_wins, 'side1', p_side1_wins, 'draws', p_draws));
      perform public.enqueue_notification('result.disputed', m.event_id,
        (select array_agg(em.user_id) from public.event_members em where em.event_id = m.event_id),
        jsonb_build_object('match_id', m.id, 'table', m.table_number));
      v_res := jsonb_build_object('ok', false, 'conflict', true, 'status', m.status, 'version', m.version,
                                  'sides', public._match_sides_json(m.id), 'draws', m.game_draws);
    end if;
  else
    update public.match_sides set game_wins = p_side0_wins where match_id = m.id and side = 0;
    update public.match_sides set game_wins = p_side1_wins where match_id = m.id and side = 1;
    update public.matches
       set game_draws = p_draws,
           status = case when v_is_org and v_part is null then 'confirmed' else 'reported' end,
           result_source = case when v_is_org and v_part is null then 'organizer' else 'player' end,
           reported_by_user = v_uid, reported_by_participant = v_part, reported_at = now(), disputed = false
     where id = m.id returning * into m;
    perform public.apply_match_outcomes(m.id);
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
    values (m.event_id, v_uid, 'result.reported', 'match', m.id, v_before,
            jsonb_build_object('side0', p_side0_wins, 'side1', p_side1_wins, 'draws', p_draws));
    perform public.enqueue_notification('result.reported', m.event_id, v_others,
      jsonb_build_object('match_id', m.id, 'side0', p_side0_wins, 'side1', p_side1_wins, 'draws', p_draws));
    v_res := jsonb_build_object('ok', true, 'status', m.status, 'version', m.version);
  end if;

  perform set_config('t1.in_rpc', '', true);
  if p_idempotency_key is not null then
    insert into public.rpc_idempotency (key, user_id, result) values (p_idempotency_key, v_uid, v_res)
    on conflict (key) do nothing;
  end if;
  return v_res;
end $$;

-- Opponent accepts or disputes a reported result.
create or replace function public.respond_to_result(p_match_id uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  m public.matches;
begin
  select * into m from public.matches where id = p_match_id for update;
  if m.id is null then raise exception 'Match not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from public.match_sides s where s.match_id = m.id and s.user_id = v_uid)
     or m.reported_by_user = v_uid then
    raise exception 'Only the opponent can respond to this result' using errcode = '42501';
  end if;
  if m.status <> 'reported' then return jsonb_build_object('ok', true, 'status', m.status, 'version', m.version); end if;

  if p_accept then
    update public.matches set status = 'confirmed', disputed = false where id = m.id returning * into m;
  else
    update public.matches set disputed = true where id = m.id returning * into m;
    perform public.enqueue_notification('result.disputed', m.event_id,
      (select array_agg(em.user_id) from public.event_members em where em.event_id = m.event_id),
      jsonb_build_object('match_id', m.id, 'table', m.table_number));
  end if;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id)
  values (m.event_id, v_uid, case when p_accept then 'result.confirmed' else 'result.disputed' end, 'match', m.id);
  return jsonb_build_object('ok', true, 'status', m.status, 'disputed', m.disputed, 'version', m.version);
end $$;

-- Owner or organizer sets any result at any time, with a reason. Final, audited, records apply the difference.
create or replace function public.set_match_result(
  p_match_id uuid, p_side0_wins int, p_side1_wins int, p_draws int default 0, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  m public.matches;
  v_before jsonb;
  v_players uuid[];
begin
  perform public._validate_score(p_side0_wins, p_side1_wins, p_draws);
  select * into m from public.matches where id = p_match_id for update;
  if m.id is null then raise exception 'Match not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from public.event_members em where em.event_id = m.event_id and em.user_id = v_uid) then
    raise exception 'Only organizers can change results' using errcode = '42501';
  end if;

  v_before := jsonb_build_object('sides', public._match_sides_json(m.id), 'draws', m.game_draws, 'status', m.status);
  perform set_config('t1.in_rpc', 'on', true);
  update public.match_sides set game_wins = p_side0_wins where match_id = m.id and side = 0;
  update public.match_sides set game_wins = p_side1_wins where match_id = m.id and side = 1;
  update public.matches
     set game_draws = p_draws, status = 'confirmed', result_source = 'organizer', disputed = false,
         reported_by_user = v_uid, reported_at = coalesce(reported_at, now())
   where id = m.id returning * into m;
  perform public.apply_match_outcomes(m.id);
  perform set_config('t1.in_rpc', '', true);

  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, reason, before, after)
  values (m.event_id, v_uid, 'result.set_by_organizer', 'match', m.id, p_reason, v_before,
          jsonb_build_object('side0', p_side0_wins, 'side1', p_side1_wins, 'draws', p_draws));

  select array_agg(s.user_id) into v_players from public.match_sides s where s.match_id = m.id and s.user_id is not null;
  perform public.enqueue_notification('result.changed', m.event_id, v_players,
    jsonb_build_object('match_id', m.id, 'before', v_before, 'side0', p_side0_wins, 'side1', p_side1_wins, 'draws', p_draws));
  return jsonb_build_object('ok', true, 'status', m.status, 'version', m.version);
end $$;

-- Reported results nobody disputed become final when their round ends: the round is marked recorded,
-- or the organizer starts a later round. Disputed matches wait for the organizer.
create or replace function public.confirm_results_through_round(p_event_id uuid, p_round_number int) returns int
language sql security definer set search_path = '' as $$
  with c as (
    update public.matches m set status = 'confirmed'
      from public.rounds r
     where r.id = m.round_id and m.event_id = p_event_id and r.number <= p_round_number
       and m.status = 'reported' and not m.disputed
    returning 1)
  select count(*)::int from c;
$$;

create or replace function public.rounds_confirm_on_end() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform public.confirm_results_through_round(new.event_id, new.number - 1);
  elsif new.status = 'recorded' and old.status is distinct from 'recorded' then
    perform public.confirm_results_through_round(new.event_id, new.number);
  end if;
  return null;
end $$;
create trigger rounds_confirm_on_end
  after insert or update of status on public.rounds
  for each row execute function public.rounds_confirm_on_end();

-- Seat an account in an event (used by nearby, QR and invite joins). Idempotent; serializes seat numbers.
create or replace function public._seat_account(p_event_id uuid, p_user_id uuid, p_via text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_pid uuid;
  v_name text;
  v_pod uuid;
  v_seat int;
begin
  select * into e from public.events where id = p_event_id;
  if e.id is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if e.status in ('completed', 'archived') then raise exception 'That event has already finished' using errcode = '22023'; end if;

  select id into v_pid from public.participants where event_id = e.id and user_id = p_user_id;
  if v_pid is not null then
    return jsonb_build_object('event_id', e.id, 'participant_id', v_pid, 'already_joined', true);
  end if;

  perform pg_advisory_xact_lock(hashtextextended(e.id::text, 0));
  if e.capacity is not null and
     (select count(*) from public.participants p where p.event_id = e.id and p.status = 'active') >= e.capacity then
    raise exception 'That event is full' using errcode = '53400';
  end if;
  select coalesce(nullif(handle, ''), display_name) into v_name from public.profiles where id = p_user_id;
  select id into v_pod from public.pods where event_id = e.id order by display_order limit 1;
  select coalesce(max(seat), 0) + 1 into v_seat from public.participants where event_id = e.id;

  insert into public.participants (event_id, pod_id, user_id, display_name, seat)
  values (e.id, v_pod, p_user_id, v_name, v_seat) returning id into v_pid;
  update public.event_invites set status = 'accepted', responded_at = now()
   where event_id = e.id and user_id = p_user_id and status = 'pending';
  insert into public.audit_log (event_id, actor_user, actor_label, action, target_type, target_id, after)
  values (e.id, p_user_id, v_name, 'participant.joined', 'participant', v_pid, jsonb_build_object('via', p_via));
  return jsonb_build_object('event_id', e.id, 'participant_id', v_pid, 'seat', v_seat, 'already_joined', false);
end $$;

-- When an event opens to nearby players, alert opted-in accounts seen in the surrounding cells within 3 hours.
-- Each gets a pending invite they can accept (join) or decline from the notification.
create or replace function public._send_nearby_alerts(p_event_id uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  l public.event_locations;
  v_users uuid[];
begin
  select * into e from public.events where id = p_event_id for update;
  select * into l from public.event_locations where event_id = p_event_id;
  if e.id is null or l.event_id is null or e.visibility <> 'nearby' or e.nearby_alerts_sent_at is not null
     or e.status not in ('setup', 'seated') then
    return 0;
  end if;

  with recipients as (
    select pc.user_id
      from public.presence_cells pc
      join public.notification_prefs np on np.user_id = pc.user_id and np.nearby_alerts
     where pc.geohash6 = any (public._geohash6_block(extensions.st_y(l.location::extensions.geometry),
                                                      extensions.st_x(l.location::extensions.geometry)))
       and pc.seen_at > now() - interval '3 hours'
       and not exists (select 1 from public.event_members em where em.event_id = e.id and em.user_id = pc.user_id)
       and not exists (select 1 from public.participants p where p.event_id = e.id and p.user_id = pc.user_id)
       and not exists (select 1 from public.event_invites i where i.event_id = e.id and i.user_id = pc.user_id)
     order by pc.seen_at desc
     limit 1000),
  ins as (
    insert into public.event_invites (event_id, user_id, source)
    select e.id, user_id, 'nearby_alert' from recipients
    returning user_id)
  select array_agg(user_id) into v_users from ins;

  update public.events set nearby_alerts_sent_at = now() where id = e.id;
  perform public.enqueue_notification('event.nearby', e.id, v_users,
    jsonb_build_object('event_name', e.name, 'venue_name', e.venue_name, 'format', e.format,
                       'actions', jsonb_build_array('join', 'decline')));
  return coalesce(cardinality(v_users), 0);
end $$;

-- Organizer pins the event to where they are standing.
create or replace function public.set_event_location(
  p_event_id uuid, p_lat double precision, p_lng double precision,
  p_venue_name text default null, p_join_radius_m int default 150, p_visibility text default 'nearby')
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can set the event location' using errcode = '42501';
  end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Invalid coordinates' using errcode = '22023';
  end if;
  insert into public.event_locations (event_id, location, geohash6)
  values (p_event_id, extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography,
          extensions.st_geohash(extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326), 6))
  on conflict (event_id) do update
    set location = excluded.location, geohash6 = excluded.geohash6, updated_at = now();
  update public.events
     set venue_name = nullif(trim(p_venue_name), ''), join_radius_m = p_join_radius_m, visibility = p_visibility,
         updated_at = now()
   where id = p_event_id;
  if p_visibility = 'nearby' then
    perform public._send_nearby_alerts(p_event_id);
  end if;
end $$;

-- Open events near the caller. Coordinates are used for this query only and never stored.
create or replace function public.nearby_events(
  p_lat double precision, p_lng double precision, p_accuracy_m int default 50, p_limit int default 20)
returns table (event_id uuid, name text, venue_name text, format text, status text,
               players int, capacity int, distance_m int, starts_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  pt extensions.geography;
begin
  if auth.uid() is null then raise exception 'Sign in to find nearby events' using errcode = '28000'; end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Invalid coordinates' using errcode = '22023';
  end if;
  pt := extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography;
  return query
  select e.id, e.name, e.venue_name, e.format, e.status,
         (select count(*) from public.participants p where p.event_id = e.id and p.status = 'active')::int,
         e.capacity,
         (round(extensions.st_distance(l.location, pt) / 50.0) * 50)::int,
         e.starts_at
    from public.event_locations l
    join public.events e on e.id = l.event_id
   where e.visibility = 'nearby' and e.status in ('setup', 'seated', 'in_progress')
     and (e.discoverable_until is null or e.discoverable_until > now())
     and extensions.st_dwithin(l.location, pt, 2100)        -- constant radius: index-assisted
     and extensions.st_distance(l.location, pt) <= e.join_radius_m + least(greatest(p_accuracy_m, 0), 100)
   order by l.location operator(extensions.<->) pt
   limit least(greatest(p_limit, 1), 50);
end $$;

-- Join an event by being there. Re-checks distance server-side; idempotent for an existing seat.
create or replace function public.join_event_nearby(
  p_event_id uuid, p_lat double precision, p_lng double precision, p_accuracy_m int default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  l public.event_locations;
begin
  if v_uid is null then raise exception 'Sign in to join' using errcode = '28000'; end if;
  perform public._rate_limit('participant.joined', 20, interval '1 minute');
  select * into e from public.events where id = p_event_id;
  select * into l from public.event_locations where event_id = p_event_id;
  if e.id is null or e.visibility <> 'nearby' or l.event_id is null then
    raise exception 'That event is not open to nearby players' using errcode = 'P0002';
  end if;
  if extensions.st_distance(l.location,
       extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography)
     > e.join_radius_m + least(greatest(p_accuracy_m, 0), 100) then
    raise exception 'You need to be at the event to join it nearby; scan the QR code instead' using errcode = '42501';
  end if;
  return public._seat_account(e.id, v_uid, 'nearby');
end $$;

-- Scan the owner's QR code: https://table-1.site/j/<short_code>?s=<secret>. Works for any visibility.
create or replace function public.join_event_qr(p_short_code text, p_secret text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_event uuid;
begin
  if v_uid is null then raise exception 'Sign in to join' using errcode = '28000'; end if;
  perform public._rate_limit('participant.joined', 20, interval '1 minute');
  select e.id into v_event
    from public.events e join public.event_join_secrets j on j.event_id = e.id
   where upper(e.short_code) = upper(trim(p_short_code)) and j.secret = p_secret;
  if v_event is null then
    raise exception 'That QR code is not valid or has been replaced; ask the organizer to show it again' using errcode = 'P0002';
  end if;
  return public._seat_account(v_event, v_uid, 'qr');
end $$;

-- The organizer's QR payload. Rotating invalidates every code shown before.
create or replace function public.get_join_qr(p_event_id uuid, p_rotate boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text;
  v_secret text;
begin
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can show the join code' using errcode = '42501';
  end if;
  if p_rotate then
    update public.event_join_secrets set secret = encode(extensions.gen_random_bytes(12), 'hex'), rotated_at = now()
     where event_id = p_event_id;
  end if;
  select e.short_code, j.secret into v_code, v_secret
    from public.events e join public.event_join_secrets j on j.event_id = e.id where e.id = p_event_id;
  return jsonb_build_object('short_code', v_code, 'secret', v_secret,
                            'url', 'https://table-1.site/j/' || v_code || '?s=' || v_secret);
end $$;

-- Organizer invites a player they can see on the Capture screen (Realtime Presence on nearby cells).
create or replace function public.invite_to_event(p_event_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.events;
begin
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can invite players' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id;
  insert into public.event_invites (event_id, user_id, source, invited_by)
  values (p_event_id, p_user_id, 'owner_invite', auth.uid())
  on conflict (event_id, user_id) do update
    set status = 'pending', source = 'owner_invite', invited_by = auth.uid(), created_at = now(), responded_at = null
    where public.event_invites.status <> 'accepted';
  perform public.enqueue_notification('event.invite', p_event_id, array[p_user_id],
    jsonb_build_object('event_name', e.name, 'venue_name', e.venue_name, 'actions', jsonb_build_array('join', 'decline')));
end $$;

-- Join or decline from the notification (or the in-app invite list).
create or replace function public.respond_to_invite(p_event_id uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  i public.event_invites;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into i from public.event_invites where event_id = p_event_id and user_id = v_uid for update;
  if i.event_id is null then raise exception 'No invitation for that event' using errcode = 'P0002'; end if;
  if not p_accept then
    update public.event_invites set status = 'declined', responded_at = now()
     where event_id = p_event_id and user_id = v_uid and status = 'pending';
    return jsonb_build_object('ok', true, 'status', 'declined');
  end if;
  if i.status = 'declined' then
    raise exception 'You declined this invitation; scan the QR code to join' using errcode = '22023';
  end if;
  return public._seat_account(p_event_id, v_uid, i.source) || jsonb_build_object('status', 'accepted');
end $$;

-- Foreground app reports where it is for nearby alerts. Only the ~1 km cell is kept; coordinates are discarded.
create or replace function public.update_presence(p_lat double precision, p_lng double precision)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Invalid coordinates' using errcode = '22023';
  end if;
  insert into public.presence_cells (user_id, geohash6, seen_at)
  values (auth.uid(), extensions.st_geohash(extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326), 6), now())
  on conflict (user_id) do update set geohash6 = excluded.geohash6, seen_at = now();
end $$;

-- A walk-in who joined by token on web signs in and takes their seat (and their history) with them.
create or replace function public.claim_participant(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  p public.participants;
begin
  if v_uid is null then raise exception 'Sign in to claim a seat' using errcode = '28000'; end if;
  select pt.* into p from public.participants pt
    join public.participant_tokens t on t.participant_id = pt.id where t.token = p_token;
  if p.id is null then raise exception 'That claim link is not valid' using errcode = 'P0002'; end if;
  if p.user_id = v_uid then return jsonb_build_object('ok', true, 'participant_id', p.id); end if;
  if p.user_id is not null then raise exception 'That seat belongs to another account' using errcode = '42501'; end if;
  if exists (select 1 from public.participants x where x.event_id = p.event_id and x.user_id = v_uid) then
    raise exception 'You already have a seat in this event' using errcode = '23505';
  end if;
  update public.participants set user_id = v_uid where id = p.id;     -- triggers flow to sides and records
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id)
  values (p.event_id, v_uid, 'participant.claimed', 'participant', p.id);
  return jsonb_build_object('ok', true, 'participant_id', p.id);
end $$;

create or replace function public.register_device(
  p_platform text, p_push_token text, p_live_activity_token text default null, p_app_version text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  insert into public.devices (user_id, platform, push_token, live_activity_token, app_version)
  values (auth.uid(), p_platform, p_push_token, p_live_activity_token, p_app_version)
  on conflict (platform, push_token) do update
    set user_id = excluded.user_id, live_activity_token = coalesce(excluded.live_activity_token, public.devices.live_activity_token),
        app_version = excluded.app_version, last_seen_at = now()
  returning id into v_id;
  return v_id;
end $$;

-- In-app account deletion (App Store 5.1.1(v)) lives in the `delete-account` edge function (service role):
-- it scrubs the profile to "Deleted player", removes devices, prefs, presence and pending invites, then deletes
-- the auth identity. Match history stays so opponents' records and head-to-head do not change.

-- ---------------------------------------------------------------------------
-- 8. RLS and grants
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.player_records enable row level security;
alter table public.head_to_head enable row level security;
alter table public.match_outcomes enable row level security;
alter table public.event_results enable row level security;
alter table public.standings_snapshots enable row level security;
alter table public.devices enable row level security;
alter table public.notification_prefs enable row level security;
alter table public.rpc_idempotency enable row level security;   -- no policy: RPC-only
alter table public.event_locations enable row level security;   -- no policy: coordinates never leave the database
alter table public.event_join_secrets enable row level security; -- no policy: organizers read via get_join_qr
alter table public.presence_cells enable row level security;    -- no policy: RPC-only
alter table public.event_invites enable row level security;

create policy profiles_read on public.profiles for select to anon, authenticated using (true);
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()) and deleted_at is null);
revoke update on public.profiles from anon, authenticated;
grant update (handle, display_name, avatar_url) on public.profiles to authenticated;

create policy player_records_read on public.player_records for select to anon, authenticated using (true);
create policy event_results_read on public.event_results for select to anon, authenticated using (true);
create policy standings_snapshots_read on public.standings_snapshots for select to anon, authenticated using (true);
create policy match_outcomes_read on public.match_outcomes for select to anon, authenticated using (true);

create policy head_to_head_read on public.head_to_head for select to anon, authenticated using (true);

create policy devices_own on public.devices for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy event_invites_own_or_organizer on public.event_invites for select to authenticated
  using (user_id = (select auth.uid()) or public.is_event_organizer(event_id));
revoke insert, update, delete on public.event_invites, public.event_locations, public.event_join_secrets,
  public.presence_cells from anon, authenticated;
create policy notification_prefs_own on public.notification_prefs for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Aggregates and outcomes are written only by security-definer functions.
revoke insert, update, delete on public.player_records, public.head_to_head, public.match_outcomes,
  public.event_results, public.standings_snapshots from anon, authenticated;

-- Functions: internal helpers are not callable by clients; RPCs are callable by signed-in users only.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.report_match(uuid, int, int, int, int, uuid),
  public.respond_to_result(uuid, boolean),
  public.set_match_result(uuid, int, int, int, text),
  public.set_event_location(uuid, double precision, double precision, text, int, text),
  public.nearby_events(double precision, double precision, int, int),
  public.join_event_nearby(uuid, double precision, double precision, int),
  public.join_event_qr(text, text),
  public.get_join_qr(uuid, boolean),
  public.invite_to_event(uuid, uuid),
  public.respond_to_invite(uuid, boolean),
  public.update_presence(double precision, double precision),
  public.claim_participant(text),
  public.register_device(text, text, text, text),
  public.uuid_v7()
  to authenticated;
-- Existing V0 RPCs keep their access (create_event: authenticated; join_event, report_result: anon walk-ins).
do $$
begin
  if to_regprocedure('public.create_event(text,text,integer,integer,text[])') is not null then
    grant execute on function public.create_event(text, text, integer, integer, text[]) to authenticated;
  end if;
  if to_regprocedure('public.join_event(text,text)') is not null then
    grant execute on function public.join_event(text, text) to anon, authenticated;
  end if;
  if to_regprocedure('public.report_result(uuid,text,integer,integer,integer)') is not null then
    grant execute on function public.report_result(uuid, text, integer, integer, integer) to anon, authenticated;
  end if;
  grant execute on function public.is_event_organizer(uuid) to anon, authenticated;   -- used by RLS policies
end $$;

-- ---------------------------------------------------------------------------
-- 9. Advisor fixes (applied live as events_v1_j_advisor_fixes)
-- ---------------------------------------------------------------------------
create index if not exists participants_user_idx on public.participants (user_id) where user_id is not null;
create index if not exists participants_pod_idx on public.participants (pod_id);
create index if not exists event_members_user_idx on public.event_members (user_id);
create index if not exists events_created_by_idx on public.events (created_by);
create index if not exists pods_event_idx on public.pods (event_id);
create index if not exists matches_pod_idx on public.matches (pod_id);
create index if not exists matches_reported_by_participant_idx on public.matches (reported_by_participant);
create index if not exists matches_reported_by_user_idx on public.matches (reported_by_user);
create index if not exists head_to_head_opponent_idx on public.head_to_head (opponent_id);
create index if not exists match_outcomes_opponent_idx on public.match_outcomes (opponent_id);
create index if not exists event_invites_invited_by_idx on public.event_invites (invited_by);
