-- Buy on TCGplayer, printings as product links (contract/tcgplayer-cart-2026-10-26.md § Printings).
-- TCGplayer's Mass Entry adds nothing when any one line fails, and "<name> [SET] <number>" lines failed often
-- (checked 2026-10-28): TCGplayer names many printings with a suffix ("Sire of Seven Deaths (Borderless)"), some
-- printings are presales with no listings (Thoughtseize SLD 2705), and copies listed with seller photos (every NM
-- Beta Mox Ruby that day) can't be added by Mass Entry. So Mass Entry now gets card names only, and a want for a
-- printing becomes a link to that printing's TCGplayer product page, from Scryfall's tcgplayer_id.
-- Replaces public.catalog_ingest and t1_private.catalog_rows from 20261028120000 and public.tcgplayer_cart(jsonb)
-- from 20261026070000 (all three checked identical to live 2026-10-28).

-- Each printing's TCGplayer product (Scryfall tcgplayer_id; tcgplayer_etched_id for its etched foil when TCGplayer
-- lists that apart). Filled by cards-sync v11+ through catalog_ingest; read only by tcgplayer_cart.
create table if not exists t1_private.card_tcgplayer (
  card_id uuid primary key references public.cards (id) on delete cascade,
  product_id integer,
  etched_product_id integer
);
alter table t1_private.card_tcgplayer enable row level security;

-- ==================================================================== ingest
drop function if exists t1_private.catalog_rows(jsonb);
create function t1_private.catalog_rows(p_rows jsonb)
returns table (
  id uuid, oracle_id uuid, name text, face_names text[], layout text, type_line text, mana_cost text,
  cmc numeric, colors text[], color_identity text[], legalities jsonb,
  set_code text, collector_number text, lang text, rarity text, finishes text[], printed_name text,
  released_at date, image_ts bigint, image_faces smallint,
  usd numeric, usd_foil numeric, usd_etched numeric, eur numeric, eur_foil numeric,
  produced_mana text, token_card_ids uuid[], pair_code text, tcgplayer_id integer,
  tcgplayer_etched_id integer)
language sql immutable set search_path = '' as $$
  select * from jsonb_to_recordset(p_rows) as r (
    id uuid, oracle_id uuid, name text, face_names text[], layout text, type_line text, mana_cost text,
    cmc numeric, colors text[], color_identity text[], legalities jsonb,
    set_code text, collector_number text, lang text, rarity text, finishes text[], printed_name text,
    released_at date, image_ts bigint, image_faces smallint,
    usd numeric, usd_foil numeric, usd_etched numeric, eur numeric, eur_foil numeric,
    produced_mana text, token_card_ids uuid[], pair_code text, tcgplayer_id integer,
    tcgplayer_etched_id integer);
$$;

-- As in 20261028120000_pack_pair_codes.sql, plus each printing's TCGplayer product ids into t1_private.card_tcgplayer.
-- Rows from a cards-sync without the ids (v10 and earlier) leave the stored ids as they are.
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

  insert into t1_private.card_tcgplayer as t (card_id, product_id, etched_product_id)
  select r.id, r.tcgplayer_id, r.tcgplayer_etched_id from t1_private.catalog_rows(p_rows) r
   where r.tcgplayer_id is not null or r.tcgplayer_etched_id is not null
  on conflict (card_id) do update
     set product_id = excluded.product_id, etched_product_id = excluded.etched_product_id
   where (t.product_id, t.etched_product_id) is distinct from (excluded.product_id, excluded.etched_product_id);

  update t1_private.catalog_runs
     set rows_in = rows_in + jsonb_array_length(p_rows), oracles_changed = oracles_changed + cardinality(v_changed),
         cards_changed = cards_changed + v_cards, prices_changed = prices_changed + v_prices
   where id = p_run;
  return jsonb_build_object('oracles', cardinality(v_changed), 'cards', v_cards, 'prices', v_prices);
end $$;

