-- Commander partner rules need who each card can share the command zone with
-- (contract/command-zone-2026-10-27.md § Partners, contract/catalog-2026-10-14.md).
-- card_oracles gains
--   pair_code  P partner, P:<name> partner with that card, G:<group> partner—group, F friends forever,
--              B choose a Background, D doctor's companion, '' none. Null until cards-sync has read the card since
--              this change (cards-sync pairCode).
-- Each O line gains a trailing field, pair, after tokens. Readers ignore extra trailing fields, so pack format 1 holds.
-- Rows cards-sync hasn't refreshed yet (pair_code null) end at tokens as before, and clients treat the pair as unknown.
-- Replaces t1_private.catalog_rows, public.catalog_ingest and t1_private.catalog_pack_o_lines as last defined in
-- 20261018120000_pack_mana_tokens.sql.

alter table public.card_oracles add column if not exists pair_code text;

-- ==================================================================== ingest
drop function if exists t1_private.catalog_rows(jsonb);
create function t1_private.catalog_rows(p_rows jsonb)
returns table (
  id uuid, oracle_id uuid, name text, face_names text[], layout text, type_line text, mana_cost text,
  cmc numeric, colors text[], color_identity text[], legalities jsonb,
  set_code text, collector_number text, lang text, rarity text, finishes text[], printed_name text,
  released_at date, image_ts bigint, image_faces smallint,
  usd numeric, usd_foil numeric, usd_etched numeric, eur numeric, eur_foil numeric,
  produced_mana text, token_card_ids uuid[], pair_code text)
language sql immutable set search_path = '' as $$
  select * from jsonb_to_recordset(p_rows) as r (
    id uuid, oracle_id uuid, name text, face_names text[], layout text, type_line text, mana_cost text,
    cmc numeric, colors text[], color_identity text[], legalities jsonb,
    set_code text, collector_number text, lang text, rarity text, finishes text[], printed_name text,
    released_at date, image_ts bigint, image_faces smallint,
    usd numeric, usd_foil numeric, usd_etched numeric, eur numeric, eur_foil numeric,
    produced_mana text, token_card_ids uuid[], pair_code text);
$$;

