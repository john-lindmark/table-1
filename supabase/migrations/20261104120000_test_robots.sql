-- Table 1 — Google's test robots (2026-11-04; contract/test-robots-2026-11-04.md).
-- Four accounts John didn't recognize (Oct 31 – Nov 4) were Google Play's pre-launch report: Firebase Test Lab phones
-- signing in with Google from Google's networks, creating a Star Trek draft with every default and leaving. They were
-- real accounts with real events, three of them Nearby, so robot events could alert real players (none did).
-- Robots stay allowed (the pre-launch report finds crashes on real phones) but are kept apart:
--   * an account is a robot when the Android app says it runs in Test Lab (account_mark_robot) or when a new
--     account's first sign-ins come from a Test Lab network (t1_private.robot_networks, a trigger on auth.sessions);
--   * a robot's profile and events are demo data (is_demo), which every list, search and push already leaves out;
--     nearby alerts and Nearby didn't look at is_demo and now do;
--   * t1-robot-sweep removes robots a week after they were marked, as account deletion does.
-- _send_nearby_alerts and nearby_events are otherwise as live (20261006120000, 20261016150000).

create table if not exists t1_private.robot_networks (
  net cidr primary key,
  note text not null
);
alter table t1_private.robot_networks enable row level security;
revoke all on t1_private.robot_networks from public, anon, authenticated;

-- Firebase Test Lab's published blocks (firebase.google.com/docs/test-lab/android/get-started, read 2026-11-04;
-- also `gcloud beta firebase test ip-blocks list`), plus one the robots used that isn't listed.
insert into t1_private.robot_networks (net, note)
select n::cidr, 'Test Lab physical / Arm' from unnest(array[
  '70.32.128.0/19', '108.177.6.0/23', '108.177.18.192/26', '108.177.29.64/27', '108.177.31.160/27',
  '199.36.156.8/29', '199.36.156.16/28', '209.85.131.0/27', '70.32.150.192/27', '108.177.24.160/27',
  '108.177.29.0/27', '108.177.25.128/27', '108.177.26.128/26', '108.177.29.192/26', '172.217.120.64/26',
  '172.217.120.128/26', '2001:4860:1008::/48', '2001:4860:1018::/48', '2001:4860:1019::/48', '2001:4860:1020::/48',
  '2001:4860:1022::/48', '2001:4860:101d::/48', '2001:4860:101e::/48', '2001:4860:1031::/48', '2001:4860:1037::/48',
  '2001:4860:1038::/48', '2001:4860:103a::/48']) n
union all
select n::cidr, 'Test Lab virtual' from unnest(array[
  '34.68.194.64/29', '34.69.234.64/29', '34.73.34.72/29', '34.73.178.72/29', '34.74.10.72/29', '34.136.2.136/29',
  '34.136.50.136/29', '34.145.234.144/29', '35.192.160.56/29', '35.196.166.80/29', '35.196.169.240/29',
  '35.203.128.0/28', '35.234.176.160/28', '35.243.2.0/27', '35.245.243.240/29', '199.192.115.0/30',
  '199.192.115.8/30', '199.192.115.16/29']) n
union all
select '66.102.8.0/24'::cidr, 'seen 2026-11-04 (pre-launch robot, not in the published list)'
on conflict (net) do nothing;

create table if not exists t1_private.robots (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reason text not null check (reason in ('device', 'network', 'manual')),
  marked_at timestamptz not null default now()
);
alter table t1_private.robots enable row level security;
revoke all on t1_private.robots from public, anon, authenticated;

create or replace function t1_private.is_robot(p_uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from t1_private.robots r where r.user_id = p_uid)
$$;

