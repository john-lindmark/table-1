-- Catalog ingest and pack: produced mana, token links and pair codes on O lines (contract/catalog-2026-10-14.md).
\ir _helpers.sql

insert into t1_private.catalog_runs (bulk_updated_at, source_uri) values (now(), 'test') returning id as run \gset

-- What cards-sync sends (catalog.ts SlimCard): a fetch land, a card that makes a token (two printings of the same
-- token), the token itself (listing itself, as Scryfall does), and a card with no produced_mana key (an older
-- cards-sync).
create temp table rows as select jsonb_build_array(
  jsonb_build_object('id', 'a1000000-0000-0000-0000-000000000001', 'oracle_id', 'a0000000-0000-0000-0000-000000000001',
    'name', 'Polluted Delta', 'layout', 'normal', 'type_line', 'Land', 'cmc', 0, 'colors', '[]'::jsonb,
    'legalities', '{"modern":"legal"}'::jsonb, 'set_code', 'ons', 'collector_number', '321', 'lang', 'en',
    'rarity', 'rare', 'finishes', '["nonfoil"]'::jsonb, 'image_faces', 1,
    'produced_mana', 'UB', 'token_card_ids', '[]'::jsonb),
  jsonb_build_object('id', 'a1000000-0000-0000-0000-000000000002', 'oracle_id', 'a0000000-0000-0000-0000-000000000002',
    'name', 'Young Pyromancer', 'layout', 'normal', 'type_line', 'Creature — Human Shaman', 'mana_cost', '{1}{R}',
    'cmc', 2, 'colors', '["R"]'::jsonb, 'legalities', '{"modern":"legal"}'::jsonb, 'set_code', 'm14',
    'collector_number', '163', 'lang', 'en', 'rarity', 'uncommon', 'finishes', '["nonfoil","foil"]'::jsonb,
    'image_faces', 1, 'produced_mana', '',
    'token_card_ids', '["a1000000-0000-0000-0000-000000000003","a1000000-0000-0000-0000-000000000004"]'::jsonb),
  jsonb_build_object('id', 'a1000000-0000-0000-0000-000000000003', 'oracle_id', 'a0000000-0000-0000-0000-000000000003',
    'name', 'Elemental', 'layout', 'token', 'type_line', 'Token Creature — Elemental', 'cmc', 0,
    'colors', '["R"]'::jsonb, 'set_code', 'tm14', 'collector_number', '7', 'lang', 'en', 'rarity', 'common',
    'finishes', '["nonfoil"]'::jsonb, 'image_faces', 1, 'produced_mana', '',
    'token_card_ids', '["a1000000-0000-0000-0000-000000000003"]'::jsonb),
  jsonb_build_object('id', 'a1000000-0000-0000-0000-000000000004', 'oracle_id', 'a0000000-0000-0000-0000-000000000003',
    'name', 'Elemental', 'layout', 'token', 'type_line', 'Token Creature — Elemental', 'cmc', 0,
    'colors', '["R"]'::jsonb, 'set_code', 'tdmu', 'collector_number', '9', 'lang', 'en', 'rarity', 'common',
    'finishes', '["nonfoil"]'::jsonb, 'image_faces', 1, 'produced_mana', '', 'token_card_ids', '[]'::jsonb),
  jsonb_build_object('id', 'a1000000-0000-0000-0000-000000000005', 'oracle_id', 'a0000000-0000-0000-0000-000000000005',
    'name', 'Island', 'layout', 'normal', 'type_line', 'Basic Land — Island', 'cmc', 0, 'colors', '[]'::jsonb,
    'set_code', 'lea', 'collector_number', '288', 'lang', 'en', 'rarity', 'common',
    'finishes', '["nonfoil"]'::jsonb, 'image_faces', 1)
) r;

select public.catalog_ingest(:run, (select r from rows)) as first \gset
select pg_temp.eq('ingest writes every card', (:'first'::jsonb)->>'oracles', '4');
select pg_temp.eq('produced mana stored',
  (select string_agg(name || '=' || coalesce(produced_mana, 'null'), ' ' order by name) from public.card_oracles),
  'Elemental= Island=null Polluted Delta=UB Young Pyromancer=');
select pg_temp.eq('token printings stored',
  (select cardinality(token_card_ids)::text from public.card_oracles where name = 'Young Pyromancer'), '2');

