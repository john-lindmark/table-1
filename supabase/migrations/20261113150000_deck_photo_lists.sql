-- Decklists read from deck photos (contract/deck-photo-lists-2026-11-13.md).
-- Every deck photo gets a decklist: adding a photo queues a read, the deck-photo-read function looks at the photo
-- with the event's card pool as a hint (the set's cards, the cube's list, or nothing for constructed and events
-- that didn't record their set), and the list is kept beside the photo. Whoever may edit the photo (its player,
-- whoever took it, the organizer) corrects the list; everyone who sees the photo sees the list and can copy it to
-- their own decks with list_create. A job like the deck finder's: queued → reading → done | failed, with the
-- steps on the row, a sweep that re-sends an unclaimed job, and one `deck.read` push to the player.
--
-- An entry: {card_id | null, name, qty, board: main | side | out, sure, read?}. `out` holds cards the photo shows
-- that aren't in the deck (lying sideways to the rest, strays off the mat): shown for correcting, never counted.
-- card_id null = a title the reader couldn't match to a card; the player picks the card.

create table if not exists t1_private.deck_photo_lists (
  photo_id uuid primary key references public.event_deck_photos (id) on delete cascade,
  status text not null default 'queued' check (status in ('queued', 'reading', 'done', 'failed')),
  steps jsonb not null default '[]'::jsonb,
  -- What the reader made of the photo, never edited: {cards, notes, model, pool: {kind, label, size}}.
  read jsonb,
  -- The list as it stands: the read, then whatever was corrected.
  entries jsonb not null default '[]'::jsonb,
  message text,
  edited_by uuid,
  edited_at timestamptz,
  asked_by uuid,
  reads integer not null default 0,
  attempts integer not null default 0,
  request_id bigint,
  pushed_at timestamptz,
  created_at timestamptz not null default now(),
  queued_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz
);
alter table t1_private.deck_photo_lists enable row level security;  -- RPCs only
create index if not exists deck_photo_lists_open_idx on t1_private.deck_photo_lists (queued_at) where status in ('queued', 'reading');

-- ---------------------------------------------------------------- who may do what

-- Correcting the list: the photo's player, whoever took it, or the event's organizer.
create or replace function t1_private.deck_photo_list_editor(ph public.event_deck_photos)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null
     and (ph.uploaded_by = auth.uid()
          or exists (select 1 from public.participants p where p.id = ph.participant_id and p.user_id = auth.uid())
          or public.is_event_organizer(ph.event_id));
$$;

-- ---------------------------------------------------------------- the card pool