-- Marks an account a robot and turns what it made into demo data. Idempotent: false when it was already marked.
create or replace function t1_private.robot_quarantine(p_uid uuid, p_reason text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  e record;
begin
  insert into t1_private.robots (user_id, reason) values (p_uid, p_reason) on conflict (user_id) do nothing;
  if not found then return false; end if;

  -- demo_owner stays null: demo_remove clears profiles a tester owns, and this is the robot's own.
  update public.profiles set is_demo = true, updated_at = now() where id = p_uid and not is_demo;
  for e in
    update public.events set is_demo = true, demo_owner = p_uid, updated_at = now()
     where created_by = p_uid and not is_demo
    returning id
  loop
    insert into public.audit_log (event_id, actor_user, actor_label, action, target_type, target_id, after)
    values (e.id, null, 'system', 'event.robot_quarantined', 'event', e.id, jsonb_build_object('reason', p_reason));
  end loop;

  insert into public.account_audit (actor, action, target_user, after)
  values (p_uid, 'robot.marked', p_uid, jsonb_build_object('reason', p_reason));
  return true;
end $$;
revoke all on function t1_private.robot_quarantine(uuid, text) from public, anon, authenticated;

-- A false positive: John lets an account back out (SQL Editor: select t1_private.robot_release('<id>')).
create or replace function t1_private.robot_release(p_uid uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  e record;
begin
  delete from t1_private.robots where user_id = p_uid;
  if not found then return false; end if;
  update public.profiles set is_demo = false, updated_at = now() where id = p_uid and is_demo and demo_owner is null;
  for e in
    update public.events set is_demo = false, demo_owner = null, updated_at = now()
     where created_by = p_uid and demo_owner = p_uid and is_demo
    returning id
  loop
    insert into public.audit_log (event_id, actor_user, actor_label, action, target_type, target_id)
    values (e.id, null, 'system', 'event.robot_released', 'event', e.id);
  end loop;
  insert into public.account_audit (actor, action, target_user) values (p_uid, 'robot.released', p_uid);
  return true;
end $$;
revoke all on function t1_private.robot_release(uuid) from public, anon, authenticated;

-- The Android app, when Settings.System "firebase.test.lab" is "true": this account is a robot. Self only.
create or replace function public.account_mark_robot()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  return jsonb_build_object('marked', t1_private.robot_quarantine(v_uid, 'device'));
end $$;
revoke all on function public.account_mark_robot() from public, anon;
grant execute on function public.account_mark_robot() to authenticated;

-- A robot's new events are demo data from the start, so no alert ever goes out for them.
create or replace function t1_private.robot_events_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not new.is_demo and new.created_by is not null and t1_private.is_robot(new.created_by) then
    new.is_demo := true;
    new.demo_owner := new.created_by;
  end if;
  return new;
end $$;
revoke all on function t1_private.robot_events_trg() from public, anon, authenticated;

drop trigger if exists t1_robot_events on public.events;
create trigger t1_robot_events before insert on public.events
  for each row execute function t1_private.robot_events_trg();

-- A sign-in from a Test Lab network within an hour of the account being made marks it. Never in the way of signing in.
create or replace function t1_private.robot_session_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.ip is not null
     and exists (select 1 from t1_private.robot_networks n where new.ip <<= n.net)
     and exists (select 1 from auth.users u where u.id = new.user_id and u.created_at > now() - interval '1 hour') then
    perform t1_private.robot_quarantine(new.user_id, 'network');
  end if;
  return null;
exception when others then
  raise warning 'robot_session_trg: %', sqlerrm;
  return null;
end $$;
revoke all on function t1_private.robot_session_trg() from public, anon, authenticated;

drop trigger if exists t1_robot_sessions on auth.sessions;
create trigger t1_robot_sessions after insert on auth.sessions
  for each row execute function t1_private.robot_session_trg();

-- Removes one robot the way account deletion does (delete_account as the robot, then the auth user). Accounts with
-- an Apple sign-in are left alone: deleting those has to revoke Apple's token, which only delete-account can.
create or replace function t1_private.robot_remove(p_uid uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not t1_private.is_robot(p_uid)
     or exists (select 1 from auth.identities i where i.user_id = p_uid and i.provider = 'apple') then
    return false;
  end if;
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform public.delete_account();
  delete from public.live_activity_tokens where user_id = p_uid;
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('request.jwt.claims', '', true);
  delete from auth.users where id = p_uid;   -- the robots row goes with it
  return true;
end $$;
revoke all on function t1_private.robot_remove(uuid) from public, anon, authenticated;

-- Daily: robots marked a week ago or more. One that can't go (it joined a real event) stays and is tried again.
create or replace function t1_private.robot_sweep()
returns int language plpgsql security definer set search_path = '' as $$
declare
  r record;
  v_n int := 0;
begin
  for r in select user_id from t1_private.robots where marked_at < now() - interval '7 days' order by marked_at loop
    begin
      if t1_private.robot_remove(r.user_id) then v_n := v_n + 1; end if;
    exception when others then
      raise warning 'robot_sweep %: %', r.user_id, sqlerrm;
    end;
  end loop;
  return v_n;
end $$;
revoke all on function t1_private.robot_sweep() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-robot-sweep') then
      perform cron.schedule('t1-robot-sweep', '10 5 * * *', 'select t1_private.robot_sweep()');
    end if;
  end if;
end $$;

-- Nearby alerts: never for demo events.
create or replace function public._send_nearby_alerts(p_event_id uuid)
returns integer language plpgsql security definer set search_path to '' as $function$
declare
  e public.events;
  l public.event_locations;
  v_users uuid[];
begin
  select * into e from public.events where id = p_event_id for update;
  select * into l from public.event_locations where event_id = p_event_id;
  if e.id is null or l.event_id is null or e.is_demo or e.visibility <> 'nearby' or e.nearby_alerts_sent_at is not null
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
end $function$;

-- Nearby: demo events only for whoever made them.
create or replace function public.nearby_events(
  p_lat double precision, p_lng double precision, p_accuracy_m integer default 50, p_limit integer default 20)
returns table(event_id uuid, name text, venue_name text, format text, status text, players integer, capacity integer,
              distance_m integer, starts_at timestamp with time zone, joined boolean)
language plpgsql stable security definer set search_path to '' as $function$
declare
  pt extensions.geography;
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in to find nearby events' using errcode = '28000'; end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Invalid coordinates' using errcode = '22023';
  end if;
  pt := extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography;
  return query
  select e.id, e.name, e.venue_name, e.format, e.status,
         (select count(*) from public.participants p where p.event_id = e.id and p.status = 'active')::int,
         e.capacity,
         (round(extensions.st_distance(l.location, pt) / 50.0) * 50)::int,
         e.starts_at,
         (e.created_by = me or exists (select 1 from public.participants p
                                        where p.event_id = e.id and p.user_id = me and p.status = 'active'))
    from public.event_locations l
    join public.events e on e.id = l.event_id
   where e.visibility = 'nearby' and e.status in ('setup', 'seated', 'in_progress')
     and (not e.is_demo or e.created_by = me)
     and (e.discoverable_until is null or e.discoverable_until > now())
     and extensions.st_dwithin(l.location, pt, 2100)        -- constant radius: index-assisted
     and extensions.st_distance(l.location, pt) <= e.join_radius_m + least(greatest(p_accuracy_m, 0), 100)
   order by l.location operator(extensions.<->) pt
   limit least(greatest(p_limit, 1), 50);
end $function$;
