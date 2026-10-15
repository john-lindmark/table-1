-- Local stand-in for the live Supabase project (aaozhfcbvqrgkkrihkrd) as of 2026-10-06.
-- Recreates the Supabase platform pieces the migration touches (auth, realtime, pgmq, roles)
-- and the existing events core tables, so the V1 migration can be tested off-platform.

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;

create schema extensions;
create extension pgcrypto schema extensions;
create extension "uuid-ossp" schema extensions;
create extension postgis schema extensions;   -- enabled on live by 20261006115900_events_v1_extensions.sql

-- auth -------------------------------------------------------------------
create schema auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);
create function auth.uid() returns uuid language sql stable as
$$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

-- realtime (Supabase ships realtime.send; stub records calls) --------------
create schema realtime;
create table realtime.sent (topic text, event text, payload jsonb, private boolean, at timestamptz default now());
create function realtime.send(payload jsonb, event text, topic text, private boolean default true)
returns void language sql as $$ insert into realtime.sent(topic, event, payload, private) values (topic, event, payload, private) $$;

-- pgmq (Supabase ships the extension; stub keeps messages in a table) -----
create schema pgmq;
create table pgmq.messages (queue text, msg jsonb, at timestamptz default now());
create function pgmq.create(queue_name text) returns void language sql as $$ select null::void $$;
create function pgmq.send(queue_name text, msg jsonb) returns bigint language sql as
$$ insert into pgmq.messages(queue, msg) values (queue_name, msg) returning 1::bigint $$;

-- existing events core (from migrations events_core_schema .. events_enable_realtime)
create table public.events (
  id uuid primary key default gen_random_uuid(),
  short_code text unique,
  name text not null,
  format text not null default 'draft' check (format in ('draft','sealed','constructed','cube')),
  status text not null default 'setup' check (status in ('setup','seated','in_progress','completed','archived')),
  number_of_rounds int not null default 3,
  current_round int not null default 0,
  round_length_seconds int not null default 3000,
  allow_player_reporting boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.event_members (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  role text not null default 'organizer' check (role in ('owner','organizer')),
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
create table public.pods (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  name text not null default 'Pod 1',
  display_order int not null default 0
);
create table public.participants (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  pod_id uuid references public.pods(id),
  user_id uuid references auth.users(id),
  display_name text not null,
  seat int,
  status text not null default 'active' check (status in ('active','dropped')),
  dropped_in_round int,
  created_at timestamptz not null default now()
);
create table public.participant_tokens (
  participant_id uuid primary key references public.participants(id) on delete cascade,
  token text unique not null default encode(extensions.gen_random_bytes(16), 'hex'),
  created_at timestamptz not null default now()
);
create table public.rounds (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  number int not null,
  status text not null default 'pending' check (status in ('pending','active','recorded')),
  timer_duration_seconds int not null default 3000,
  timer_remaining_at_change int not null default 3000,
  timer_status text not null default 'paused' check (timer_status in ('paused','running')),
  timer_last_started_at timestamptz,
  started_at timestamptz,
  recorded_at timestamptz
);
create table public.matches (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  round_id uuid not null references public.rounds(id) on delete cascade,
  pod_id uuid references public.pods(id),
  table_number int,
  is_bye boolean not null default false,
  game_draws int not null default 0,
  intentional_draw boolean not null default false,
  status text not null default 'pending' check (status in ('pending','reported','confirmed')),
  reported_by_participant uuid references public.participants(id),
  reported_by_user uuid references auth.users(id),
  reported_at timestamptz,
  created_at timestamptz not null default now()
);
create table public.match_sides (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  participant_id uuid references public.participants(id),
  side int not null,
  game_wins int not null default 0 check (game_wins >= 0 and game_wins <= 5)
);
create table public.audit_log (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  actor_user uuid references auth.users(id),
  actor_label text,
  action text not null,
  target_type text,
  target_id uuid,
  reason text,
  before jsonb,
  after jsonb,
  at timestamptz not null default now()
);
alter table public.events enable row level security;
alter table public.event_members enable row level security;
alter table public.pods enable row level security;
alter table public.participants enable row level security;
alter table public.participant_tokens enable row level security;
alter table public.rounds enable row level security;
alter table public.matches enable row level security;
alter table public.match_sides enable row level security;
alter table public.audit_log enable row level security;

create function public.is_event_organizer(p_event_id uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.event_members m where m.event_id = p_event_id and m.user_id = auth.uid());
$$;

-- Supabase default privileges (RLS does the gating)
grant usage on schema public, extensions to anon, authenticated, service_role;
grant usage on schema auth, realtime, pgmq to anon, authenticated;
grant all on all tables in schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
grant execute on all functions in schema auth to anon, authenticated;

-- Live read policies: event data is public
create policy events_read on public.events for select to anon, authenticated using (true);
create policy pods_read on public.pods for select to anon, authenticated using (true);
create policy participants_read on public.participants for select to anon, authenticated using (true);
create policy rounds_read on public.rounds for select to anon, authenticated using (true);
create policy matches_read on public.matches for select to anon, authenticated using (true);
create policy match_sides_read on public.match_sides for select to anon, authenticated using (true);