-- The cards a deck in this event was built from, as a hint for the reader: {kind, label, cards: [[name, card_id]]}.
--   set   the event's set: one English printing per card (lowest collector number)
--   cube  a cube named like the event's, owned by its creator, an organizer or a player (the fullest one)
--   none  constructed events and events that recorded neither (cards: [])
-- Never a filter: packs hold cards filed under other sets (The List, bonus sheets), and basics come from anywhere.
create or replace function t1_private.deck_photo_pool(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare e public.events; v_cards jsonb; v_list uuid;
begin
  select * into e from public.events where id = p_event_id;
  if e.id is null then return jsonb_build_object('kind', 'none', 'label', '', 'cards', '[]'::jsonb); end if;
  if nullif(btrim(coalesce(e.set_code, '')), '') is not null then
    select jsonb_agg(jsonb_build_array(s.name, s.id) order by s.name) into v_cards
      from (select distinct on (c.oracle_id) o.name, c.id
              from public.cards c join public.card_oracles o on o.oracle_id = c.oracle_id
             where c.set_code = lower(btrim(e.set_code)) and c.lang = 'en'
             order by c.oracle_id, (c.collector_number ~ '^[0-9]+$') desc, length(c.collector_number), c.collector_number) s;
    if v_cards is not null then
      return jsonb_build_object('kind', 'set', 'label', coalesce(nullif(e.set_name, ''), upper(e.set_code)), 'cards', v_cards);
    end if;
  end if;
  if nullif(btrim(coalesce(e.cube_name, '')), '') is not null then
    select l.id into v_list
      from public.card_lists l
     where l.kind = 'cube' and l.deleted_at is null and lower(btrim(l.name)) = lower(btrim(e.cube_name))
       and (l.user_id = e.created_by
            or exists (select 1 from public.event_members m where m.event_id = e.id and m.user_id = l.user_id)
            or exists (select 1 from public.participants p where p.event_id = e.id and p.user_id = l.user_id))
     order by (l.user_id = e.created_by) desc,
              (select count(*) from public.card_list_entries x where x.list_id = l.id and x.board = 'main') desc,
              l.updated_at desc
     limit 1;
    if v_list is not null then
      select jsonb_agg(jsonb_build_array(s.name, s.id) order by s.name) into v_cards
        from (select distinct on (c.oracle_id) o.name, c.id
                from public.card_list_entries x
                join public.cards c on c.id = x.card_id
                join public.card_oracles o on o.oracle_id = c.oracle_id
               where x.list_id = v_list and x.board = 'main'
               order by c.oracle_id, c.id) s;
      if v_cards is not null then
        return jsonb_build_object('kind', 'cube', 'label', btrim(e.cube_name), 'cards', v_cards);
      end if;
    end if;
  end if;
  return jsonb_build_object('kind', 'none', 'label', coalesce(e.format_label, e.format_name, e.format, ''), 'cards', '[]'::jsonb);
end $$;

-- A card's usual printing (the catalog pack's "original": earliest English paper printing with an image).
create or replace function t1_private.deck_photo_printing(p_oracle uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select c.id
    from public.cards c left join public.mtg_sets s on s.code = c.set_code
   where c.oracle_id = p_oracle
   order by (c.lang = 'en' and c.image_faces > 0
               and coalesce(s.set_type, '') not in ('promo', 'token', 'memorabilia', 'alchemy', 'minigame')) desc,
            (c.lang = 'en' and c.image_faces > 0) desc,
            c.released_at nulls last,
            (c.collector_number ~ '^[0-9]+$') desc,
            length(c.collector_number), c.collector_number, c.set_code
   limit 1;
$$;

-- Names the reader gave, against the whole catalog: [{q, name, card_id, exact}] (name/card_id null = no such card).
-- The exact name (or a face's) first; else the closest name by trigram at 0.6 or more, marked exact: false.
create or replace function public.deck_photo_read_names(p_names text[])
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'q', q.name, 'name', o.name, 'card_id', t1_private.deck_photo_printing(m.oracle_id), 'exact', m.exact) order by q.n), '[]'::jsonb)
    from (select name, n from unnest(p_names[1:200]) with ordinality t(name, n)) q
    left join lateral (
      select x.oracle_id, x.exact from (
        (select n.oracle_id, true as exact, 0 as o, (not n.is_face)::int::real as s
           from public.card_names n
          where n.name_norm = public.card_name_norm(q.name)
             or n.name_norm = public.card_name_norm(split_part(q.name, ' // ', 1))
          order by (n.name_norm = public.card_name_norm(q.name)) desc, n.is_face, n.oracle_id limit 1)
        union all
        (select n.oracle_id, false, 1, extensions.similarity(n.name_norm, public.card_name_norm(q.name))
           from public.card_names n
          where length(public.card_name_norm(q.name)) >= 4
            and n.name_norm operator(extensions.%) public.card_name_norm(q.name)
            and not n.is_face
            and extensions.similarity(n.name_norm, public.card_name_norm(q.name)) >= 0.6
          order by 4 desc, n.oracle_id limit 1)
      ) x order by x.o limit 1
    ) m on true
    left join public.card_oracles o on o.oracle_id = m.oracle_id;
$$;

-- ---------------------------------------------------------------- the job

