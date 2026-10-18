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
  created_at timestamptz default now(),
  deleted_at timestamptz
);
create function auth.uid() returns uuid language sql stable as
$$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

-- realtime (Supabase ships realtime.send; stub records calls) --------------
create schema realtime;
create table realtime.sent (topic text, event text, payload jsonb, private boolean, at timestamptz default now());
create function realtime.send(payload jsonb, event text, topic text, private boolean default true)
returns void language sql as $$ insert into realtime.sent(topic, event, payload, private) values (topic, event, payload, private) $$;

create function auth.role() returns text language sql stable as
$$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon') $$;

-- pgmq (Supabase ships the extension; stub keeps messages in a table) -----
-- run.sh strips `create extension pgmq|pg_cron|pg_net` from migrations; these schemas stand in.
create schema pgmq;
create table pgmq.messages (msg_id bigserial primary key, queue text, msg jsonb, at timestamptz default now());
create function pgmq.create(queue_name text) returns void language sql as $$ select null::void $$;
create function pgmq.send(queue_name text, msg jsonb) returns bigint language sql as
$$ insert into pgmq.messages(queue, msg) values (queue_name, msg) returning msg_id $$;
create function pgmq.send(queue_name text, msg jsonb, delay integer) returns bigint language sql as
$$ insert into pgmq.messages(queue, msg) values (queue_name, msg) returning msg_id $$;
create function pgmq.read(queue_name text, vt integer, qty integer)
returns table (msg_id bigint, read_ct integer, enqueued_at timestamptz, vt timestamptz, message jsonb)
language sql as $$
  select m.msg_id, 1, m.at, now(), m.msg from pgmq.messages m where m.queue = queue_name order by m.msg_id limit qty
$$;
create function pgmq.delete(queue_name text, msg_ids bigint[]) returns setof bigint language sql as
$$ delete from pgmq.messages m where m.queue = queue_name and m.msg_id = any(msg_ids) returning m.msg_id $$;
create function pgmq.purge_queue(queue_name text) returns bigint language sql as
$$ with d as (delete from pgmq.messages m where m.queue = queue_name returning 1) select count(*)::bigint from d $$;

-- pg_cron stub: jobs are recorded, never run -------------------------------
create schema cron;
create table cron.job (jobid bigserial primary key, jobname text unique, schedule text, command text);
create function cron.schedule(job_name text, schedule text, command text) returns bigint language sql as $$
  insert into cron.job(jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command returning jobid
$$;
create function cron.unschedule(job_name text) returns boolean language sql as
$$ with d as (delete from cron.job where jobname = job_name returning 1) select exists (select 1 from d) $$;

-- pg_net stub: requests are recorded, never sent ---------------------------
create schema net;
create table net.requests (id bigserial primary key, url text, body jsonb, headers jsonb, at timestamptz default now());
create function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
  headers jsonb default '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds integer default 5000)
returns bigint language sql as $$ insert into net.requests(url, body, headers) values (url, body, headers) returning id $$;

-- storage -------------------------------------------------------------------
create schema storage;
create table storage.buckets (id text primary key, name text not null, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[], created_at timestamptz default now());
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id),
  name text, owner uuid, owner_id text, metadata jsonb, created_at timestamptz default now(), updated_at timestamptz default now());
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as
$$ select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1] $$;

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

-- Pre-migration functions still live (copied from the project 2026-10-16; no migration defines them).
create function public.generate_short_code() returns text
language plpgsql security definer set search_path to 'public' as $$
declare
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  code text;
  i int;
begin
  loop
    code := '';
    for i in 1..4 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.events e where e.short_code = code);
  end loop;
  return code;
end $$;

create function public.create_event(p_name text, p_format text default 'draft', p_rounds integer default 3,
  p_round_seconds integer default 3000, p_player_names text[] default '{}')
returns json language plpgsql security definer set search_path to 'public' as $$
declare
  v_event_id uuid;
  v_code text;
  v_pod_id uuid;
  v_name text;
  v_seat int := 1;
  v_participant_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Sign in required to create an event';
  end if;
  v_code := public.generate_short_code();
  insert into public.events (short_code, name, format, number_of_rounds, round_length_seconds, created_by)
  values (v_code, p_name, p_format, greatest(1, p_rounds), greatest(60, p_round_seconds), auth.uid())
  returning id into v_event_id;
  insert into public.event_members (event_id, user_id, role) values (v_event_id, auth.uid(), 'owner');
  insert into public.pods (event_id, name, display_order) values (v_event_id, 'Pod 1', 0)
  returning id into v_pod_id;
  foreach v_name in array coalesce(p_player_names, '{}')
  loop
    if length(trim(v_name)) > 0 then
      insert into public.participants (event_id, pod_id, display_name, seat)
      values (v_event_id, v_pod_id, trim(v_name), v_seat)
      returning id into v_participant_id;
      insert into public.participant_tokens (participant_id) values (v_participant_id);
      v_seat := v_seat + 1;
    end if;
  end loop;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id)
  values (v_event_id, auth.uid(), 'event.created', 'event', v_event_id);
  return json_build_object('event_id', v_event_id, 'short_code', v_code);
