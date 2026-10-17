-- After the matches (2026-10-16): the redraft pile and deck photos.
--
-- Redraft: after a non-cube draft, the table sometimes redrafts the cards everyone opened. Anyone in the event
-- (organizer or a seated account) scans those cards into the event's pile; it lists most valuable first
-- (TCGplayer market, the finish scanned) and stays with the event. Cube drafts have no redraft (the cube goes
-- home with its owner).
--
-- Deck photos: players photograph their deck (and the organizer can for anyone, guests included), with a note,
-- during or after the event. Each player always sees their own; everyone in the event sees all of them once the
-- event is over. Files live in the private `deck-photos` bucket at <event_id>/<photo_id>.jpg.

-- ---------------------------------------------------------------- helpers

create or replace function public.in_event(p_event_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_event_organizer(p_event_id)
      or exists (select 1 from public.participants p where p.event_id = p_event_id and p.user_id = auth.uid());
$$;
revoke execute on function public.in_event(uuid) from public, anon;
grant execute on function public.in_event(uuid) to authenticated;

-- ---------------------------------------------------------------- redraft

create table if not exists public.event_redraft_cards (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  card_id uuid not null references public.cards (id),
  finish text not null default 'nonfoil' check (finish in ('nonfoil', 'foil', 'etched')),
  added_by uuid,
  added_at timestamptz not null default now()
);
create index if not exists event_redraft_cards_event_idx on public.event_redraft_cards (event_id);
alter table public.event_redraft_cards enable row level security;  -- RPCs only

create or replace function public._redraft_check(p_event_id uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event_id;
  if e.id is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if not public.in_event(p_event_id) then
    raise exception 'Only players in this event can do that' using errcode = '42501';
  end if;
  if coalesce(e.format_name, e.format) not in ('draft', 'team_draft') or nullif(e.cube_name, '') is not null
     or nullif(e.cube_url, '') is not null then
    raise exception 'Redrafts are for set drafts, not cubes' using errcode = '55000';
  end if;
  if e.status not in ('completed', 'archived') then
    raise exception 'The redraft opens when the event is finished' using errcode = '55000';
  end if;
end $$;

-- Most valuable first; cards with no market price last, then by name.
create or replace function public.redraft_list(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.in_event(p_event_id) then
    raise exception 'Only players in this event can see the redraft' using errcode = '42501';
  end if;
  return (
    with rows as (
      select r.id, r.card_id, r.finish, r.added_at, o.name, c.set_code, c.collector_number, c.image_ts, c.image_faces,
             case r.finish when 'foil' then pr.usd_foil when 'etched' then pr.usd_etched else pr.usd end as usd,
             coalesce(p.display_name, 'Organizer') as added_by_name, coalesce(r.added_by = auth.uid(), false) as mine
        from public.event_redraft_cards r
        join public.cards c on c.id = r.card_id
        join public.card_oracles o on o.oracle_id = c.oracle_id
        left join public.card_prices pr on pr.card_id = r.card_id
        left join public.participants p on p.event_id = r.event_id and p.user_id = r.added_by
       where r.event_id = p_event_id)
    select jsonb_build_object(
      'event_id', p_event_id,
      'count', count(*),
      'total_usd', coalesce(sum(usd), 0),
      'cards', coalesce(jsonb_agg(jsonb_build_object(
          'id', id, 'card_id', card_id, 'finish', finish, 'name', name, 'set', set_code, 'cn', collector_number,
          'image_ts', image_ts, 'image_faces', image_faces, 'usd', usd, 'added_by', added_by_name,
          'mine', mine, 'added_at', added_at)
        order by usd desc nulls last, name, added_at), '[]'::jsonb))
      from rows);
end $$;

-- p_cards: [{"card_id", "finish"}], up to 200 at a time.
create or replace function public.redraft_add(p_event_id uuid, p_cards jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  perform public._redraft_check(p_event_id);
  if jsonb_typeof(p_cards) <> 'array' or jsonb_array_length(p_cards) > 200 then
    raise exception 'Add up to 200 cards at a time' using errcode = '22023';
  end if;
  insert into public.event_redraft_cards (event_id, card_id, finish, added_by)
  select p_event_id, x.card_id, case when x.finish in ('foil', 'etched') then x.finish else 'nonfoil' end, auth.uid()
    from jsonb_to_recordset(p_cards) as x(card_id uuid, finish text)
    join public.cards c on c.id = x.card_id;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
    values (p_event_id, auth.uid(), 'redraft.added', 'event', p_event_id, jsonb_build_object('cards', v_n));
  end if;
  return public.redraft_list(p_event_id);
end $$;

create or replace function public.redraft_remove(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.event_redraft_cards;
begin
  select * into r from public.event_redraft_cards where id = p_id;
  if r.id is null then raise exception 'Card not found' using errcode = 'P0002'; end if;
  perform public._redraft_check(r.event_id);
  delete from public.event_redraft_cards where id = p_id;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before)
  values (r.event_id, auth.uid(), 'redraft.removed', 'redraft_card', r.id,
          jsonb_build_object('card_id', r.card_id, 'finish', r.finish, 'added_by', r.added_by));
  return public.redraft_list(r.event_id);
end $$;

revoke execute on function public._redraft_check(uuid) from public, anon, authenticated;
revoke execute on function public.redraft_list(uuid) from public, anon;
revoke execute on function public.redraft_add(uuid, jsonb) from public, anon;
revoke execute on function public.redraft_remove(uuid) from public, anon;
grant execute on function public.redraft_list(uuid) to authenticated;
grant execute on function public.redraft_add(uuid, jsonb) to authenticated;
grant execute on function public.redraft_remove(uuid) to authenticated;

-- ---------------------------------------------------------------- deck photos

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('deck-photos', 'deck-photos', false, 10485760, array['image/jpeg'])
on conflict (id) do nothing;

create table if not exists public.event_deck_photos (
  id uuid primary key,
  event_id uuid not null references public.events (id) on delete cascade,
  participant_id uuid not null references public.participants (id) on delete cascade,
  uploaded_by uuid not null,
  path text not null unique,
  note text not null default '' check (char_length(note) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists event_deck_photos_event_idx on public.event_deck_photos (event_id);
alter table public.event_deck_photos enable row level security;  -- RPCs only

-- Who sees a photo: whoever took it, the player it belongs to, the organizer, and everyone in the event once
-- it's over.
create or replace function public.deck_photo_visible(ph public.event_deck_photos)
returns boolean language sql stable security definer set search_path = '' as $$
  select ph.uploaded_by = auth.uid()
      or exists (select 1 from public.participants p where p.id = ph.participant_id and p.user_id = auth.uid())
      or public.is_event_organizer(ph.event_id)
      or (public.in_event(ph.event_id)
          and exists (select 1 from public.events e where e.id = ph.event_id and e.status in ('completed', 'archived')));
$$;
revoke execute on function public.deck_photo_visible(public.event_deck_photos) from public, anon;

-- Storage: uploads go under an event you're in; reads follow deck_photo_visible (or your own fresh upload).
create or replace function public.deck_photo_object_readable(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.event_deck_photos ph where ph.path = p_name and public.deck_photo_visible(ph));
$$;
create or replace function public.deck_photo_upload_ok(p_name text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_event uuid;
begin
  begin
    v_event := split_part(p_name, '/', 1)::uuid;
  exception when others then
    return false;
  end;
  return public.in_event(v_event)
     and exists (select 1 from public.events e where e.id = v_event and e.status <> 'cancelled');
end $$;
revoke execute on function public.deck_photo_object_readable(text) from public, anon;
revoke execute on function public.deck_photo_upload_ok(text) from public, anon;
grant execute on function public.deck_photo_object_readable(text) to authenticated;
grant execute on function public.deck_photo_upload_ok(text) to authenticated;

drop policy if exists deck_photos_insert on storage.objects;
create policy deck_photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'deck-photos' and public.deck_photo_upload_ok(name));
drop policy if exists deck_photos_read on storage.objects;
create policy deck_photos_read on storage.objects for select to authenticated
  using (bucket_id = 'deck-photos' and (owner_id = (select auth.uid())::text or public.deck_photo_object_readable(name)));
-- Upsert on retry needs update; only your own file.
drop policy if exists deck_photos_update on storage.objects;
create policy deck_photos_update on storage.objects for update to authenticated
  using (bucket_id = 'deck-photos' and owner_id = (select auth.uid())::text);
drop policy if exists deck_photos_delete on storage.objects;
create policy deck_photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'deck-photos' and owner_id = (select auth.uid())::text);

-- After the file is uploaded to <event_id>/<p_id>.jpg. Players add their own; the organizer adds for anyone.
create or replace function public.deck_photo_add(p_id uuid, p_event_id uuid, p_participant_id uuid, p_note text default '')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_path text := p_event_id::text || '/' || p_id::text || '.jpg';
  v_mine boolean;
begin
  select coalesce(p.user_id = auth.uid(), false) into v_mine from public.participants p
   where p.id = p_participant_id and p.event_id = p_event_id;
  if v_mine is null then raise exception 'Player not found' using errcode = 'P0002'; end if;
  if not v_mine and not public.is_event_organizer(p_event_id) then
    raise exception 'You can only add photos of your own deck' using errcode = '42501';
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'deck-photos' and o.name = v_path) then
    raise exception 'Upload the photo first' using errcode = '22023';
  end if;
  insert into public.event_deck_photos (id, event_id, participant_id, uploaded_by, path, note)
  values (p_id, p_event_id, p_participant_id, auth.uid(), v_path, left(coalesce(p_note, ''), 2000))
  on conflict (id) do nothing;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, auth.uid(), 'deck_photo.added', 'participant', p_participant_id, jsonb_build_object('photo_id', p_id));
  return public.deck_photos(p_event_id);
end $$;

create or replace function public.deck_photo_note(p_id uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ph public.event_deck_photos;
begin
  select * into ph from public.event_deck_photos where id = p_id;
  if ph.id is null then raise exception 'Photo not found' using errcode = 'P0002'; end if;
  if ph.uploaded_by <> auth.uid()
     and not exists (select 1 from public.participants p where p.id = ph.participant_id and p.user_id = auth.uid()) then
    raise exception 'Only the player or whoever took it can edit the note' using errcode = '42501';
  end if;
  update public.event_deck_photos set note = left(coalesce(p_note, ''), 2000), updated_at = now() where id = p_id;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
  values (ph.event_id, auth.uid(), 'deck_photo.note', 'deck_photo', p_id,
          jsonb_build_object('note', ph.note), jsonb_build_object('note', left(coalesce(p_note, ''), 2000)));
  return public.deck_photos(ph.event_id);
end $$;

create or replace function public.deck_photo_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ph public.event_deck_photos;
begin
  select * into ph from public.event_deck_photos where id = p_id;
  if ph.id is null then raise exception 'Photo not found' using errcode = 'P0002'; end if;
  if ph.uploaded_by <> auth.uid()
     and not exists (select 1 from public.participants p where p.id = ph.participant_id and p.user_id = auth.uid()) then
    raise exception 'Only the player or whoever took it can remove it' using errcode = '42501';
  end if;
  delete from public.event_deck_photos where id = p_id;
  -- The app removes the file (storage rows can't be deleted from SQL); an orphaned file is unreadable anyway,
  -- since reads need a photo row.
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before)
  values (ph.event_id, auth.uid(), 'deck_photo.removed', 'deck_photo', p_id,
          jsonb_build_object('participant_id', ph.participant_id, 'note', ph.note));
  return public.deck_photos(ph.event_id);
end $$;

-- The photos this account can see, by player, newest first. `editable`: note and delete allowed.
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
               'note', ph.note, 'created_at', ph.created_at,
               'mine', coalesce(p.user_id = auth.uid(), false),
               'editable', ph.uploaded_by = auth.uid() or coalesce(p.user_id = auth.uid(), false))
             order by coalesce(p.user_id = auth.uid(), false) desc, p.display_name, ph.created_at desc)
        from public.event_deck_photos ph
        join public.participants p on p.id = ph.participant_id
       where ph.event_id = p_event_id and public.deck_photo_visible(ph)), '[]'::jsonb));
end $$;

revoke execute on function public.deck_photo_add(uuid, uuid, uuid, text) from public, anon;
revoke execute on function public.deck_photo_note(uuid, text) from public, anon;
revoke execute on function public.deck_photo_delete(uuid) from public, anon;
revoke execute on function public.deck_photos(uuid) from public, anon;
grant execute on function public.deck_photo_add(uuid, uuid, uuid, text) to authenticated;
grant execute on function public.deck_photo_note(uuid, text) to authenticated;
grant execute on function public.deck_photo_delete(uuid) to authenticated;
grant execute on function public.deck_photos(uuid) to authenticated;
