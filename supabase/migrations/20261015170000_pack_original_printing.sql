-- Catalog pack: each card's original paper printing is flagged (P line field 13 = "1") so every client adds
-- that printing by default. Original = earliest released English printing with an image, skipping promo,
-- token, memorabilia (30A, CE/IE, World Championship decks), alchemy and minigame sets; within a release day
-- the plain collector number wins over variants. Cards with no such printing fall back to their earliest
-- English printing with an image, then their earliest printing. Every printing in the catalog is paper
-- (cards-sync drops digital-only ones). Readers ignore unknown fields, so pack format 1 still holds.
create or replace function public.catalog_pack_body()
returns text language sql stable security definer set search_path = '' as $$
  with o as (
    select oracle_id, name, name_norm, face_names, type_line, mana_cost, cmc, colors, legalities,
           (row_number() over (order by name_norm, oracle_id)) - 1 idx
      from public.card_oracles
  ),
  orig as (
    select distinct on (c.oracle_id) c.id
      from public.cards c left join public.mtg_sets s on s.code = c.set_code
     order by c.oracle_id,
              (c.lang = 'en' and c.image_faces > 0
                 and coalesce(s.set_type, '') not in ('promo', 'token', 'memorabilia', 'alchemy', 'minigame')) desc,
              (c.lang = 'en' and c.image_faces > 0) desc,
              c.released_at nulls last,
              (c.collector_number ~ '^[0-9]+$') desc,
              length(c.collector_number), c.collector_number, c.set_code
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
                     translate(coalesce(c.printed_name, ''), E'\t\n\r', '   '),
                     case when orig.id is not null then '1' else '' end)
      from public.cards c join o on o.oracle_id = c.oracle_id left join orig on orig.id = c.id
  ) t;
$$;
