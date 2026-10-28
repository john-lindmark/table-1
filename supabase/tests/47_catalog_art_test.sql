-- Illustrator and frame on P lines (20261028210000_pack_artist_frame.sql): ingested beside the cards, written only
-- for printings that have a row, the parts still equal the body, and only the service role may call it.
\ir _helpers.sql

insert into t1_private.catalog_runs (bulk_updated_at, source_uri) values (now(), 'test') returning id as run \gset

create temp table rows as select jsonb_build_array(
  jsonb_build_object('id', 'b1000000-0000-0000-0000-000000000001', 'oracle_id', 'b0000000-0000-0000-0000-000000000001',
    'name', 'Misty Rainforest', 'layout', 'normal', 'type_line', 'Land', 'cmc', 0, 'colors', '[]'::jsonb,
    'set_code', 'zen', 'collector_number', '220', 'lang', 'en', 'rarity', 'rare', 'finishes', '["nonfoil","foil"]'::jsonb,
    'image_faces', 1, 'produced_mana', 'UG', 'token_card_ids', '[]'::jsonb, 'pair_code', ''),
  jsonb_build_object('id', 'b1000000-0000-0000-0000-000000000002', 'oracle_id', 'b0000000-0000-0000-0000-000000000001',
    'name', 'Misty Rainforest', 'layout', 'normal', 'type_line', 'Land', 'cmc', 0, 'colors', '[]'::jsonb,
    'set_code', 'mh2', 'collector_number', '438', 'lang', 'en', 'rarity', 'rare', 'finishes', '["nonfoil","foil","etched"]'::jsonb,
    'image_faces', 1, 'produced_mana', 'UG', 'token_card_ids', '[]'::jsonb, 'pair_code', '')
) r;
select public.catalog_ingest(:run, (select r from rows)) as first \gset

create or replace function pg_temp.p(cn text) returns text[] language sql as
$$ select string_to_array(l, E'\t') from unnest(string_to_array(public.catalog_pack_part(1, 0, 100), E'\n')) l
    where split_part(l, E'\t', 5) = cn $$;

select pg_temp.eq('before any art, P lines end at original', array_length(pg_temp.p('220'), 1)::text, '13');
select public.catalog_pack_body() as body_before \gset

-- Art for one printing, a tab in the name, and a card the catalog doesn't hold (skipped).
select public.catalog_art_ingest(:run, '[
  {"id": "b1000000-0000-0000-0000-000000000002", "artist": "Shelly\tWan", "frame": "1997"},
  {"id": "b1000000-0000-0000-0000-000000000009", "artist": "Nobody", "frame": "2015"}]'::jsonb) as n1 \gset
select pg_temp.eq('one row written', :'n1', '1');
select pg_temp.eq('the retro printing carries artist and frame', (pg_temp.p('438'))[14] || '|' || (pg_temp.p('438'))[15], 'Shelly Wan|1997');
select pg_temp.eq('a printing without art still ends at original', array_length(pg_temp.p('220'), 1)::text, '13');
select pg_temp.eq('the pack changed', (public.catalog_pack_body() <> :'body_before')::text, 'true');
select pg_temp.eq('parts joined equal the body with art',
  (select concat_ws(E'\n', public.catalog_pack_part(0, 0, 100), public.catalog_pack_part(1, 0, 100), public.catalog_pack_part(2, 0, 100))),
  public.catalog_pack_body());

select public.catalog_art_ingest(:run, '[{"id": "b1000000-0000-0000-0000-000000000002", "artist": "Shelly Wan", "frame": "1997"}]'::jsonb) as n2 \gset
select pg_temp.eq('the same art again writes nothing', :'n2', '0');
select public.catalog_art_ingest(:run, '[{"id": "b1000000-0000-0000-0000-000000000002", "artist": "Shelly Wan", "frame": "2015"}]'::jsonb) as n3 \gset
select pg_temp.eq('a changed frame rewrites the row', :'n3' || '|' || (pg_temp.p('438'))[15], '1|2015');

-- Null fields are empty strings, never null in the line.
select public.catalog_art_ingest(:run, '[{"id": "b1000000-0000-0000-0000-000000000001", "artist": null, "frame": null}]'::jsonb) as n4 \gset
select pg_temp.eq('null art is empty fields', :'n4' || ':' || array_length(pg_temp.p('220'), 1)::text || ':' || (pg_temp.p('220'))[14] || (pg_temp.p('220'))[15], '1:15:');

-- Refusals: an unknown run, and callers other than the service role.
select pg_temp.throws('unknown run refused', format('select public.catalog_art_ingest(%s, ''[]''::jsonb)', :run + 1000000), 'P0002');
select pg_temp.eq('anon may not call it',
  (select has_function_privilege('anon', 'public.catalog_art_ingest(bigint, jsonb)', 'execute'))::text, 'false');
select pg_temp.eq('authenticated may not call it',
  (select has_function_privilege('authenticated', 'public.catalog_art_ingest(bigint, jsonb)', 'execute'))::text, 'false');
