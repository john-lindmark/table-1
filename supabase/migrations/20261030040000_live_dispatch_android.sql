-- Android's Live Activities (contract/widgets-2026-10-22.md § Android): live-activity also sends the player and organizer
-- states to Android devices as data-only FCM messages, drawn as an ongoing notification. The dispatch guard only
-- called it when someone in the event held an iOS Live Activity token, so an event of Android players never reached
-- it. Now an Android device of a player or an organizer counts too. Otherwise the same function as
-- 20261022170000_organizer_live_activity.sql.
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
     where m.event_id = p_event_id
    union all
    select 1 from public.participants p
      join public.devices d on d.user_id = p.user_id and d.platform = 'android'
     where p.event_id = p_event_id
    union all
    select 1 from public.event_members m
      join public.devices d on d.user_id = m.user_id and d.platform = 'android'
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
