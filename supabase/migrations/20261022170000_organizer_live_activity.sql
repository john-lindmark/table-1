-- Organizer Live Activity (contract/widgets-2026-10-22.md). Organizers (event_members) get their own activity type,
-- so their push tokens are their own kinds: org_start (per device) and org_update (per activity, per event).
-- Replaces register_live_activity_token, t1_private.live_dispatch and live_on_matches (checked equal to live first).

alter table public.live_activity_tokens drop constraint if exists live_activity_tokens_kind_check;
alter table public.live_activity_tokens add constraint live_activity_tokens_kind_check
  check (kind in ('start', 'update', 'org_start', 'org_update'));

create index if not exists live_activity_tokens_org_event_idx on public.live_activity_tokens (event_id)
  where kind = 'org_update' and revoked_at is null;

create or replace function public.register_live_activity_token(
  p_kind text, p_token text, p_env text, p_device_id text,
  p_event_id uuid default null, p_activity_id text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_kind not in ('start', 'update', 'org_start', 'org_update') or p_env not in ('development','production')
     or length(coalesce(p_token,'')) not between 32 and 512 or length(coalesce(p_device_id,'')) not between 1 and 100 then
    raise exception 'Invalid token' using errcode = '22023';
  end if;
  if p_kind = 'update' and (p_event_id is null or not exists (
       select 1 from public.participants p where p.event_id = p_event_id and p.user_id = v_uid)) then
    raise exception 'You are not playing in that event' using errcode = '42501';
  end if;
  if p_kind = 'org_update' and (p_event_id is null or not exists (
       select 1 from public.event_members m where m.event_id = p_event_id and m.user_id = v_uid)) then
    raise exception 'You are not running that event' using errcode = '42501';
  end if;
  perform public._rate_limit('live.token', 30, interval '1 minute');
  insert into public.live_activity_tokens (user_id, kind, token, env, device_id, event_id, activity_id)
  values (v_uid, p_kind, p_token, p_env, p_device_id,
          case when p_kind in ('update', 'org_update') then p_event_id end, p_activity_id)
  on conflict (token) do update
     set user_id = excluded.user_id, kind = excluded.kind, env = excluded.env, device_id = excluded.device_id,
         event_id = excluded.event_id, activity_id = excluded.activity_id, revoked_at = null, updated_at = now();
  -- A device has one current push-to-start token per activity type; older ones are retired.
  if p_kind in ('start', 'org_start') then
    update public.live_activity_tokens set revoked_at = now(), updated_at = now()
     where kind = p_kind and user_id = v_uid and device_id = p_device_id and token <> p_token and revoked_at is null;
  end if;
end $$;

-- Fires for players or organizers with a token; demo events never push.
create or replace function t1_private.live_dispatch(p_kind text, p_event_id uuid, p_extra jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  if not exists (
    select 1 from public.participants p
      join public.live_activity_tokens t on t.user_id = p.user_id and t.revoked_at is null
     where p.event_id = p_event_id
    union all
    select 1 from public.event_members m
      join public.live_activity_tokens t on t.user_id = m.user_id and t.revoked_at is null
                                        and t.kind in ('org_start', 'org_update')
     where m.event_id = p_event_id) then
    return;
  end if;
  if exists (select 1 from public.events e where e.id = p_event_id and e.is_demo) then return; end if;
  select value into v_secret from t1_private.settings where name = 'live_push_secret';
  perform net.http_post(
    url := 'https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/live-activity',
    body := jsonb_build_object('action', 'dispatch', 'kind', p_kind, 'event_id', p_event_id) || coalesce(p_extra, '{}'::jsonb),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-t1-secret', v_secret),
    timeout_milliseconds := 10000);
exception when others then
  raise warning 'live_dispatch skipped: %', sqlerrm;
end $$;

-- One call per statement and event. `disputed`: a match became disputed; `settled`: a match stopped waiting
-- (pending, or disputed and not confirmed), for the organizer's alerts.
create or replace function public.live_on_matches()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in
    select n.event_id, array_agg(n.id) as ids,
           bool_or(n.disputed and not coalesce(o.disputed, false)) as disputed,
           bool_or((o.status = 'pending' or (o.disputed and o.status <> 'confirmed'))
                   and not (n.status = 'pending' or (n.disputed and n.status <> 'confirmed'))) as settled
      from new_rows n join old_rows o on o.id = n.id
     where (n.status, n.disputed, n.game_draws, n.version) is distinct from (o.status, o.disputed, o.game_draws, o.version)
     group by n.event_id
  loop
    perform t1_private.live_dispatch('match', r.event_id, jsonb_build_object(
      'match_ids', to_jsonb(r.ids), 'disputed', coalesce(r.disputed, false), 'settled', coalesce(r.settled, false)));
  end loop;
  return null;
end $$;

revoke execute on function public.live_on_matches() from public, anon, authenticated;
revoke execute on function public.register_live_activity_token(text,text,text,text,uuid,text) from public, anon;
grant execute on function public.register_live_activity_token(text,text,text,text,uuid,text) to authenticated;
