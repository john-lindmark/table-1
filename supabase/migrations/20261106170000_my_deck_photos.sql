-- Your deck photos on your account (contract/event-night-2026-10-16.md § 7 "On your account", 2026-11-06; John:
-- "Users should be able to see their past deck photos from their account/profile view"). Until now a photo could only
-- be found inside its event's Deck photos screen. `my_deck_photos` lists every photo of a deck you played (the
-- participant is you, whoever took it), across events, newest event first: the same rows as `deck_photos` plus the
-- event's id, name, format and date, so the clients can head them by event and reuse the per-photo actions
-- (deck_photo_note / _turn / _delete all let the player act on their own deck's photo).
-- Visibility follows deck_photo_visible for the player: a photo moderation hid shows only to whoever took it.
-- Demo events show only to demo testers. `total` and `events` count every one (not just the first `p_limit`), so the
-- Account row can ask for one photo and still say "12 photos · 5 events". Read only, so no audit row.

create index if not exists event_deck_photos_participant_idx on public.event_deck_photos (participant_id);

create or replace function public.my_deck_photos(p_limit integer default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_demo boolean := t1_private.is_demo_tester();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  return (
    select jsonb_build_object('total', count(*), 'events', count(distinct ph.event_id))
      from public.participants p
      join public.event_deck_photos ph on ph.participant_id = p.id
      join public.events e on e.id = ph.event_id
     where p.user_id = v_uid
       and (ph.hidden_at is null or ph.uploaded_by = v_uid)
       and (v_demo or not e.is_demo)
  ) || jsonb_build_object('photos', coalesce((
    select jsonb_agg(x.j order by x.event_at desc, x.event_id, x.created_at desc)
      from (
        select jsonb_build_object(
                 'id', ph.id, 'participant_id', ph.participant_id, 'player', p.display_name, 'path', ph.path,
                 'note', ph.note, 'created_at', ph.created_at, 'turns', ph.turns, 'mine', true, 'editable', true,
                 'event_id', e.id, 'event_name', e.name, 'event_status', e.status,
                 'format_label', coalesce(e.format_label, e.format_name, e.format),
                 'event_at', coalesce(e.starts_at, e.created_at)) as j,
               coalesce(e.starts_at, e.created_at) as event_at, e.id as event_id, ph.created_at
          from public.participants p
          join public.event_deck_photos ph on ph.participant_id = p.id
          join public.events e on e.id = ph.event_id
         where p.user_id = v_uid
           and (ph.hidden_at is null or ph.uploaded_by = v_uid)
           and (v_demo or not e.is_demo)
         order by coalesce(e.starts_at, e.created_at) desc, e.id, ph.created_at desc
         limit greatest(1, least(coalesce(p_limit, 200), 500))
      ) x), '[]'::jsonb));
end $$;
revoke execute on function public.my_deck_photos(integer) from public, anon;
grant execute on function public.my_deck_photos(integer) to authenticated;