-- ==================================================================== cart
-- p_items: [{oracle_id?, card_id?, qty}], up to 2000 (a card_id alone is that printing; an oracle_id alone is any
-- printing). Returns {enabled, lines, unknown, urls, products}:
--   urls      Mass Entry links, one per part (each adds to the same TCGplayer cart). Lines are "<qty> <name>", summed
--             by name. Names are TCGplayer's: split cards whole ("Fire // Ice"), every other card with two names by
--             its first (transform, modal, adventure, flip: "Delver of Secrets", "Bonecrusher Giant").
--   products  with p_products (new apps): a printing TCGplayer has a product for is left out of Mass Entry and comes
--             here instead, [{card_id, name, set, number, qty, url}] by name, then set and number, url = its product
--             page (affiliate-wrapped like the urls). Without it (apps from before) every printing goes into Mass
--             Entry by name and products is empty.
--   lines     Mass Entry lines; unknown: cards the catalog doesn't know, left out.
drop function if exists public.tcgplayer_cart(jsonb);
create function public.tcgplayer_cart(p_items jsonb, p_products boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_base text;
  v_product text;
  v_link text;
  v_max integer;
  v_lines text[];
  v_unknown integer;
  v_products jsonb;
  v_urls text[] := '{}';
  v_part text := '';
  v_line text;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if t1_private.tcgplayer_setting('enabled', 'true') <> 'true' then
    return jsonb_build_object('enabled', false, 'lines', 0, 'unknown', 0, 'urls', '[]'::jsonb, 'products', '[]'::jsonb);
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 2000 then
    raise exception 'p_items: an array of up to 2000 items' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_items) e
              where jsonb_typeof(e) <> 'object' or jsonb_typeof(e -> 'qty') <> 'number'
                 or (e ->> 'qty')::numeric not between 1 and 999 or (e ->> 'qty')::numeric <> floor((e ->> 'qty')::numeric)
                 or coalesce(e ->> 'oracle_id', e ->> 'card_id') is null
                 or (e ->> 'oracle_id') !~ '^[0-9a-f-]{36}$' and e ? 'oracle_id' and e -> 'oracle_id' <> 'null'::jsonb
                 or (e ->> 'card_id') !~ '^[0-9a-f-]{36}$' and e ? 'card_id' and e -> 'card_id' <> 'null'::jsonb) then
    raise exception 'p_items: each {oracle_id or card_id, qty 1-999}' using errcode = '22023';
  end if;
  v_base := t1_private.tcgplayer_setting('massentry', 'https://www.tcgplayer.com/massentry?productline=Magic&c=');
  v_product := t1_private.tcgplayer_setting('product', 'https://www.tcgplayer.com/product/');
  v_link := t1_private.tcgplayer_setting('link', '{url}');
  v_max := coalesce(nullif(t1_private.tcgplayer_setting('max_url', '6000'), '')::int, 6000);

  with items as (
    select (e ->> 'oracle_id')::uuid oracle_id, (e ->> 'card_id')::uuid card_id, (e ->> 'qty')::int qty
      from jsonb_array_elements(p_items) e
  ), r as (
    select i.qty, c.id card_id, case when o.layout = 'split' then o.name else split_part(o.name, ' // ', 1) end name,
           c.set_code, c.collector_number, case when p_products then coalesce(t.product_id, t.etched_product_id) end product_id,
           o.oracle_id is null unknown
      from items i
      left join public.cards c on c.id = i.card_id
      left join public.card_oracles o on o.oracle_id = coalesce(c.oracle_id, case when i.card_id is null then i.oracle_id end)
      left join t1_private.card_tcgplayer t on t.card_id = c.id
  )
  select (select array_agg(g.qty || ' ' || g.name order by g.name)
            from (select r.name, sum(r.qty) qty from r where not r.unknown and r.product_id is null group by r.name) g),
         (select count(*) from r where r.unknown),
         (select coalesce(jsonb_agg(jsonb_build_object('card_id', g.card_id, 'name', g.name, 'set', upper(g.set_code),
                                                       'number', g.collector_number, 'qty', g.qty,
                                                       'url', replace(replace(v_link, '{url_encoded}', t1_private.url_encode(v_product || g.product_id)),
                                                                      '{url}', v_product || g.product_id))
                                    order by g.name, g.set_code, g.collector_number), '[]'::jsonb)
            from (select r.card_id, r.name, r.set_code, r.collector_number, r.product_id, sum(r.qty) qty
                    from r where r.product_id is not null
                   group by r.card_id, r.name, r.set_code, r.collector_number, r.product_id) g)
    into v_lines, v_unknown, v_products;

  foreach v_line in array coalesce(v_lines, '{}') loop
    v_line := t1_private.url_encode(v_line);
    if v_part <> '' and length(v_base) + length(v_part) + 2 + length(v_line) > v_max then
      v_urls := v_urls || (v_base || v_part);
      v_part := '';
    end if;
    v_part := case when v_part = '' then v_line else v_part || '||' || v_line end;
  end loop;
  if v_part <> '' then v_urls := v_urls || (v_base || v_part); end if;

  return jsonb_build_object('enabled', true, 'lines', coalesce(cardinality(v_lines), 0), 'unknown', v_unknown,
    'urls', coalesce((select jsonb_agg(replace(replace(v_link, '{url_encoded}', t1_private.url_encode(u)), '{url}', u) order by n)
                        from unnest(v_urls) with ordinality t(u, n)), '[]'::jsonb),
    'products', v_products);
end $$;

do $$
begin
  revoke all on table t1_private.card_tcgplayer from public, anon, authenticated;
  revoke execute on function public.tcgplayer_cart(jsonb, boolean) from public, anon;
  grant execute on function public.tcgplayer_cart(jsonb, boolean) to authenticated;
end $$;
