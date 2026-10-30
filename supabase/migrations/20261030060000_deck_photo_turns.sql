-- Deck photos turn after upload (contract/event-night-2026-10-16.md § 7, 2026-10-29): a photo that went up sideways
-- is set upright by the player or whoever took it. The file is never rewritten: only its uploader may overwrite it
-- (storage policy) and a new file would skip moderation. Instead the row keeps quarter turns clockwise (0-3) and
-- every client draws the photo turned. Updating `turns` doesn't touch path or note, so moderation isn't re-run.

alter table public.event_deck_photos add column if not exists turns smallint not null default 0
  check (turns between 0 and 3);

create or replace function public.deck_photo_turn(p_id uuid, p_turns int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ph public.event_deck_photos;
begin
  if p_turns is null or p_turns not between 0 and 3 then
    raise exception 'Turns are 0 to 3' using errcode = '22023';
  end if;
  select * into ph from public.event_deck_photos where id = p_id;
  if ph.id is null then raise exception 'Photo not found' using errcode = 'P0002'; end if;
  if ph.uploaded_by <> auth.uid()
     and not exists (select 1 from public.participants p where p.id = ph.participant_id and p.user_id = auth.uid()) then
    raise exception 'Only the player or whoever took it can turn it' using errcode = '42501';
  end if;
  if ph.turns <> p_turns then
    update public.event_deck_photos set turns = p_turns, updated_at = now() where id = p_id;
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
    values (ph.event_id, auth.uid(), 'deck_photo.turned', 'deck_photo', p_id,
            jsonb_build_object('turns', ph.turns), jsonb_build_object('turns', p_turns));
  end if;
  return public.deck_photos(ph.event_id);
end $$;
revoke execute on function public.deck_photo_turn(uuid, int) from public, anon;
grant execute on function public.deck_photo_turn(uuid, int) to authenticated;

-- As before, plus `turns`.
create or replace function public.deck_photos(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.in_event(p_event_id) then
    raise exception 'Only players in this event can see deck photos' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'event_id', p_event_id,
    'shared', exists (select 1 from public.events e where e.id = p_event_id and e.status in ('completed', 'archived')),
    'photos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', ph.id, 'participant_id', ph.participant_id, 'player', p.display_name, 'path', ph.path,
               'note', ph.note, 'created_at', ph.created_at, 'turns', ph.turns,
               'mine', coalesce(p.user_id = auth.uid(), false),
               'editable', ph.uploaded_by = auth.uid() or coalesce(p.user_id = auth.uid(), false))
             order by coalesce(p.user_id = auth.uid(), false) desc, p.display_name, ph.created_at desc)
        from public.event_deck_photos ph
        join public.participants p on p.id = ph.participant_id
       where ph.event_id = p_event_id and public.deck_photo_visible(ph)), '[]'::jsonb));
end $$;