select public.catalog_ingest(:run, (select r from rows)) as again \gset
select pg_temp.eq('same rows again change nothing', (:'again'::jsonb)->>'oracles', '0');

-- Pack: name order is Elemental 0, Island 1, Polluted Delta 2, Young Pyromancer 3.
create temp table o as
select split_part(l, E'\t', 4) name, l, array_length(string_to_array(l, E'\t'), 1) n
  from unnest(string_to_array(public.catalog_pack_part(0, 0, 100), E'\n')) l;
create or replace function pg_temp.field(card text, i int) returns text language sql as
$$ select split_part(l, E'\t', i) from o where name = card $$;

select pg_temp.eq('O lines carry produced and tokens', (select string_agg(name || ':' || n, ' ' order by name) from o),
  'Elemental:14 Island:12 Polluted Delta:14 Young Pyromancer:14');
select pg_temp.eq('produced field', pg_temp.field('Polluted Delta', 13) || '|' || pg_temp.field('Young Pyromancer', 13), 'UB|');
select pg_temp.eq('tokens are O-line indexes, one per token card', pg_temp.field('Young Pyromancer', 14), '0');
select pg_temp.eq('a token never links to itself', pg_temp.field('Elemental', 14), '');
select pg_temp.eq('a card not read since the change ends at points', pg_temp.field('Island', 11), '--------');

-- A newer cards-sync fills the Island in.
select public.catalog_ingest(:run, jsonb_build_array((select r->4 from rows) || '{"produced_mana":"U","token_card_ids":[]}'::jsonb)) as fill \gset
select pg_temp.eq('a filled field rewrites the row', (:'fill'::jsonb)->>'oracles', '1');
select pg_temp.eq('Island now produces U',
  (select split_part(l, E'\t', 13) from unnest(string_to_array(public.catalog_pack_part(0, 0, 100), E'\n')) l
    where l like E'O\t1\t%'), 'U');

select pg_temp.eq('parts joined equal the body',
  (select concat_ws(E'\n', public.catalog_pack_part(0, 0, 2), public.catalog_pack_part(0, 2, 100),
                    public.catalog_pack_part(1, 0, 100), public.catalog_pack_part(2, 0, 100))),
  public.catalog_pack_body());

-- Pair codes (20261028120000_pack_pair_codes.sql): a partner commander, and Young Pyromancer read again with none.
select public.catalog_ingest(:run, jsonb_build_array(
  jsonb_build_object('id', 'a1000000-0000-0000-0000-000000000006', 'oracle_id', 'a0000000-0000-0000-0000-000000000006',
    'name', 'Pir, Imaginative Rascal', 'layout', 'normal', 'type_line', 'Legendary Creature — Human', 'cmc', 3,
    'colors', '["G"]'::jsonb, 'set_code', 'bbd', 'collector_number', '11', 'lang', 'en', 'rarity', 'rare',
    'finishes', '["nonfoil"]'::jsonb, 'image_faces', 1, 'produced_mana', '', 'token_card_ids', '[]'::jsonb,
    'pair_code', 'P:Toothy, Imaginary Friend'),
  (select r->1 from rows) || '{"pair_code":""}'::jsonb)) as pairs \gset
select pg_temp.eq('pair codes stored, and a new pair code rewrites the row', (:'pairs'::jsonb)->>'oracles', '2');
-- Name order now: Elemental 0, Island 1, Pir 2, Polluted Delta 3, Young Pyromancer 4.
drop table o;
create temp table o as
select split_part(l, E'\t', 4) name, l, array_length(string_to_array(l, E'\t'), 1) n
  from unnest(string_to_array(public.catalog_pack_part(0, 0, 100), E'\n')) l;
select pg_temp.eq('pair is the field after tokens', pg_temp.field('Pir, Imaginative Rascal', 15), 'P:Toothy, Imaginary Friend');
select pg_temp.eq('no pair ability is an empty field; not read yet ends at tokens',
  (select string_agg(name || ':' || n, ' ' order by name) from o),
  'Elemental:14 Island:14 Pir, Imaginative Rascal:15 Polluted Delta:14 Young Pyromancer:15');
select pg_temp.eq('parts joined still equal the body',
  (select concat_ws(E'\n', public.catalog_pack_part(0, 0, 3), public.catalog_pack_part(0, 3, 100),
                    public.catalog_pack_part(1, 0, 100), public.catalog_pack_part(2, 0, 100))),
  public.catalog_pack_body());

