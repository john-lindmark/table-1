-- Deck and cube lines record a condition (contract/lists-2026-10-15.md, "Conditions"; John, 2026-11-01: Add to
-- collection's "Add N missing" and "Add all" add the deck's recorded printing, "notably keeping the language and
-- condition"), so a copy moved into a deck from the collection keeps its condition and goes back in as it.
--  - A line is printing × section × finish × language × condition. An entry is [card_id, board, qty] (non-foil,
--    English, NM), [card_id, board, qty, finish], [card_id, board, qty, finish, lang], or
--    [card_id, board, qty, finish, lang, cond] for any condition but NM (finish and language are then always
--    written). Older entries stay valid and mean NM; older clients read the first five elements and ignore the sixth.
--  - Conditions are NM, LP, MP, HP, DMG, as in the collection.
--  - list_edit ops take an optional cond (default NM); {from, to} keeps the line's condition; the move op takes
--    to_cond (default the line's condition) beside to_card_id / to_finish / to_lang.
-- Replaces t1_private.list_write and public.list_edit (as of 20261026040000_list_languages.sql); everything else in
-- them is unchanged.

alter table public.card_list_entries add column if not exists condition text not null default 'NM'
  check (condition in ('NM', 'LP', 'MP', 'HP', 'DMG'));
alter table public.card_list_entries drop constraint if exists card_list_entries_pkey;
alter table public.card_list_entries add primary key (list_id, board, card_id, finish, lang, condition);

create or replace function t1_private.list_write(
  p_list public.card_lists, p_entries jsonb, p_note text, p_extend boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_bad text;
  v_version integer;
  v_clean jsonb;
begin
  -- Merge duplicate lines, drop zero/negative, use a finish the printing comes in and a foreign printing's own
  -- language, validate boards, cards, languages, conditions and size.
  with rows as (
    select (e->>0)::uuid card_id, e->>1 board, (e->>2)::int qty, coalesce(nullif(e->>3, ''), 'nonfoil') finish,
           lower(coalesce(nullif(e->>4, ''), 'en')) lang, upper(coalesce(nullif(e->>5, ''), 'NM')) cond
      from jsonb_array_elements(p_entries) e
  ), fitted as (
    select r.card_id, r.board, r.qty,
           case when c.id is null or coalesce(cardinality(c.finishes), 0) = 0 or r.finish = any (c.finishes) then r.finish
                when 'nonfoil' = any (c.finishes) then 'nonfoil'
                when 'foil' = any (c.finishes) then 'foil'
                else c.finishes[1] end finish,
           case when c.lang is not null and c.lang <> 'en' then c.lang else r.lang end lang,
           r.cond
      from rows r left join public.cards c on c.id = r.card_id
  ), merged as (
    select card_id, board, finish, lang, cond, sum(qty)::int qty from fitted group by 1, 2, 3, 4, 5 having sum(qty) > 0
  )
  select coalesce(jsonb_agg(case when cond <> 'NM' then jsonb_build_array(card_id, board, qty, finish, lang, cond)
                                 when lang <> 'en' then jsonb_build_array(card_id, board, qty, finish, lang)
                                 when finish = 'nonfoil' then jsonb_build_array(card_id, board, qty)
                                 else jsonb_build_array(card_id, board, qty, finish) end
                            order by board, card_id, finish, lang, array_position(array['NM', 'LP', 'MP', 'HP', 'DMG'], cond), cond),
                   '[]'::jsonb) into v_clean from merged;

  if jsonb_array_length(v_clean) > 1000 then raise exception 'A list holds at most 1000 different cards' using errcode = '22023'; end if;
  select string_agg(distinct e->>1, ', ') into v_bad from jsonb_array_elements(v_clean) e
   where e->>1 not in ('main', 'maybe') and not (p_list.kind = 'deck' and e->>1 in ('side', 'commander'));
  if v_bad is not null then raise exception 'Not a section of a %: %', p_list.kind, v_bad using errcode = '22023'; end if;
  if exists (select 1 from jsonb_array_elements(v_clean) e where (e->>2)::int > 999) then
    raise exception 'At most 999 copies of a card in one section' using errcode = '22023';
  end if;
  select string_agg(distinct e->>4, ', ') into v_bad from jsonb_array_elements(v_clean) e
   where e->>4 is not null and e->>4 !~ '^[a-z]{2,3}$';
  if v_bad is not null then raise exception 'Not a language: %', v_bad using errcode = '22023'; end if;
  select string_agg(distinct e->>5, ', ') into v_bad from jsonb_array_elements(v_clean) e
   where e->>5 is not null and e->>5 not in ('NM', 'LP', 'MP', 'HP', 'DMG');
  if v_bad is not null then raise exception 'Not a condition: %', v_bad using errcode = '22023'; end if;
  select string_agg(e->>0, ', ') into v_bad from (select e from jsonb_array_elements(v_clean) e
    where not exists (select 1 from public.cards c where c.id = (e->>0)::uuid) limit 3) x;
  if v_bad is not null then raise exception 'Unknown card: %', v_bad using errcode = '22023'; end if;

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
  insert into public.card_list_entries (list_id, card_id, board, qty, finish, lang, condition)
  select p_list.id, (e->>0)::uuid, e->>1, (e->>2)::int, coalesce(e->>3, 'nonfoil'), coalesce(e->>4, 'en'), coalesce(e->>5, 'NM')
    from jsonb_array_elements(v_clean) e;
  update public.card_lists set current_version = v_version, seq = nextval('public.card_list_seq'), updated_at = now()
   where id = p_list.id;
end $$;

-- Applies edits to the current contents. p_ops (finish defaults to nonfoil, lang to en, cond to NM everywhere):
--   {card_id, board, finish?, lang?, cond?, delta} | {…, qty}                         change a line's count
--   {card_id, finish?, lang?, cond?, from, to}                                       move every copy to another section
--   {card_id, board, finish?, lang?, cond?, to_card_id?, to_finish?, to_lang?, to_cond?, qty?}
--                                                                                    move qty copies (default all) to
--                                                                                    another printing, finish, language
--                                                                                    and/or condition, same section
-- Edits within 10 minutes of the last edit extend that version.
create or replace function public.list_edit(p_list_id uuid, p_ops jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_list public.card_lists := t1_private.list_lock(auth.uid(), p_list_id);
  v_cur public.card_list_versions;
  v_entries jsonb;
  v_op jsonb;
  v_fin text;
  v_lang text;
  v_cond text;
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
  -- Work on a {"card|board|finish|lang|cond": qty} map.
  select coalesce(jsonb_object_agg((e->>0) || '|' || (e->>1) || '|' || coalesce(e->>3, 'nonfoil') || '|' || coalesce(e->>4, 'en')
                                   || '|' || coalesce(e->>5, 'NM'), (e->>2)::int), '{}'::jsonb)
    into v_map from jsonb_array_elements(v_cur.entries) e;
  for v_op in select * from jsonb_array_elements(p_ops) loop
    v_fin := coalesce(nullif(v_op->>'finish', ''), 'nonfoil');
    v_lang := lower(coalesce(nullif(v_op->>'lang', ''), 'en'));
    v_cond := upper(coalesce(nullif(v_op->>'cond', ''), 'NM'));
    if v_lang !~ '^[a-z]{2,3}$' or lower(coalesce(nullif(v_op->>'to_lang', ''), 'en')) !~ '^[a-z]{2,3}$' then
      raise exception 'Not a language: %', coalesce(v_op->>'to_lang', v_op->>'lang') using errcode = '22023';
    end if;
    if v_cond not in ('NM', 'LP', 'MP', 'HP', 'DMG')
       or upper(coalesce(nullif(v_op->>'to_cond', ''), 'NM')) not in ('NM', 'LP', 'MP', 'HP', 'DMG') then
      raise exception 'Not a condition: %', coalesce(v_op->>'to_cond', v_op->>'cond') using errcode = '22023';
    end if;
    if v_op ? 'from' then
      v_key := (v_op->>'card_id') || '|' || (v_op->>'from') || '|' || v_fin || '|' || v_lang || '|' || v_cond;
      v_q := coalesce((v_map->>v_key)::int, 0);
      if v_q > 0 then
        v_map := v_map - v_key;
        v_key := (v_op->>'card_id') || '|' || (v_op->>'to') || '|' || v_fin || '|' || v_lang || '|' || v_cond;
        v_map := jsonb_set(v_map, array[v_key], to_jsonb(coalesce((v_map->>v_key)::int, 0) + v_q));
      end if;
    elsif v_op ? 'to_card_id' or v_op ? 'to_finish' or v_op ? 'to_lang' or v_op ? 'to_cond' then
      v_key := (v_op->>'card_id') || '|' || coalesce(v_op->>'board', 'main') || '|' || v_fin || '|' || v_lang || '|' || v_cond;
      v_to := coalesce(v_op->>'to_card_id', v_op->>'card_id') || '|' || coalesce(v_op->>'board', 'main') || '|'
              || coalesce(nullif(v_op->>'to_finish', ''), v_fin) || '|' || lower(coalesce(nullif(v_op->>'to_lang', ''), v_lang))
              || '|' || upper(coalesce(nullif(v_op->>'to_cond', ''), v_cond));
      v_q := coalesce((v_map->>v_key)::int, 0);
      v_n := least(v_q, coalesce((v_op->>'qty')::int, v_q));
      if v_n > 0 and v_to <> v_key then
        v_map := case when v_q - v_n > 0 then jsonb_set(v_map, array[v_key], to_jsonb(v_q - v_n)) else v_map - v_key end;
        v_map := jsonb_set(v_map, array[v_to], to_jsonb(coalesce((v_map->>v_to)::int, 0) + v_n));
      end if;
    else
      v_key := (v_op->>'card_id') || '|' || coalesce(v_op->>'board', 'main') || '|' || v_fin || '|' || v_lang || '|' || v_cond;
      v_q := case when v_op ? 'qty' then (v_op->>'qty')::int
                  else coalesce((v_map->>v_key)::int, 0) + coalesce((v_op->>'delta')::int, 0) end;
      v_map := case when v_q > 0 then jsonb_set(v_map, array[v_key], to_jsonb(v_q)) else v_map - v_key end;
    end if;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_array(split_part(k, '|', 1), split_part(k, '|', 2), v::int, split_part(k, '|', 3),
                                              split_part(k, '|', 4), split_part(k, '|', 5))), '[]'::jsonb)
    into v_entries from jsonb_each_text(v_map) as m(k, v);
  perform t1_private.list_write(v_list, v_entries, 'Edited', v_cur.open_until is not null and v_cur.open_until > now());
  return t1_private.list_json(p_list_id);
end $$;