end $$;

create function public.report_result(p_match_id uuid, p_token text, p_side0_wins integer, p_side1_wins integer,
  p_draws integer default 0)
returns json language plpgsql security definer set search_path to 'public' as $$
declare
  v_participant_id uuid;
  v_match public.matches;
  v_event public.events;
  v_before jsonb;
begin
  select participant_id into v_participant_id from public.participant_tokens where token = p_token;
  if v_participant_id is null then
    raise exception 'Not recognised — rejoin the event to report results';
  end if;
  select * into v_match from public.matches where id = p_match_id;
  if v_match.id is null then raise exception 'Match not found'; end if;
  select * into v_event from public.events where id = v_match.event_id;
  if not v_event.allow_player_reporting then
    raise exception 'The organizer is recording results for this event';
  end if;
  if not exists (select 1 from public.match_sides s where s.match_id = p_match_id and s.participant_id = v_participant_id) then
    raise exception 'You are not playing in that match';
  end if;
  if p_side0_wins < 0 or p_side1_wins < 0 or p_draws < 0
     or p_side0_wins > 2 or p_side1_wins > 2
     or (p_side0_wins + p_side1_wins + p_draws) > 3 then
    raise exception 'That is not a valid match result';
  end if;
  select to_jsonb(array(
    select jsonb_build_object('side', s.side, 'game_wins', s.game_wins)
    from public.match_sides s where s.match_id = p_match_id order by s.side
  )) into v_before;
  update public.match_sides set game_wins = p_side0_wins where match_id = p_match_id and side = 0;
  update public.match_sides set game_wins = p_side1_wins where match_id = p_match_id and side = 1;
  update public.matches
     set game_draws = p_draws, status = 'reported', reported_by_participant = v_participant_id, reported_at = now()
   where id = p_match_id;
  insert into public.audit_log (event_id, actor_label, action, target_type, target_id, before, after)
  select v_match.event_id, p.display_name, 'result.reported', 'match', p_match_id, v_before,
         jsonb_build_object('side0', p_side0_wins, 'side1', p_side1_wins, 'draws', p_draws)
    from public.participants p where p.id = v_participant_id;
  return json_build_object('ok', true);
end $$;

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

-- Live organizer write policies (dashboard-created; copied from the project 2026-10-17).
-- 20261017120000_rpc_only_event_writes drops them; they stay here so tests run against what live has.
create policy events_insert_authenticated on public.events for insert to authenticated
  with check (created_by = (select auth.uid()));
create policy events_organizer_write on public.events for all using (public.is_event_organizer(id))
  with check (public.is_event_organizer(id));
create policy event_members_owner_write on public.event_members for all using (public.is_event_organizer(event_id))
  with check (public.is_event_organizer(event_id));
create policy pods_organizer_write on public.pods for all using (public.is_event_organizer(event_id))
  with check (public.is_event_organizer(event_id));
create policy participants_organizer_write on public.participants for all using (public.is_event_organizer(event_id))
  with check (public.is_event_organizer(event_id));
create policy rounds_organizer_write on public.rounds for all using (public.is_event_organizer(event_id))
  with check (public.is_event_organizer(event_id));
create policy matches_organizer_write on public.matches for all using (public.is_event_organizer(event_id))
  with check (public.is_event_organizer(event_id));
create policy match_sides_organizer_write on public.match_sides for all
  using (exists (select 1 from public.matches m where m.id = match_sides.match_id and public.is_event_organizer(m.event_id)))
  with check (exists (select 1 from public.matches m where m.id = match_sides.match_id and public.is_event_organizer(m.event_id)));
create policy audit_log_organizer_write on public.audit_log for insert with check (public.is_event_organizer(event_id));
create policy audit_log_organizer_read on public.audit_log for select using (public.is_event_organizer(event_id));
create policy event_members_read on public.event_members for select
  using (user_id = (select auth.uid()) or public.is_event_organizer(event_id));
