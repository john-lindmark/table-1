-- The organizer hears when someone signs up or drops (contract/scheduled-events-2026-10-27.md § Organizer pushes).
-- Table triggers, so every way in or out counts: the sign-up link (app, web, Discord), a join code or Nearby, an
-- accepted invite, the waitlist, and leaving before round 1. Only a player's own move counts: nothing when an
-- organizer adds, seats, admits or drops someone, when the waitlist moves up behind someone who left, or in demo
-- events. Pushes go to every organizer (event_members) as `event.signed_up` / `event.dropped`; notify-worker reads
-- the player count when it sends, so a drop that moved someone up from the waitlist reads right.

-- The player's own move, made as them: their account (also via Discord, which acts as the account), or signed out
-- by join code as a guest.
create or replace function t1_private.own_move(p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select case when p_user_id is not null then p_user_id = auth.uid()
              else auth.uid() is null and coalesce(current_setting('role', true), 'none') = 'anon' end
$$;

create or replace function t1_private.organizer_sign_up_push(p_event_id uuid, p_kind text, p_name text, p_waitlist boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_users uuid[];
begin
  select * into e from public.events where id = p_event_id;
  if e.id is null or e.is_demo or e.status in ('cancelled', 'completed', 'archived') then return; end if;
  -- An organizer signing themselves up or leaving is no news to the organizers.
  if exists (select 1 from public.event_members m where m.event_id = e.id and m.user_id = auth.uid()) then return; end if;
  select array_agg(distinct m.user_id) into v_users from public.event_members m where m.event_id = e.id;
  perform public.enqueue_notification(p_kind, e.id, v_users,
    jsonb_build_object('event_name', e.name, 'name', coalesce(nullif(trim(p_name), ''), 'A player'), 'waitlist', p_waitlist));
end $$;

create or replace function t1_private.participants_sign_up_push() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if t1_private.own_move(new.user_id) then
      perform t1_private.organizer_sign_up_push(new.event_id, 'event.signed_up', new.display_name, false);
    end if;
    return null;
  end if;
  if old.user_id is not null and old.user_id = auth.uid() then
    perform t1_private.organizer_sign_up_push(old.event_id, 'event.dropped', old.display_name, false);
  end if;
  return null;
end $$;

drop trigger if exists participants_sign_up_push on public.participants;
create trigger participants_sign_up_push
  after insert or delete on public.participants
  for each row execute function t1_private.participants_sign_up_push();

create or replace function t1_private.waitlist_sign_up_push() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.user_id = auth.uid() then
      perform t1_private.organizer_sign_up_push(new.event_id, 'event.signed_up', new.display_name, true);
    end if;
    return null;
  end if;
  -- Leaving the line on your own; not when you were just seated from it (a join code seats you, then clears it).
  if old.user_id = auth.uid() and not exists (select 1 from public.participants p
                                                where p.event_id = old.event_id and p.user_id = old.user_id) then
    perform t1_private.organizer_sign_up_push(old.event_id, 'event.dropped', old.display_name, true);
  end if;
  return null;
end $$;

drop trigger if exists event_waitlist_sign_up_push on public.event_waitlist;
create trigger event_waitlist_sign_up_push
  after insert or delete on public.event_waitlist
  for each row execute function t1_private.waitlist_sign_up_push();

revoke all on function t1_private.own_move(uuid) from public;
revoke all on function t1_private.organizer_sign_up_push(uuid, text, text, boolean) from public;
revoke all on function t1_private.participants_sign_up_push() from public;
revoke all on function t1_private.waitlist_sign_up_push() from public;
