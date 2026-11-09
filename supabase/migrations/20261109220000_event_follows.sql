-- Following events you're not in (contract/event-follows-2026-11-09.md; John 2026-11-09: "add the ability for users
-- to follow events they are not in"). Anyone signed in who can read an event by its link (not private, not cancelled,
-- not demo, no block with its creator) and doesn't run or play in it can follow it from the event page: it shows on
-- their Events home under Following, and they get a notification when each round is paired, when the event finishes
-- and if it's cancelled. Who follows is never shown to anyone, the organizer included.

-- ==================================================================== a_table
create table if not exists public.event_follows (
  user_id uuid not null references auth.users (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  notify boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (user_id, event_id)
);
create index if not exists event_follows_event_idx on public.event_follows (event_id);
alter table public.event_follows enable row level security;
-- No policy: read and written only through the RPCs below.
revoke all on public.event_follows from anon, authenticated;

-- ==================================================================== b_helpers
-- Can p_user follow p_event (as event_access's `link` or `invited`, for any account, not just the caller)?
create or replace function t1_private.event_followable(p_event_id uuid, p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.events e
      join public.profiles pr on pr.id = p_user_id and pr.deleted_at is null
     where e.id = p_event_id and e.visibility <> 'private' and e.status <> 'cancelled' and not e.is_demo
       and not exists (select 1 from public.event_members m where m.event_id = e.id and m.user_id = p_user_id)
       and not exists (select 1 from public.participants p where p.event_id = e.id and p.user_id = p_user_id)
       and not exists (select 1 from public.user_blocks b
                        where (b.user_id = e.created_by and b.blocked_id = p_user_id)
                           or (b.user_id = p_user_id and b.blocked_id = e.created_by)));
$$;

-- Followers to notify about p_event_id, re-checked now (someone who joined it, was blocked, or is gone drops out).
create or replace function t1_private.event_followers(p_event_id uuid)
returns uuid[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(f.user_id), '{}')
    from public.event_follows f
   where f.event_id = p_event_id and f.notify and t1_private.event_followable(p_event_id, f.user_id);
$$;

-- ==================================================================== c_rpcs
-- Follow (p_follow true) or unfollow; p_notify turns its notifications on or off (null keeps). → {following, notify}.
create or replace function public.event_follow_set(p_event_id uuid, p_follow boolean, p_notify boolean default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_access text;
  v_status text;
  f public.event_follows;
  v_n integer;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_event_id is null or p_follow is null then raise exception 'Say which event and whether to follow it' using errcode = '22023'; end if;
  if not p_follow then
    delete from public.event_follows where user_id = v_uid and event_id = p_event_id;
    get diagnostics v_n = row_count;
    if v_n > 0 then
      insert into public.account_audit (actor, action, target_id) values (v_uid, 'event.unfollowed', p_event_id);
    end if;
    return jsonb_build_object('following', false, 'notify', false);
  end if;
  v_access := t1_private.event_access(p_event_id);
  if v_access in ('organizer', 'player') then
    raise exception 'You''re in this event already' using errcode = '22023';
  end if;
  if v_access not in ('link', 'invited') or not t1_private.event_followable(p_event_id, v_uid) then
    raise exception 'That event isn''t available' using errcode = '42501';
  end if;
  select e.status into v_status from public.events e where e.id = p_event_id;
  select * into f from public.event_follows where user_id = v_uid and event_id = p_event_id;
  if f.user_id is null then
    if v_status in ('completed', 'archived') then raise exception 'That event is over' using errcode = '22023'; end if;
    if (select count(*) from public.event_follows where user_id = v_uid) >= 200 then
      raise exception 'You''re following 200 events. Unfollow one first.' using errcode = '53400';
    end if;
    insert into public.event_follows (user_id, event_id, notify) values (v_uid, p_event_id, coalesce(p_notify, true))
    returning * into f;
    insert into public.account_audit (actor, action, target_id, after)
    values (v_uid, 'event.followed', p_event_id, jsonb_build_object('notify', f.notify));
  elsif p_notify is not null and p_notify is distinct from f.notify then
    update public.event_follows set notify = p_notify where user_id = v_uid and event_id = p_event_id returning * into f;
    insert into public.account_audit (actor, action, target_id, after)
    values (v_uid, 'event.follow_notify', p_event_id, jsonb_build_object('notify', f.notify));
  end if;
  return jsonb_build_object('following', true, 'notify', f.notify);
end $$;

-- Whether you follow it. Someone who can't follow it (in it, private, blocked) reads not following.
create or replace function public.event_follow_get(p_event_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when auth.uid() is null then jsonb_build_object('following', false, 'notify', false, 'can_follow', false)
    else jsonb_build_object(
      'following', f.user_id is not null and t1_private.event_followable(p_event_id, auth.uid()),
      'notify', coalesce(f.notify, false) and t1_private.event_followable(p_event_id, auth.uid()),
      'can_follow', t1_private.event_followable(p_event_id, auth.uid())
        and coalesce((select e.status not in ('completed', 'archived') or f.user_id is not null from public.events e where e.id = p_event_id), false)) end
    from (select 1) one
    left join public.event_follows f on f.user_id = auth.uid() and f.event_id = p_event_id;
$$;

-- The Events home's Following: events you follow that you can still follow, running first, then upcoming by start,
-- then finished ones from the last 7 days (newest first). Older finished ones drop off the list.
create or replace function public.events_followed()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'event_id', e.id, 'name', e.name, 'format_label', e.format_label, 'status', e.status,
             'current_round', e.current_round, 'number_of_rounds', e.number_of_rounds, 'top_cut', e.top_cut,
             'starts_at', e.starts_at, 'venue_name', e.venue_name, 'notify', f.notify,
             'stage', (select r.stage from public.rounds r where r.event_id = e.id order by r.number desc limit 1))
           order by case when e.status = 'completed' then 2 when e.current_round > 0 then 0 else 1 end,
                    case when e.status = 'completed' then null else e.starts_at end nulls last,
                    case when e.status = 'completed' then e.updated_at end desc, lower(e.name), e.id)
      from public.event_follows f
      join public.events e on e.id = f.event_id
     where f.user_id = v_uid and t1_private.event_followable(e.id, v_uid)
       and e.status <> 'archived' and (e.status <> 'completed' or e.updated_at > now() - interval '7 days')), '[]'::jsonb);
