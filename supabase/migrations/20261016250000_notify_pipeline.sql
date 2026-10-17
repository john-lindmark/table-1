-- Push notifications go out (2026-10-16). Until now `enqueue_notification` filled the pgmq `notify` queue and
-- nothing sent it, and no app registered a push token, so no alert ever arrived (Kenny's for the 15 Oct draft).
--
--   devices.env                 APNs environment per token (TestFlight/App Store = production, Xcode = development).
--   register_device(..., p_env) apps call it at launch with their APNs (later FCM) token.
--   notify_claim / notify_done  the notify-worker edge function reads and deletes queue messages (service role).
--   enqueue_notification        now kicks the worker at once (pg_net, after commit) when a recipient has a device.
--   cron t1-notify-sweep        every minute, in case a kick was lost.
--   event.new                   a new event alerts the organizer's regulars: accounts that played in one of their
--                               events in the last 90 days. Sent by the sweep a minute after the event is created
--                               (skipped if it was made private), alongside the nearby alert (which still needs
--                               opt-in and recent presence). Muted per account with notification_prefs.muted_kinds.

alter table public.devices add column if not exists env text not null default 'production'
  check (env in ('development', 'production'));

drop function if exists public.register_device(text, text, text, text);
create or replace function public.register_device(
  p_platform text, p_push_token text, p_live_activity_token text default null, p_app_version text default null,
  p_env text default 'production')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  insert into public.devices (user_id, platform, push_token, live_activity_token, app_version, env)
  values (auth.uid(), p_platform, p_push_token, p_live_activity_token, p_app_version,
          case when p_env = 'development' then 'development' else 'production' end)
  on conflict (platform, push_token) do update
    set user_id = excluded.user_id, live_activity_token = coalesce(excluded.live_activity_token, public.devices.live_activity_token),
        app_version = excluded.app_version, env = excluded.env, last_seen_at = now()
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.register_device(text, text, text, text, text) from public, anon;
grant execute on function public.register_device(text, text, text, text, text) to authenticated;

-- Sign-out on a shared phone: the token stops reaching the old account.
create or replace function public.unregister_device(p_push_token text)
returns void language sql security definer set search_path = '' as $$
  delete from public.devices where push_token = p_push_token and user_id = auth.uid();
$$;
revoke execute on function public.unregister_device(text) from public, anon;
grant execute on function public.unregister_device(text) to authenticated;

-- ---------------------------------------------------------------- worker queue access (service role only)

create or replace function public.notify_claim(p_n integer default 50)
returns table (msg_id bigint, enqueued_at timestamptz, message jsonb)
language sql security definer set search_path = '' as $$
  select r.msg_id, r.enqueued_at, r.message from pgmq.read('notify', 60, least(greatest(p_n, 1), 200)) r;
$$;
create or replace function public.notify_done(p_ids bigint[])
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform pgmq.delete('notify', p_ids);
end $$;
revoke execute on function public.notify_claim(integer) from public, anon, authenticated;
revoke execute on function public.notify_done(bigint[]) from public, anon, authenticated;
grant execute on function public.notify_claim(integer) to service_role;
grant execute on function public.notify_done(bigint[]) to service_role;

create or replace function t1_private.notify_kick()
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  select value into v_secret from t1_private.settings where name = 'live_push_secret';
  perform net.http_post(
    url := 'https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/notify-worker',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-t1-secret', v_secret),
    timeout_milliseconds := 10000);
exception when others then
  raise warning 'notify_kick skipped: %', sqlerrm;
end $$;

-- One message per audience; the notify-worker expands audiences into device tokens.
create or replace function public.enqueue_notification(p_kind text, p_event_id uuid, p_user_ids uuid[], p_data jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_user_ids is null or cardinality(p_user_ids) = 0 then return; end if;
  perform pgmq.send('notify', jsonb_build_object(
    'kind', p_kind, 'event_id', p_event_id, 'user_ids', to_jsonb(p_user_ids),
    'data', coalesce(p_data, '{}'::jsonb), 'enqueued_at', now()));
  if exists (select 1 from public.devices d where d.user_id = any (p_user_ids)) then
    perform t1_private.notify_kick();
  end if;
end $$;

-- The backlog from before any device could receive it is stale: drop it rather than alert about old events.
select pgmq.purge_queue('notify');

-- ---------------------------------------------------------------- new events reach the organizer's regulars

create or replace function public._send_regulars_alert(p_event_id uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_users uuid[];
begin
  select * into e from public.events where id = p_event_id;
  if e.id is null or e.is_demo or e.visibility = 'private' or e.status not in ('setup', 'seated') then return 0; end if;
  select array_agg(distinct p.user_id) into v_users
    from public.participants p
    join public.events pe on pe.id = p.event_id
   where pe.created_by = e.created_by and pe.id <> e.id and not pe.is_demo
     and pe.created_at > now() - interval '90 days'
     and p.user_id is not null and p.user_id <> e.created_by
     and not exists (select 1 from public.participants x where x.event_id = e.id and x.user_id = p.user_id)
     and not exists (select 1 from public.event_invites i where i.event_id = e.id and i.user_id = p.user_id)
     and not exists (select 1 from public.notification_prefs np
                      where np.user_id = p.user_id and 'event.new' = any (np.muted_kinds));
  perform public.enqueue_notification('event.new', e.id, v_users,
    jsonb_build_object('event_name', e.name, 'venue_name', e.venue_name, 'format_label', e.format_label,
                       'starts_at', e.starts_at,
                       'organizer', (select pr.display_name from public.profiles pr where pr.id = e.created_by)));
  return coalesce(cardinality(v_users), 0);
end $$;
revoke execute on function public._send_regulars_alert(uuid) from public, anon, authenticated;

-- Every minute: alert regulars about events that are a minute old (so a private choice made right after
-- creating has landed), then wake the worker if anything is waiting.
alter table public.events add column if not exists regulars_alerted_at timestamptz;
update public.events set regulars_alerted_at = now() where regulars_alerted_at is null;

create or replace function t1_private.notify_tick()
returns void language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in
    update public.events set regulars_alerted_at = now()
     where regulars_alerted_at is null and created_at < now() - interval '1 minute'
     returning id
  loop
    perform public._send_regulars_alert(r.id);
  end loop;
  if exists (select 1 from pgmq.q_notify where vt <= now()) then
    perform t1_private.notify_kick();
  end if;
exception when others then
  raise warning 'notify_tick: %', sqlerrm;
end $$;

do $$ begin
  perform cron.unschedule('t1-notify-sweep') where exists (select 1 from cron.job where jobname = 't1-notify-sweep');
  perform cron.schedule('t1-notify-sweep', '* * * * *', 'select t1_private.notify_tick()');
end $$;