-- As in 20261018120000_pack_mana_tokens.sql, with pair_code on the Oracle row and in its content hash, so the first run
-- after this change rewrites every row once.
create or replace function public.catalog_ingest(p_run bigint, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_changed uuid[];
  v_cards integer;
  v_prices integer;
begin
  with ranked as (
    select r.*, t1_private.catalog_source_rank(r.layout, r.legalities, r.lang, r.released_at, r.id) rnk
      from t1_private.catalog_rows(p_rows) r
  ), src as (
    select distinct on (r.oracle_id) r.oracle_id, r.name, coalesce(r.face_names, '{}') face_names, r.layout,
           r.type_line, r.mana_cost, r.cmc, coalesce(r.colors, '{}') colors,
           coalesce(r.color_identity, '{}') color_identity, coalesce(r.legalities, '{}'::jsonb) legalities,
           r.produced_mana, coalesce(r.token_card_ids, '{}') token_card_ids, r.pair_code, r.rnk, r.id
      from ranked r
     order by r.oracle_id, r.rnk desc
  ), up as (
    insert into public.card_oracles as o (oracle_id, name, name_norm, face_names, layout, type_line, mana_cost, cmc,
                                          colors, color_identity, legalities, produced_mana, token_card_ids,
                                          pair_code, source_card_id, source_rank, content_hash)
    select s.oracle_id, s.name, public.card_name_norm(s.name), s.face_names, s.layout, s.type_line, s.mana_cost,
           s.cmc, s.colors, s.color_identity, s.legalities, s.produced_mana, s.token_card_ids, s.pair_code, s.id, s.rnk,
           md5(jsonb_build_array(s.name, s.face_names, s.layout, s.type_line, s.mana_cost, s.cmc, s.colors,
                                 s.color_identity, s.legalities, s.produced_mana, s.token_card_ids, s.pair_code)::text)
      from src s
    on conflict (oracle_id) do update
       set name = excluded.name, name_norm = excluded.name_norm, face_names = excluded.face_names,
           layout = excluded.layout, type_line = excluded.type_line, mana_cost = excluded.mana_cost,
           cmc = excluded.cmc, colors = excluded.colors, color_identity = excluded.color_identity,
           legalities = excluded.legalities, produced_mana = excluded.produced_mana,
           token_card_ids = excluded.token_card_ids, pair_code = excluded.pair_code, source_card_id = excluded.source_card_id,
           source_rank = excluded.source_rank, content_hash = excluded.content_hash, updated_at = now()
     where excluded.source_rank > o.source_rank
        or (excluded.source_card_id = o.source_card_id and o.content_hash is distinct from excluded.content_hash)
    returning o.oracle_id
  )
  select coalesce(array_agg(up.oracle_id), '{}') into v_changed from up;

  if cardinality(v_changed) > 0 then
    delete from public.card_names n where n.oracle_id = any(v_changed);
    insert into public.card_names (name_norm, oracle_id, is_face)
    select distinct on (v.nm, o.oracle_id) v.nm, o.oracle_id, v.f
      from public.card_oracles o,
           lateral (select o.name_norm nm, false f
                    union all
                    select public.card_name_norm(x), true from unnest(o.face_names) x) v
     where o.oracle_id = any(v_changed) and v.nm <> ''
     order by v.nm, o.oracle_id, v.f
    on conflict do nothing;
  end if;

  with up as (
    insert into public.cards as c (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout,
                                   printed_name, released_at, image_ts, image_faces, content_hash)
    select r.id, r.oracle_id, r.set_code, r.collector_number, r.lang, r.rarity, r.finishes, r.layout,
           r.printed_name, r.released_at, r.image_ts, coalesce(r.image_faces, 1),
           md5(jsonb_build_array(r.oracle_id, r.set_code, r.collector_number, r.lang, r.rarity, r.finishes,
                                 r.layout, r.printed_name, r.released_at, r.image_ts, r.image_faces)::text)
      from t1_private.catalog_rows(p_rows) r
    on conflict (id) do update
       set oracle_id = excluded.oracle_id, set_code = excluded.set_code, collector_number = excluded.collector_number,
           lang = excluded.lang, rarity = excluded.rarity, finishes = excluded.finishes, layout = excluded.layout,
           printed_name = excluded.printed_name, released_at = excluded.released_at, image_ts = excluded.image_ts,
           image_faces = excluded.image_faces, content_hash = excluded.content_hash, updated_at = now()
     where c.content_hash is distinct from excluded.content_hash
    returning 1
  )
  select count(*) into v_cards from up;

  with up as (
    insert into public.card_prices as p (card_id, usd, usd_foil, usd_etched, eur, eur_foil)
    select r.id, r.usd, r.usd_foil, r.usd_etched, r.eur, r.eur_foil from t1_private.catalog_rows(p_rows) r
    on conflict (card_id) do update
       set usd = excluded.usd, usd_foil = excluded.usd_foil, usd_etched = excluded.usd_etched,
           eur = excluded.eur, eur_foil = excluded.eur_foil, updated_at = now()
     where (p.usd, p.usd_foil, p.usd_etched, p.eur, p.eur_foil)
           is distinct from (excluded.usd, excluded.usd_foil, excluded.usd_etched, excluded.eur, excluded.eur_foil)
    returning 1
  )
  select count(*) into v_prices from up;

  update t1_private.catalog_runs
     set rows_in = rows_in + jsonb_array_length(p_rows), oracles_changed = oracles_changed + cardinality(v_changed),
         cards_changed = cards_changed + v_cards, prices_changed = prices_changed + v_prices
   where id = p_run;
  return jsonb_build_object('oracles', cardinality(v_changed), 'cards', v_cards, 'prices', v_prices);
end $$;

-- ==================================================================== pack
-- O lines for a window of cards: the 20261016210000 fields, then produced, tokens and pair. concat_ws skips nulls, so a
-- row with no produced_mana yet ends at points exactly as before, and one with no pair_code yet at tokens.
create or replace function t1_private.catalog_pack_o_lines(p_from bigint, p_to bigint)
returns text language sql stable set search_path = '' as $$
  with o as (
    select oracle_id, name, name_norm, face_names, type_line, mana_cost, cmc, colors, legalities, produced_mana,
           token_card_ids, pair_code, (row_number() over (order by name_norm, oracle_id)) - 1 idx
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
                     case when w.produced_mana is not null then translate(w.pair_code, E'\t\n\r', '   ') end),
           E'\n' order by w.idx)
    from w left join tk on tk.oracle_id = w.oracle_id;
$$;
revoke all on function t1_private.catalog_pack_o_lines(bigint, bigint) from public, anon, authenticated;
