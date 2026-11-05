-- Sideboard guides (John, 2026-11-04; contract/sideboard-guide-2026-11-04.md).
-- A deck keeps one guide: matchups, each with the cards that come in (sideboard or Considering), the cards that go
-- out (main deck) and notes. It rides on the deck (card_lists.sideboard_guide), so it syncs with lists_changes, works
-- offline through the clients' list queues, and goes only to the deck's owner (list_json is owner-only; shared decks,
-- profiles and share links read other functions and never see it).
--  - list_json answers carry `guide` (null when the deck has none); older clients ignore it.
--  - list_guide_set(p_list_id, p_guide) replaces the whole guide (null or no matchups clears it) and returns the list.
--    Last write wins: the clients send the whole guide after a short pause.
-- Shape: {matchups: [{id, name, archetype?, in: [[oracle_id, qty]], out: [[oracle_id, qty]], notes?}]}; at most 40
-- matchups, 40 cards a side, names 1-40 characters, notes up to 1000, quantities 1-99 (one entry per card a side,
-- merged). testdata/sideboard-guide/make_cases.py `normalize` is the reference.
-- Replaces t1_private.list_json (as of 20261030080000_cube_sync.sql); adds a column and two functions.

alter table public.card_lists add column if not exists sideboard_guide jsonb;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'card_lists_sideboard_guide_size') then
    alter table public.card_lists add constraint card_lists_sideboard_guide_size
      check (sideboard_guide is null or pg_column_size(sideboard_guide) <= 131072);
  end if;
end $$;

create or replace function t1_private.list_json(p_list_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', l.id, 'kind', l.kind, 'name', l.name, 'format', l.format, 'seq', l.seq,
    'current_version', l.current_version, 'deleted', l.deleted_at is not null,
    'event_id', l.event_id, 'event_name', e.name, 'source_url', l.source_url, 'guide', l.sideboard_guide,
    'versions', coalesce((select jsonb_agg(jsonb_build_object('version', v.version, 'note', v.note,
                                   'at', extract(epoch from v.edited_at), 'entries', v.entries) order by v.version)
                            from public.card_list_versions v where v.list_id = l.id), '[]'::jsonb))
  from public.card_lists l left join public.events e on e.id = l.event_id where l.id = p_list_id;
$$;

