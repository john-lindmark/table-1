-- Catalog pack: each O line gains a legality code (field 11) so clients can flag banned cards offline.
-- One character per format, in this order: standard, pioneer, modern, legacy, vintage, pauper, commander,
-- premodern. L legal, R restricted, B banned, - not legal. Readers ignore fields they don't know, so pack
-- format 1 still holds (contract/catalog-2026-10-14.md).
create or replace function public.catalog_pack_body()
returns text language sql stable security definer set search_path = '' as $$
  with o as (
    select oracle_id, name, name_norm, face_names, type_line, mana_cost, cmc, colors, legalities,
           (row_number() over (order by name_norm, oracle_id)) - 1 idx
      from public.card_oracles
  )
  select string_agg(line, E'\n' order by k, idx, d desc nulls last, s, cn) from (
    select 0 k, o.idx, null::date d, null::text s, null::text cn,
           concat_ws(E'\t', 'O', o.idx, o.oracle_id, translate(o.name, E'\t\n\r', '   '), o.name_norm,
                     translate(coalesce(o.type_line, ''), E'\t\n\r', '   '), coalesce(o.mana_cost, ''),
                     coalesce(o.cmc::text, ''), array_to_string(o.colors, ''),
                     array_to_string(o.face_names, ' // '),
                     (select string_agg(case o.legalities->>f when 'legal' then 'L' when 'restricted' then 'R'
                                                               when 'banned' then 'B' else '-' end, '' order by ord)
                        from unnest(array['standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'commander',
                                          'premodern']) with ordinality as fm(f, ord))) line
      from o
    union all
    select 1, o.idx, c.released_at, c.set_code, c.collector_number,
           concat_ws(E'\t', 'P', c.id, o.idx, c.set_code, c.collector_number, c.lang, left(c.rarity, 1),
                     (select string_agg(left(f, 1), '' order by f) from unnest(c.finishes) f),
                     coalesce(c.released_at::text, ''), coalesce(c.image_ts::text, ''), c.image_faces,
                     translate(coalesce(c.printed_name, ''), E'\t\n\r', '   '))
      from public.cards c join o on o.oracle_id = c.oracle_id
  ) t;
$$;
