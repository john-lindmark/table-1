-- Decks and cubes name a finish per line, so a deck can hold 2 foil and 2 non-foil copies of a card, and a
-- line can move to another printing (contract/lists-2026-10-15.md, "Finishes and printings").
--  - An entry is [card_id, board, qty] (non-foil) or [card_id, board, qty, finish] (foil / etched). Old
--    three-element entries stay valid and mean non-foil, so history and older clients keep working.
--  - A line is card × board × finish. The finish must exist for that printing.
--  - list_edit ops take an optional finish (default nonfoil), and a new op moves copies of a line to another
--    printing and/or finish in the same section: {card_id, board, finish?, to_card_id?, to_finish?, qty?}
--    (qty = how many to move; default all). Moving 2 of 4 non-foil to foil splits the line.

alter table public.card_list_entries add column if not exists finish text not null default 'nonfoil'
  check (finish in ('nonfoil', 'foil', 'etched'));
alter table public.card_list_entries drop constraint if exists card_list_entries_pkey;
alter table public.card_list_entries add primary key (list_id, board, card_id, finish);

create or replace function t1_private.list_write(
  p_list public.card_lists, p_entries jsonb, p_note text, p_extend boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_bad text;
  v_version integer;
  v_clean jsonb;
begin
  -- Merge duplicate lines, drop zero/negative, validate boards, cards, finishes and size.
  with rows as (
    select (e->>0)::uuid card_id, e->>1 board, (e->>2)::int qty, coalesce(nullif(e->>3, ''), 'nonfoil') finish
      from jsonb_array_elements(p_entries) e
  ), merged as (
    select card_id, board, finish, sum(qty)::int qty from rows group by 1, 2, 3 having sum(qty) > 0
  )
  select coalesce(jsonb_agg(case when finish = 'nonfoil' then jsonb_build_array(card_id, board, qty)
                                 else jsonb_build_array(card_id, board, qty, finish) end
                            order by board, card_id, finish), '[]'::jsonb) into v_clean from merged;

  if jsonb_array_length(v_clean) > 1000 then raise exception 'A list holds at most 1000 different cards' using errcode = '22023'; end if;
  select string_agg(distinct e->>1, ', ') into v_bad from jsonb_array_elements(v_clean) e
   where e->>1 not in ('main', 'maybe') and not (p_list.kind = 'deck' and e->>1 in ('side', 'commander'));
  if v_bad is not null then raise exception 'Not a section of a %: %', p_list.kind, v_bad using errcode = '22023'; end if;
  if exists (select 1 from jsonb_array_elements(v_clean) e where (e->>2)::int > 999) then
    raise exception 'At most 999 copies of a card in one section' using errcode = '22023';
  end if;
  select string_agg(e->>0, ', ') into v_bad from (select e from jsonb_array_elements(v_clean) e
    where not exists (select 1 from public.cards c where c.id = (e->>0)::uuid) limit 3) x;
  if v_bad is not null then raise exception 'Unknown card: %', v_bad using errcode = '22023'; end if;
  select string_agg(c.set_code || ' #' || c.collector_number || ' ' || coalesce(e->>3, 'nonfoil'), ', ') into v_bad
    from (select e from jsonb_array_elements(v_clean) e) x
    join public.cards c on c.id = (x.e->>0)::uuid
   where not coalesce(x.e->>3, 'nonfoil') = any (c.finishes);
  if v_bad is not null then raise exception 'That printing doesn''t come in that finish: %', v_bad using errcode = '22023'; end if;

  if p_extend then
    update public.card_list_versions set entries = v_clean, edited_at = now(), open_until = now() + interval '10 minutes'
     where list_id = p_list.id and version = p_list.current_version;
    v_version := p_list.current_version;
  else
    update public.card_list_versions set open_until = null where list_id = p_list.id and open_until is not null;
    v_version := coalesce((select max(version) from public.card_list_versions where list_id = p_list.id), 0) + 1;
    insert into public.card_list_versions (list_id, version, note, entries, open_until)
    values (p_list.id, v_version, left(coalesce(nullif(trim(p_note), ''), 'Edited'), 80), v_clean,
            case when p_note = 'Edited' then now() + interval '10 minutes' end);
  end if;

  delete from public.card_list_entries where list_id = p_list.id;
  insert into public.card_list_entries (list_id, card_id, board, qty, finish)
  select p_list.id, (e->>0)::uuid, e->>1, (e->>2)::int, coalesce(e->>3, 'nonfoil') from jsonb_array_elements(v_clean) e;
  update public.card_lists set current_version = v_version, seq = nextval('public.card_list_seq'), updated_at = now()
   where id = p_list.id;
end $$;

-- Applies edits to the current contents. p_ops (finish defaults to nonfoil everywhere):
--   {card_id, board, finish?, delta} | {card_id, board, finish?, qty}     change a line's count
--   {card_id, finish?, from, to}                                         move every copy to another section
--   {card_id, board, finish?, to_card_id?, to_finish?, qty?}             move qty copies (default all) to another
--                                                                        printing and/or finish, same section
-- Edits within 10 minutes of the last edit extend that version.
create or replace function public.list_edit(p_list_id uuid, p_ops jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_list public.card_lists := t1_private.list_lock(auth.uid(), p_list_id);
  v_cur public.card_list_versions;
  v_entries jsonb;
  v_op jsonb;
  v_fin text;
  v_key text;
  v_to text;
  v_map jsonb := '{}'::jsonb;
  v_q integer;
  v_n integer;
begin
  if p_ops is null or jsonb_typeof(p_ops) <> 'array' or jsonb_array_length(p_ops) = 0 then
    raise exception 'Nothing to change' using errcode = '22023';
  end if;
  if jsonb_array_length(p_ops) > 2000 then raise exception 'At most 2000 changes at once' using errcode = '22023'; end if;
  select * into v_cur from public.card_list_versions where list_id = p_list_id and version = v_list.current_version;
  -- Work on a {"card|board|finish": qty} map.
  select coalesce(jsonb_object_agg((e->>0) || '|' || (e->>1) || '|' || coalesce(e->>3, 'nonfoil'), (e->>2)::int), '{}'::jsonb)
    into v_map from jsonb_array_elements(v_cur.entries) e;
  for v_op in select * from jsonb_array_elements(p_ops) loop
    v_fin := coalesce(nullif(v_op->>'finish', ''), 'nonfoil');
    if v_op ? 'from' then
      v_key := (v_op->>'card_id') || '|' || (v_op->>'from') || '|' || v_fin;
      v_q := coalesce((v_map->>v_key)::int, 0);
      if v_q > 0 then
        v_map := v_map - v_key;
        v_key := (v_op->>'card_id') || '|' || (v_op->>'to') || '|' || v_fin;
        v_map := jsonb_set(v_map, array[v_key], to_jsonb(coalesce((v_map->>v_key)::int, 0) + v_q));
      end if;
    elsif v_op ? 'to_card_id' or v_op ? 'to_finish' then
      v_key := (v_op->>'card_id') || '|' || coalesce(v_op->>'board', 'main') || '|' || v_fin;
      v_to := coalesce(v_op->>'to_card_id', v_op->>'card_id') || '|' || coalesce(v_op->>'board', 'main') || '|'
              || coalesce(nullif(v_op->>'to_finish', ''), v_fin);
      v_q := coalesce((v_map->>v_key)::int, 0);
      v_n := least(v_q, coalesce((v_op->>'qty')::int, v_q));
      if v_n > 0 and v_to <> v_key then
        v_map := case when v_q - v_n > 0 then jsonb_set(v_map, array[v_key], to_jsonb(v_q - v_n)) else v_map - v_key end;
        v_map := jsonb_set(v_map, array[v_to], to_jsonb(coalesce((v_map->>v_to)::int, 0) + v_n));
      end if;
    else
      v_key := (v_op->>'card_id') || '|' || coalesce(v_op->>'board', 'main') || '|' || v_fin;
      v_q := case when v_op ? 'qty' then (v_op->>'qty')::int
                  else coalesce((v_map->>v_key)::int, 0) + coalesce((v_op->>'delta')::int, 0) end;
      v_map := case when v_q > 0 then jsonb_set(v_map, array[v_key], to_jsonb(v_q)) else v_map - v_key end;
    end if;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_array(split_part(k, '|', 1), split_part(k, '|', 2), v::int, split_part(k, '|', 3))), '[]'::jsonb)
    into v_entries from jsonb_each_text(v_map) as m(k, v);
  perform t1_private.list_write(v_list, v_entries, 'Edited', v_cur.open_until is not null and v_cur.open_until > now());
  return t1_private.list_json(p_list_id);
end $$;