-- The guide as it's kept, or null for none; raises 22023 on a bad shape.
create or replace function t1_private.sideboard_guide_clean(p_guide jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  v_ms jsonb := case when p_guide is null or jsonb_typeof(p_guide) = 'null' then '[]'::jsonb else p_guide->'matchups' end;
  v_m jsonb;
  v_out jsonb := '[]'::jsonb;
  v_side text;
  v_sides jsonb;
  v_cards jsonb;
  v_e jsonb;
  v_oracle text;
  v_qty integer;
  v_name text;
  v_notes text;
  v_id text;
  v_arch jsonb;
  v_ids text[] := '{}';
begin
  if p_guide is not null and jsonb_typeof(p_guide) not in ('object', 'null') then
    raise exception 'A guide is an object' using errcode = '22023';
  end if;
  if v_ms is null or jsonb_typeof(v_ms) = 'null' then v_ms := '[]'::jsonb; end if;
  if jsonb_typeof(v_ms) <> 'array' then raise exception 'matchups is a list' using errcode = '22023'; end if;
  if jsonb_array_length(v_ms) > 40 then raise exception 'At most 40 matchups' using errcode = '22023'; end if;
  for v_m in select value from jsonb_array_elements(v_ms) loop
    if jsonb_typeof(v_m) <> 'object' then raise exception 'A matchup is an object' using errcode = '22023'; end if;
    v_id := v_m->>'id';
    if v_id is null or char_length(v_id) not between 1 and 40 or v_id = any(v_ids) then
      raise exception 'Each matchup needs its own id' using errcode = '22023';
    end if;
    v_ids := v_ids || v_id;
    v_name := btrim(coalesce(v_m->>'name', ''));
    if char_length(v_name) not between 1 and 40 then
      raise exception 'A matchup name is 1 to 40 characters' using errcode = '22023';
    end if;
    v_notes := btrim(coalesce(v_m->>'notes', ''), E' \t\r\n');
    if char_length(v_notes) > 1000 then raise exception 'Notes are at most 1000 characters' using errcode = '22023'; end if;
    v_arch := v_m->'archetype';
    if v_arch is not null and jsonb_typeof(v_arch) not in ('number', 'null') then
      raise exception 'archetype is a number' using errcode = '22023';
    end if;
    v_sides := '{}'::jsonb;
    foreach v_side in array array['in', 'out'] loop
      v_cards := '[]'::jsonb;
      if v_m ? v_side and jsonb_typeof(v_m->v_side) <> 'null' then
        if jsonb_typeof(v_m->v_side) <> 'array' then
          raise exception '% is a list', v_side using errcode = '22023';
        end if;
        for v_e in select value from jsonb_array_elements(v_m->v_side) loop
          if jsonb_typeof(v_e) <> 'array' or jsonb_array_length(v_e) <> 2 or jsonb_typeof(v_e->0) <> 'string'
             or jsonb_typeof(v_e->1) <> 'number' then
            raise exception 'A card is [oracle_id, qty]' using errcode = '22023';
          end if;
          v_oracle := v_e->>0;
          if char_length(v_oracle) not between 1 and 64 then raise exception 'Bad card id' using errcode = '22023'; end if;
          if (v_e->>1)::numeric <> floor((v_e->>1)::numeric) or (v_e->>1)::numeric not between 1 and 99 then
            raise exception 'A quantity is 1 to 99' using errcode = '22023';
          end if;
          v_qty := (v_e->>1)::integer;
          -- One entry per card a side, merged where it first appeared.
          if exists (select 1 from jsonb_array_elements(v_cards) x where x->>0 = v_oracle) then
            select jsonb_agg(case when x->>0 = v_oracle
                                  then jsonb_build_array(v_oracle, least(99, (x->>1)::integer + v_qty)) else x end
                             order by o)
              into v_cards
              from jsonb_array_elements(v_cards) with ordinality as t(x, o);
          else
            v_cards := v_cards || jsonb_build_array(jsonb_build_array(v_oracle, v_qty));
          end if;
        end loop;
      end if;
      if jsonb_array_length(v_cards) > 40 then raise exception 'At most 40 cards a side' using errcode = '22023'; end if;
      v_sides := v_sides || jsonb_build_object(v_side, v_cards);
    end loop;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', v_id, 'name', v_name, 'archetype', case when jsonb_typeof(v_arch) = 'number' then v_arch end,
      'in', v_sides->'in', 'out', v_sides->'out', 'notes', v_notes));
  end loop;
  return case when jsonb_array_length(v_out) = 0 then null else jsonb_build_object('matchups', v_out) end;
end $$;

create or replace function public.list_guide_set(p_list_id uuid, p_guide jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_list public.card_lists := t1_private.list_lock(auth.uid(), p_list_id);
  v_guide jsonb := t1_private.sideboard_guide_clean(p_guide);
begin
  if v_list.kind <> 'deck' then raise exception 'Only decks have a sideboard guide' using errcode = '22023'; end if;
  if v_guide is distinct from v_list.sideboard_guide then
    update public.card_lists set sideboard_guide = v_guide, seq = nextval('public.card_list_seq'), updated_at = now()
     where id = v_list.id;
  end if;
  return t1_private.list_json(p_list_id);
end $$;

revoke all on function t1_private.sideboard_guide_clean(jsonb) from public, anon, authenticated;
revoke all on function public.list_guide_set(uuid, jsonb) from public, anon;
grant execute on function public.list_guide_set(uuid, jsonb) to authenticated;