end $$;

-- ==================================================================== d_pushes
-- A round paired (re-paired rounds too): "Round 3 is up · <event>". Copy in notify-worker (event.follow_round).
create or replace function t1_private.event_follow_round_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
declare e public.events;
begin
  select * into e from public.events where id = new.event_id;
  if e.id is null or e.is_demo then return null; end if;
  perform public.enqueue_notification('event.follow_round', e.id, t1_private.event_followers(e.id),
    jsonb_build_object('event_name', e.name, 'round', new.number, 'stage', coalesce(new.stage, 'swiss'),
                       'of', e.number_of_rounds));
  return null;
end $$;
drop trigger if exists rounds_follow_push on public.rounds;
create trigger rounds_follow_push after insert on public.rounds
  for each row execute function t1_private.event_follow_round_trg();

-- The event finished ("Final standings are up") or was cancelled (the usual cancelled copy).
create or replace function t1_private.event_follow_status_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.is_demo or new.status is not distinct from old.status then return null; end if;
  if new.status = 'completed' then
    perform public.enqueue_notification('event.follow_done', new.id, t1_private.event_followers(new.id),
      jsonb_build_object('event_name', new.name));
  elsif new.status = 'cancelled' then
    -- event_followers drops cancelled events, so these are read straight from the follows.
    perform public.enqueue_notification('event.cancelled', new.id,
      (select coalesce(array_agg(f.user_id), '{}') from public.event_follows f
        join public.profiles pr on pr.id = f.user_id and pr.deleted_at is null
       where f.event_id = new.id and f.notify
         and not exists (select 1 from public.participants p where p.event_id = new.id and p.user_id = f.user_id)
         and not exists (select 1 from public.event_members m where m.event_id = new.id and m.user_id = f.user_id)),
      jsonb_build_object('event_name', new.name, 'reason', new.cancel_reason));
  end if;
  return null;
end $$;
drop trigger if exists events_follow_push on public.events;
create trigger events_follow_push after update of status on public.events
  for each row execute function t1_private.event_follow_status_trg();

-- ==================================================================== e_grants
revoke execute on function t1_private.event_followable(uuid, uuid) from public, anon, authenticated;
revoke execute on function t1_private.event_followers(uuid) from public, anon, authenticated;
revoke execute on function t1_private.event_follow_round_trg() from public, anon, authenticated;
revoke execute on function t1_private.event_follow_status_trg() from public, anon, authenticated;
revoke execute on function public.event_follow_set(uuid, boolean, boolean) from public, anon;
grant execute on function public.event_follow_set(uuid, boolean, boolean) to authenticated;
revoke execute on function public.event_follow_get(uuid) from public, anon;
grant execute on function public.event_follow_get(uuid) to authenticated;
revoke execute on function public.events_followed() from public, anon;
grant execute on function public.events_followed() to authenticated;
