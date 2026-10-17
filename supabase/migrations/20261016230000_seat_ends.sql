-- Draft seating drawn like a real table (2026-10-16): players sit along both long sides of one table, and the
-- organizer can seat the two ends too. This is only how the table is drawn: seat numbers and round 1 pairings
-- don't change. Stored on the event so every player sees the same table as the organizer.

alter table public.events add column if not exists seat_ends boolean not null default false;

create or replace function public.set_seat_ends(p_event_id uuid, p_on boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_before boolean;
begin
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can do that' using errcode = '42501';
  end if;
  select seat_ends into v_before from public.events where id = p_event_id for update;
  if not found then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if v_before = coalesce(p_on, false) then return; end if;
  update public.events set seat_ends = coalesce(p_on, false), updated_at = now() where id = p_event_id;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
  values (p_event_id, auth.uid(), 'event.seat_ends', 'event', p_event_id,
          jsonb_build_object('seat_ends', v_before), jsonb_build_object('seat_ends', coalesce(p_on, false)));
end $$;
revoke execute on function public.set_seat_ends(uuid, boolean) from public, anon;
grant execute on function public.set_seat_ends(uuid, boolean) to authenticated;