create or replace function t1_private.deck_photo_read_kick(p_photo_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret text; v_req bigint;
begin
  select value into v_secret from t1_private.settings where name = 'live_push_secret';
  v_req := net.http_post(
    url := 'https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/deck-photo-read',
    body := jsonb_build_object('photo_id', p_photo_id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-t1-secret', v_secret),
    timeout_milliseconds := 20000);
  update t1_private.deck_photo_lists set request_id = v_req, attempts = attempts + 1 where photo_id = p_photo_id;
exception when others then
  raise warning 'deck_photo_read_kick skipped: %', sqlerrm;
end $$;

-- Queues a read of one photo (a first read, or again). Returns false when one is already under way.
create or replace function t1_private.deck_photo_read_queue(p_photo_id uuid, p_asked_by uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_status text;
begin
  select status into v_status from t1_private.deck_photo_lists where photo_id = p_photo_id for update;
  if v_status in ('queued', 'reading') then return false; end if;
  insert into t1_private.deck_photo_lists (photo_id, asked_by) values (p_photo_id, p_asked_by)
  on conflict (photo_id) do update
    set status = 'queued', steps = '[]'::jsonb, message = null, asked_by = excluded.asked_by, attempts = 0,
        queued_at = now(), started_at = null, finished_at = null;
  perform t1_private.deck_photo_read_kick(p_photo_id);
  return true;
end $$;

-- A new photo is read at once (not demo events: their photos are made up). Never fails the photo's own write.
create or replace function t1_private.deck_photo_read_on_add()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    if not exists (select 1 from public.events e where e.id = new.event_id and e.is_demo) then
      perform t1_private.deck_photo_read_queue(new.id, null);
    end if;
  exception when others then
    raise warning 'deck_photo_read_on_add skipped: %', sqlerrm;
  end;
  return new;
end $$;
drop trigger if exists deck_photo_read_on_add on public.event_deck_photos;
create trigger deck_photo_read_on_add after insert on public.event_deck_photos
  for each row execute function t1_private.deck_photo_read_on_add();

-- The list as a viewer reads it.
create or replace function t1_private.deck_photo_list_json(ph public.event_deck_photos)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'photo_id', ph.id, 'event_id', ph.event_id, 'participant_id', ph.participant_id,
    'player', (select p.display_name from public.participants p where p.id = ph.participant_id),
    'path', ph.path, 'turns', ph.turns, 'note', ph.note,
    'status', coalesce(l.status, 'none'), 'steps', coalesce(l.steps, '[]'::jsonb),
    'entries', coalesce(l.entries, '[]'::jsonb), 'message', l.message,
    'notes', l.read->>'notes',
    'pool', coalesce(l.read->'pool', '{}'::jsonb),
    'checked', l.edited_at is not null,
    'editable', t1_private.deck_photo_list_editor(ph),
    'mine', exists (select 1 from public.participants p where p.id = ph.participant_id and p.user_id = auth.uid()),
    'reads_left', greatest(0, 5 - coalesce(l.reads, 0)),
    'finished_at', l.finished_at,
    'event', (select jsonb_build_object('name', e.name, 'format', coalesce(e.format_name, e.format), 'event_type', e.event_type,
                                         'format_label', coalesce(e.format_label, e.format_name, e.format))
                from public.events e where e.id = ph.event_id))
    from (select 1) one
    left join t1_private.deck_photo_lists l on l.photo_id = ph.id;
$$;

-- A photo's decklist, for anyone who can see the photo.
create or replace function public.deck_photo_list(p_photo_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare ph public.event_deck_photos;
begin
  if auth.uid() is null then raise exception 'Sign in to see decklists' using errcode = '28000'; end if;
  select * into ph from public.event_deck_photos where id = p_photo_id;
  if ph.id is null or not public.deck_photo_visible(ph) or (ph.hidden_at is not null and ph.uploaded_by <> auth.uid()) then
    raise exception 'Photo not found' using errcode = 'P0002';
  end if;
  return t1_private.deck_photo_list_json(ph);
end $$;

-- Read this photo (when it has no list yet: anyone who sees it) or read it again (its editors; five reads a photo).
create or replace function public.deck_photo_read_start(p_photo_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ph public.event_deck_photos; l t1_private.deck_photo_lists;
begin
  if auth.uid() is null then raise exception 'Sign in to read decklists' using errcode = '28000'; end if;
  select * into ph from public.event_deck_photos where id = p_photo_id;
  if ph.id is null or not public.deck_photo_visible(ph) or (ph.hidden_at is not null and ph.uploaded_by <> auth.uid()) then
    raise exception 'Photo not found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.events e where e.id = ph.event_id and e.is_demo) then
    raise exception 'Demo photos have no decklist' using errcode = '22023';
  end if;
  select * into l from t1_private.deck_photo_lists where photo_id = p_photo_id;
  if l.photo_id is not null and l.status in ('queued', 'reading') then return t1_private.deck_photo_list_json(ph); end if;
  if l.photo_id is not null and l.status = 'done' and not t1_private.deck_photo_list_editor(ph) then
    raise exception 'Only the player, whoever took the photo or the organizer can read it again' using errcode = '42501';
  end if;
  if coalesce(l.reads, 0) >= 5 then
    raise exception 'This photo has been read five times. Correct the list by hand.' using errcode = 'P0001';
  end if;
  perform t1_private.deck_photo_read_queue(p_photo_id, auth.uid());
  return t1_private.deck_photo_list_json(ph);
end $$;

-- The function takes a queued read (null when it's gone or already taken): the photo, the event and its pool.
create or replace function public.deck_photo_read_claim(p_photo_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ph public.event_deck_photos; e public.events;
begin
  update t1_private.deck_photo_lists set status = 'reading', started_at = now(), reads = reads + 1
   where photo_id = p_photo_id and status = 'queued';
  if not found then return null; end if;
  select * into ph from public.event_deck_photos where id = p_photo_id;
  select * into e from public.events where id = ph.event_id;
  return jsonb_build_object(
    'photo_id', ph.id, 'path', ph.path, 'turns', ph.turns,
    'event', jsonb_build_object('name', e.name, 'event_type', e.event_type, 'format', coalesce(e.format_name, e.format),
                                'format_label', coalesce(e.format_label, e.format_name, e.format)),
    'pool', t1_private.deck_photo_pool(ph.event_id));
end $$;

-- What a read would be given, without taking anything (the function's eval path).
create or replace function public.deck_photo_read_peek(p_photo_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'photo_id', ph.id, 'path', ph.path, 'turns', ph.turns,
    'event', jsonb_build_object('name', e.name, 'event_type', e.event_type, 'format', coalesce(e.format_name, e.format),
                                'format_label', coalesce(e.format_label, e.format_name, e.format)),
    'pool', t1_private.deck_photo_pool(ph.event_id))
    from public.event_deck_photos ph join public.events e on e.id = ph.event_id
   where ph.id = p_photo_id;
$$;

create or replace function public.deck_photo_read_progress(p_photo_id uuid, p_steps jsonb)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_steps jsonb;
begin
  select coalesce(jsonb_agg(left(s, 200) order by n), '[]'::jsonb) into v_steps
    from (select s, n from jsonb_array_elements_text(case when jsonb_typeof(p_steps) = 'array' then p_steps else '[]'::jsonb end) with ordinality t(s, n)
           where btrim(s) <> '' order by n limit 20) q;
  update t1_private.deck_photo_lists set steps = v_steps where photo_id = p_photo_id and status = 'reading';
  return found;
end $$;

-- Entries as stored: known cards only by id (the name comes from the catalog), qty 1–99, a known board, 250 lines.
create or replace function t1_private.deck_photo_entries_clean(p_entries jsonb)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'card_id', c.id,
           'name', coalesce(o.name, left(btrim(x.e->>'name'), 80)),
           'qty', least(99, greatest(1, coalesce((x.e->>'qty')::int, 1))),
           'board', case when x.e->>'board' in ('side', 'out') then x.e->>'board' else 'main' end,
           'sure', coalesce((x.e->>'sure')::boolean, true),
           'read', nullif(left(btrim(coalesce(x.e->>'read', '')), 120), ''))) order by x.n), '[]'::jsonb)
    from (select e, n from jsonb_array_elements(case when jsonb_typeof(p_entries) = 'array' then p_entries else '[]'::jsonb end)
            with ordinality t(e, n) order by n limit 250) x
    left join public.cards c on c.id = case when x.e->>'card_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                                            then (x.e->>'card_id')::uuid end
    left join public.card_oracles o on o.oracle_id = c.oracle_id
   where c.id is not null or btrim(coalesce(x.e->>'name', '')) <> '';
$$;

-- The function's answer ends the read: {status: done | failed, cards, notes, model, pool: {kind, label, size},
-- message}. A done read replaces the list (a read asked again is asked to start over); a failed one keeps what
-- was there. The player is told once per photo, when a list with cards first exists.
create or replace function public.deck_photo_read_finish(p_photo_id uuid, p_result jsonb)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  l t1_private.deck_photo_lists; ph public.event_deck_photos; e public.events;
  v_done boolean := coalesce(p_result->>'status', 'failed') = 'done';
  v_entries jsonb; v_uid uuid; v_cards int; v_check int;
begin
  select * into l from t1_private.deck_photo_lists where photo_id = p_photo_id and status in ('queued', 'reading') for update;
  if l.photo_id is null then return false; end if;
  if not v_done then
    update t1_private.deck_photo_lists
       set status = case when read is null then 'failed' else 'done' end,
           message = left(coalesce(p_result->>'message', 'The photo couldn''t be read just now.'), 200), finished_at = now()
     where photo_id = p_photo_id;
    return true;
  end if;
  v_entries := t1_private.deck_photo_entries_clean(p_result->'cards');
  update t1_private.deck_photo_lists
     set status = 'done', entries = v_entries, message = null, edited_by = null, edited_at = null, finished_at = now(),
         read = jsonb_build_object('cards', v_entries, 'notes', left(coalesce(p_result->>'notes', ''), 300),
                                   'model', p_result->>'model', 'pool', coalesce(p_result->'pool', '{}'::jsonb))
   where photo_id = p_photo_id;
  select coalesce(sum((x->>'qty')::int) filter (where x->>'board' <> 'out'), 0),
         count(*) filter (where x->>'board' <> 'out' and (x->>'card_id' is null or not coalesce((x->>'sure')::boolean, true)))
    into v_cards, v_check from jsonb_array_elements(v_entries) x;
  if l.pushed_at is null and v_cards > 0 then
    select * into ph from public.event_deck_photos where id = p_photo_id;
    select * into e from public.events where id = ph.event_id;
    select p.user_id into v_uid from public.participants p where p.id = ph.participant_id;
    if v_uid is not null and not e.is_demo and ph.hidden_at is null then
      update t1_private.deck_photo_lists set pushed_at = now() where photo_id = p_photo_id;
      perform public.enqueue_notification('deck.read', ph.event_id, array[v_uid],
        jsonb_build_object('photo_id', p_photo_id, 'event_name', e.name, 'cards', v_cards, 'check', v_check));
    end if;
  end if;
  return true;
end $$;

-- Every minute: an unclaimed read is sent again (three tries), one that ran too long is failed.
create or replace function t1_private.deck_photo_read_sweep()
returns void language plpgsql security definer set search_path = '' as $$
declare r record;
  v_timeout constant jsonb := jsonb_build_object('status', 'failed', 'message', 'The photo couldn''t be read just now. Try again.');
begin
  for r in select photo_id from t1_private.deck_photo_lists
            where status = 'queued' and queued_at < now() - interval '45 seconds' and attempts < 3 loop
    perform t1_private.deck_photo_read_kick(r.photo_id);
  end loop;
  for r in select photo_id from t1_private.deck_photo_lists
            where (status = 'queued' and queued_at < now() - interval '45 seconds' and attempts >= 3)
               or (status = 'reading' and started_at < now() - interval '4 minutes') loop
    perform public.deck_photo_read_finish(r.photo_id, v_timeout);
  end loop;
end $$;

-- ---------------------------------------------------------------- correcting

-- Saves the corrected list (the whole list each time). Audited with the counts, not the cards.
create or replace function public.deck_photo_list_save(p_photo_id uuid, p_entries jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ph public.event_deck_photos; v_entries jsonb; v_before int; v_after int;
begin
  if auth.uid() is null then raise exception 'Sign in to correct decklists' using errcode = '28000'; end if;
  select * into ph from public.event_deck_photos where id = p_photo_id;
  if ph.id is null or not public.deck_photo_visible(ph) then raise exception 'Photo not found' using errcode = 'P0002'; end if;
  if not t1_private.deck_photo_list_editor(ph) then
    raise exception 'Only the player, whoever took the photo or the organizer can correct this list' using errcode = '42501';
  end if;
  if jsonb_typeof(p_entries) is distinct from 'array' then raise exception 'A list of cards' using errcode = '22023'; end if;
  if jsonb_array_length(p_entries) > 250 then raise exception 'At most 250 lines' using errcode = '22023'; end if;
  v_entries := t1_private.deck_photo_entries_clean(p_entries);
  insert into t1_private.deck_photo_lists (photo_id, status, asked_by) values (p_photo_id, 'done', auth.uid())
  on conflict (photo_id) do nothing;
  select coalesce(sum((x->>'qty')::int) filter (where x->>'board' <> 'out'), 0) into v_before
    from t1_private.deck_photo_lists l, jsonb_array_elements(l.entries) x where l.photo_id = p_photo_id;
  select coalesce(sum((x->>'qty')::int) filter (where x->>'board' <> 'out'), 0) into v_after from jsonb_array_elements(v_entries) x;
  update t1_private.deck_photo_lists
     set entries = v_entries, edited_by = auth.uid(), edited_at = now(),
         status = case when status in ('queued', 'reading') then status else 'done' end
   where photo_id = p_photo_id;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
  values (ph.event_id, auth.uid(), 'deck_photo.list_saved', 'deck_photo', p_photo_id,
          jsonb_build_object('cards', coalesce(v_before, 0)), jsonb_build_object('cards', v_after, 'lines', jsonb_array_length(v_entries)));
  return t1_private.deck_photo_list_json(ph);
end $$;

-- ---------------------------------------------------------------- photo rows carry their list's state

-- {status, cards, check, checked} for a photo row (null when the photo was never queued).
create or replace function t1_private.deck_photo_list_brief(p_photo_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
           'status', l.status,
           'cards', (select coalesce(sum((x->>'qty')::int) filter (where x->>'board' <> 'out'), 0) from jsonb_array_elements(l.entries) x),
           'check', (select count(*) filter (where x->>'board' <> 'out' and (x->>'card_id' is null or not coalesce((x->>'sure')::boolean, true)))
                       from jsonb_array_elements(l.entries) x),
           'checked', l.edited_at is not null)
    from t1_private.deck_photo_lists l where l.photo_id = p_photo_id;
$$;

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
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'id', ph.id, 'participant_id', ph.participant_id, 'player', p.display_name, 'path', ph.path,
               'note', ph.note, 'created_at', ph.created_at, 'turns', ph.turns,
               'mine', coalesce(p.user_id = auth.uid(), false),
               'editable', ph.uploaded_by = auth.uid() or coalesce(p.user_id = auth.uid(), false),
               'list', t1_private.deck_photo_list_brief(ph.id)))
             order by coalesce(p.user_id = auth.uid(), false) desc, p.display_name, ph.created_at desc)
        from public.event_deck_photos ph
        join public.participants p on p.id = ph.participant_id
       where ph.event_id = p_event_id and public.deck_photo_visible(ph)), '[]'::jsonb));
