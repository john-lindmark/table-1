-- Live Activities + widgets (applied live as n_live_activity_tokens and o_live_activity_dispatch).

-- Push tokens. 'start' = per-device push-to-start token (iOS 17.2+); 'update' = per-activity token.
create table if not exists public.live_activity_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  kind text not null check (kind in ('start','update')),
  token text not null unique,
  env text not null check (env in ('development','production')),
  device_id text not null,
  event_id uuid,
  activity_id text,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists live_activity_tokens_user_idx on public.live_activity_tokens (user_id) where revoked_at is null;
create index if not exists live_activity_tokens_event_idx on public.live_activity_tokens (event_id) where kind = 'update' and revoked_at is null;
alter table public.live_activity_tokens enable row level security;
revoke all on public.live_activity_tokens from anon, authenticated;

create or replace function public.register_live_activity_token(
  p_kind text, p_token text, p_env text, p_device_id text,
  p_event_id uuid default null, p_activity_id text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_kind not in ('start','update') or p_env not in ('development','production')
     or length(coalesce(p_token,'')) not between 32 and 512 or length(coalesce(p_device_id,'')) not between 1 and 100 then
    raise exception 'Invalid token' using errcode = '22023';
  end if;
  if p_kind = 'update' and (p_event_id is null or not exists (
       select 1 from public.participants p where p.event_id = p_event_id and p.user_id = v_uid)) then
    raise exception 'You are not playing in that event' using errcode = '42501';
  end if;
  perform public._rate_limit('live.token', 30, interval '1 minute');
  insert into public.live_activity_tokens (user_id, kind, token, env, device_id, event_id, activity_id)
  values (v_uid, p_kind, p_token, p_env, p_device_id, case when p_kind = 'update' then p_event_id end, p_activity_id)
  on conflict (token) do update
     set user_id = excluded.user_id, kind = excluded.kind, env = excluded.env, device_id = excluded.device_id,
         event_id = excluded.event_id, activity_id = excluded.activity_id, revoked_at = null, updated_at = now();
  if p_kind = 'start' then
    update public.live_activity_tokens set revoked_at = now(), updated_at = now()
     where kind = 'start' and user_id = v_uid and device_id = p_device_id and token <> p_token and revoked_at is null;
  end if;
end $$;

create or replace function public.unregister_live_activity_token(p_token text)
returns void language sql security definer set search_path = '' as $$
  update public.live_activity_tokens set revoked_at = now(), updated_at = now()
   where token = p_token and user_id = auth.uid() and revoked_at is null;
$$;
revoke execute on function public.register_live_activity_token(text,text,text,text,uuid,text) from public, anon;
revoke execute on function public.unregister_live_activity_token(text) from public, anon;
grant execute on function public.register_live_activity_token(text,text,text,text,uuid,text) to authenticated;
grant execute on function public.unregister_live_activity_token(text) to authenticated;

-- Shared secret between the database and the live-activity edge function (never exposed over the API).
create schema if not exists t1_private;
revoke all on schema t1_private from public, anon, authenticated;
create table if not exists t1_private.settings (name text primary key, value text not null);
insert into t1_private.settings (name, value)
values ('live_push_secret', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (name) do nothing;
create or replace function public.live_push_secret_ok(p_secret text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from t1_private.settings where name = 'live_push_secret' and value = p_secret);
$$;
revoke execute on function public.live_push_secret_ok(text) from public, anon, authenticated;
grant execute on function public.live_push_secret_ok(text) to service_role;

-- Fire-and-forget: pg_net sends after commit, so result writes never wait on Apple.
-- Events with no iOS Live Activity tokens cost one indexed lookup and nothing else.
create or replace function t1_private.live_dispatch(p_kind text, p_event_id uuid, p_extra jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  if not exists (
    select 1 from public.participants p
      join public.live_activity_tokens t on t.user_id = p.user_id and t.revoked_at is null
     where p.event_id = p_event_id) then
    return;
  end if;
  select value into v_secret from t1_private.settings where name = 'live_push_secret';
  perform net.http_post(
    url := 'https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/live-activity',
    body := jsonb_build_object('action', 'dispatch', 'kind', p_kind, 'event_id', p_event_id) || coalesce(p_extra, '{}'::jsonb),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-t1-secret', v_secret),
    timeout_milliseconds := 10000);
exception when others then
  raise warning 'live_dispatch skipped: %', sqlerrm;
end $$;

-- One call per statement and event, however many matches changed.
create or replace function public.live_on_matches()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in
    select n.event_id, array_agg(n.id) as ids
      from new_rows n join old_rows o on o.id = n.id
     where (n.status, n.disputed, n.game_draws, n.version) is distinct from (o.status, o.disputed, o.game_draws, o.version)
     group by n.event_id
  loop
    perform t1_private.live_dispatch('match', r.event_id, jsonb_build_object('match_ids', to_jsonb(r.ids)));
  end loop;
  return null;
end $$;
create trigger matches_live_push after update on public.matches
  referencing old table as old_rows new table as new_rows
  for each statement execute function public.live_on_matches();

create or replace function public.live_on_events()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status in ('completed','archived') and old.status is distinct from new.status then
    perform t1_private.live_dispatch('event_ended', new.id);
  elsif new.current_round is distinct from old.current_round and new.status = 'in_progress' then
    perform t1_private.live_dispatch('round_started', new.id);
  end if;
  return null;
end $$;
create trigger events_live_push after update of current_round, status on public.events
  for each row execute function public.live_on_events();

create or replace function public.live_on_rounds()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'recorded' and old.status is distinct from 'recorded' then
    perform t1_private.live_dispatch('round_recorded', new.event_id, jsonb_build_object('round_id', new.id));
  elsif new.status = 'active' and
        (new.timer_status, new.timer_remaining_at_change, new.timer_last_started_at, new.timer_ends_at, new.timer_duration_seconds)
        is distinct from
        (old.timer_status, old.timer_remaining_at_change, old.timer_last_started_at, old.timer_ends_at, old.timer_duration_seconds) then
    perform t1_private.live_dispatch('clock', new.event_id, jsonb_build_object('round_id', new.id));
  end if;
  return null;
end $$;
create trigger rounds_live_push after update on public.rounds
  for each row execute function public.live_on_rounds();

create or replace function public.live_on_participants()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'dropped' and old.status is distinct from 'dropped' then
    perform t1_private.live_dispatch('dropped', new.event_id, jsonb_build_object('participant_id', new.id));
  end if;
  return null;
end $$;
create trigger participants_live_push after update of status on public.participants
  for each row execute function public.live_on_participants();

revoke execute on function public.live_on_matches() from public, anon, authenticated;
revoke execute on function public.live_on_events() from public, anon, authenticated;
revoke execute on function public.live_on_rounds() from public, anon, authenticated;
revoke execute on function public.live_on_participants() from public, anon, authenticated;
