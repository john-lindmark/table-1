-- Group by color identity (contract/shared-lists-grouping-2026-10-20.md § Color identity) needs each card's color
-- identity on the device. card_oracles.color_identity has been stored since 20261014150000_card_catalog.sql; the pack
-- never carried it.
-- Each O line gains a trailing field, identity, after pair: WUBRG letters in that order (empty = colorless). Readers
-- ignore extra trailing fields, so pack format 1 holds. It is written only where pair is (a row cards-sync hasn't read
-- since 20261028120000_pack_pair_codes.sql ends at tokens or points as before), so every field keeps its position.
-- No ingest change: the next pack build after this migration carries it, and its new content hash publishes it.
-- Replaces t1_private.catalog_pack_o_lines as last defined in 20261028120000_pack_pair_codes.sql.

-- ==================================================================== pack
-- O lines for a window of cards: the 20261016210000 fields, then produced, tokens, pair and identity. concat_ws skips
-- nulls, so a row with no produced_mana yet ends at points exactly as before, and one with no pair_code yet at tokens.
create or replace function t1_private.catalog_pack_o_lines(p_from bigint, p_to bigint)
returns text language sql stable set search_path = '' as $$
  with o as (
    select oracle_id, name, name_norm, face_names, type_line, mana_cost, cmc, colors, color_identity, legalities,
           produced_mana, token_card_ids, pair_code, (row_number() over (order by name_norm, oracle_id)) - 1 idx
      from public.card_oracles
  ),
  w as (select * from o where o.idx >= p_from and o.idx < p_to),
  tk as (
    select x.oracle_id, string_agg(x.idx::text, ',' order by x.idx) ids
      from (select distinct w.oracle_id, t.idx
              from w cross join lateral unnest(w.token_card_ids) tid
              join public.cards tc on tc.id = tid
              join o t on t.oracle_id = tc.oracle_id
             where tc.oracle_id <> w.oracle_id) x
     group by x.oracle_id
  )
  select string_agg(
           concat_ws(E'\t', 'O', w.idx, w.oracle_id, translate(w.name, E'\t\n\r', '   '), w.name_norm,
                     translate(coalesce(w.type_line, ''), E'\t\n\r', '   '), coalesce(w.mana_cost, ''),
                     coalesce(w.cmc::text, ''), array_to_string(w.colors, ''),
                     array_to_string(w.face_names, ' // '),
                     (select string_agg(case w.legalities->>f when 'legal' then 'L' when 'restricted' then 'R'
                                                               when 'banned' then 'B' else '-' end, '' order by ord)
                        from unnest(array['standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'commander',
                                          'premodern']) with ordinality as fm(f, ord)),
                     coalesce((select fp.points::text from public.format_points fp
                                where fp.format = 'canlander' and fp.oracle_id = w.oracle_id), ''),
                     w.produced_mana,
                     case when w.produced_mana is not null then coalesce(tk.ids, '') end,
                     case when w.produced_mana is not null then translate(w.pair_code, E'\t\n\r', '   ') end,
                     case when w.produced_mana is not null and w.pair_code is not null then
                       coalesce((select string_agg(c, '' order by ord)
                                   from unnest(array['W', 'U', 'B', 'R', 'G']) with ordinality as ci(c, ord)
                                  where c = any(coalesce(w.color_identity, '{}'))), '')
                     end),
           E'\n' order by w.idx)
    from w left join tk on tk.oracle_id = w.oracle_id;
$$;
revoke all on function t1_private.catalog_pack_o_lines(bigint, bigint) from public, anon, authenticated;