end $$;

-- Account → Deck photos rows carry it too (my_deck_photos as in 20261106170000, plus `list`).
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
        select jsonb_strip_nulls(jsonb_build_object(
                 'id', ph.id, 'participant_id', ph.participant_id, 'player', p.display_name, 'path', ph.path,
                 'note', ph.note, 'created_at', ph.created_at, 'turns', ph.turns, 'mine', true, 'editable', true,
                 'event_id', e.id, 'event_name', e.name, 'event_status', e.status,
                 'format_label', coalesce(e.format_label, e.format_name, e.format),
                 'event_at', coalesce(e.starts_at, e.created_at),
                 'list', t1_private.deck_photo_list_brief(ph.id))) as j,
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

-- ---------------------------------------------------------------- grants and the sweep

revoke execute on function t1_private.deck_photo_list_editor(public.event_deck_photos) from public, anon, authenticated;
revoke execute on function t1_private.deck_photo_pool(uuid) from public, anon, authenticated;
revoke execute on function t1_private.deck_photo_printing(uuid) from public, anon, authenticated;
revoke execute on function t1_private.deck_photo_read_kick(uuid) from public, anon, authenticated;
revoke execute on function t1_private.deck_photo_read_queue(uuid, uuid) from public, anon, authenticated;
revoke execute on function t1_private.deck_photo_read_on_add() from public, anon, authenticated;
revoke execute on function t1_private.deck_photo_list_json(public.event_deck_photos) from public, anon, authenticated;
revoke execute on function t1_private.deck_photo_entries_clean(jsonb) from public, anon, authenticated;
revoke execute on function t1_private.deck_photo_read_sweep() from public, anon, authenticated;
revoke execute on function t1_private.deck_photo_list_brief(uuid) from public, anon, authenticated;

