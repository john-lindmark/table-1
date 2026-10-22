-- A deck or cube line asking for a finish its printing doesn't come in is saved in the finish the printing does
-- come in (non-foil first, then foil, then etched) instead of refusing the whole list (contract/lists-2026-10-15.md,
-- "Finishes and printings"). An imported Cube Cobra cube with a foil-only printing listed without a finish (a Secret
-- Lair, a promo) was refused outright, so it never reached the server (bug found 2026-10-22).
-- Lines that become the same line are merged. Everything else in list_write is unchanged.

create or replace function t1_private.list_write(
  p_list public.card_lists, p_entries jsonb, p_note text, p_extend boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_bad text;
  v_version integer;
  v_clean jsonb;
begin
  -- Merge duplicate lines, drop zero/negative, use a finish the printing comes in, validate boards, cards and size.
  with rows as (
    select (e->>0)::uuid card_id, e->>1 board, (e->>2)::int qty, coalesce(nullif(e->>3, ''), 'nonfoil') finish
      from jsonb_array_elements(p_entries) e
  ), fitted as (
    select r.card_id, r.board, r.qty,
           case when c.id is null or coalesce(cardinality(c.finishes), 0) = 0 or r.finish = any (c.finishes) then r.finish
                when 'nonfoil' = any (c.finishes) then 'nonfoil'
                when 'foil' = any (c.finishes) then 'foil'
                else c.finishes[1] end finish
      from rows r left join public.cards c on c.id = r.card_id
  ), merged as (
    select card_id, board, finish, sum(qty)::int qty from fitted group by 1, 2, 3 having sum(qty) > 0
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