revoke execute on function public.deck_photo_read_names(text[]) from public, anon, authenticated;
revoke execute on function public.deck_photo_read_claim(uuid) from public, anon, authenticated;
revoke execute on function public.deck_photo_read_peek(uuid) from public, anon, authenticated;
revoke execute on function public.deck_photo_read_progress(uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.deck_photo_read_finish(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.deck_photo_read_names(text[]) to service_role;
grant execute on function public.deck_photo_read_claim(uuid) to service_role;
grant execute on function public.deck_photo_read_peek(uuid) to service_role;
grant execute on function public.deck_photo_read_progress(uuid, jsonb) to service_role;
grant execute on function public.deck_photo_read_finish(uuid, jsonb) to service_role;

revoke execute on function public.deck_photo_list(uuid) from public, anon;
revoke execute on function public.deck_photo_read_start(uuid) from public, anon;
revoke execute on function public.deck_photo_list_save(uuid, jsonb) from public, anon;
grant execute on function public.deck_photo_list(uuid) to authenticated;
grant execute on function public.deck_photo_read_start(uuid) to authenticated;
grant execute on function public.deck_photo_list_save(uuid, jsonb) to authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-deck-photo-read-sweep') then
      perform cron.schedule('t1-deck-photo-read-sweep', '* * * * *',
        $c$select t1_private.deck_photo_read_sweep() where exists (select 1 from t1_private.deck_photo_lists where status in ('queued', 'reading'))$c$);
    end if;
  end if;
end $$;
