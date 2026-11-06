-- Buy on TCGplayer: wants or Missing as a Mass Entry cart (contract/tcgplayer-cart-2026-10-26.md).
\ir _helpers.sql

-- The affiliate link is live config (20261106120000_tcgplayer_affiliate.sql); these checks start from the defaults.
delete from t1_private.settings where name like 'tcgplayer.%';

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''

insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Fire // Ice', 'fire // ice', 'split', 'c1000000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000002', 'Delver of Secrets // Insectile Aberration', 'delver of secrets // insectile aberration', 'transform', 'c1000000-0000-0000-0000-000000000002', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000003', 'Bonecrusher Giant // Stomp', 'bonecrusher giant // stomp', 'adventure', 'c1000000-0000-0000-0000-000000000003', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000004', 'Orim''s Chant', 'orim''s chant', 'normal', 'c1000000-0000-0000-0000-000000000004', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000005', 'Æther Vial', 'aether vial', 'normal', 'c1000000-0000-0000-0000-000000000005', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'apc', '128', 'en', 'uncommon', '{nonfoil}', 'split', 'h'),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'isd', '51', 'en', 'common', '{nonfoil,foil}', 'transform', 'h'),
  ('c1000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000003', 'eld', '115', 'en', 'rare', '{nonfoil,foil}', 'adventure', 'h'),
  ('c1000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000004', 'pls', '11', 'en', 'rare', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000005', 'c0000000-0000-0000-0000-000000000005', 'dst', '91', 'en', 'uncommon', '{nonfoil}', 'normal', 'h');

-- TCGplayer products: Bonecrusher Giant ELD 115 has one, Delver ISD 51 only an etched one, the rest none.
insert into t1_private.card_tcgplayer (card_id, product_id, etched_product_id) values
  ('c1000000-0000-0000-0000-000000000003', 198586, null),
  ('c1000000-0000-0000-0000-000000000002', null, 55501);

create or replace function pg_temp.cart(items jsonb) returns jsonb language sql as $$ select public.tcgplayer_cart(items) $$;
create or replace function pg_temp.cart2(items jsonb) returns jsonb language sql as $$ select public.tcgplayer_cart(items, true) $$;
\set BASE '''https://www.tcgplayer.com/massentry?productline=Magic&c='''

select pg_temp.eq('url_encode matches encodeURIComponent (and escapes the apostrophe)',
  t1_private.url_encode('1 Orim''s Chant [PLS] 11, Æ // ~-_.'), '1%20Orim%27s%20Chant%20%5BPLS%5D%2011%2C%20%C3%86%20%2F%2F%20~-_.');

set role authenticated;
select pg_temp.as_user(null);
select pg_temp.throws('signed out: refused', $$select public.tcgplayer_cart('[]')$$, '28000');
select pg_temp.as_user(:ANA);

select pg_temp.eq('the cart',
  (pg_temp.cart(jsonb_build_array(
     jsonb_build_object('oracle_id', 'c0000000-0000-0000-0000-000000000001', 'qty', 1),
     jsonb_build_object('oracle_id', 'c0000000-0000-0000-0000-000000000002', 'qty', 4),
     jsonb_build_object('card_id', 'c1000000-0000-0000-0000-000000000003', 'qty', 2),
     jsonb_build_object('oracle_id', 'c0000000-0000-0000-0000-000000000004', 'card_id', 'c1000000-0000-0000-0000-000000000004', 'qty', 1),
     jsonb_build_object('card_id', 'c1000000-0000-0000-0000-000000000004', 'qty', 2),
     jsonb_build_object('oracle_id', 'c0000000-0000-0000-0000-000000000005', 'qty', 1),
     jsonb_build_object('oracle_id', 'c0000000-0000-0000-0000-0000000000ff', 'qty', 1))))::text,
  '{"urls": ["' || :BASE || '2%20Bonecrusher%20Giant||4%20Delver%20of%20Secrets||1%20Fire%20%2F%2F%20Ice||3%20Orim%27s%20Chant||1%20%C3%86ther%20Vial"], "lines": 5, "enabled": true, "unknown": 1, "products": []}');

-- A printing is named by its card alone: TCGplayer refuses the whole cart over one "[SET] number" it can't match.
select pg_temp.eq('apps from before: a printing and any printing of the same card are one line, with no set or number',
  pg_temp.cart(jsonb_build_array(
     jsonb_build_object('card_id', 'c1000000-0000-0000-0000-000000000005', 'qty', 1),
     jsonb_build_object('oracle_id', 'c0000000-0000-0000-0000-000000000005', 'qty', 2)))->'urls'->>0,
  :BASE || '3%20%C3%86ther%20Vial');

-- New apps: a printing with a TCGplayer product is a link to its page; one without goes into Mass Entry by name.
select pg_temp.eq('new apps: printings with a product are product links, the rest Mass Entry',
  pg_temp.cart2(jsonb_build_array(
     jsonb_build_object('oracle_id', 'c0000000-0000-0000-0000-000000000001', 'qty', 1),
     jsonb_build_object('card_id', 'c1000000-0000-0000-0000-000000000002', 'qty', 1),
     jsonb_build_object('card_id', 'c1000000-0000-0000-0000-000000000003', 'qty', 2),
     jsonb_build_object('card_id', 'c1000000-0000-0000-0000-000000000003', 'qty', 1),
     jsonb_build_object('oracle_id', 'c0000000-0000-0000-0000-000000000003', 'qty', 1),
     jsonb_build_object('card_id', 'c1000000-0000-0000-0000-000000000004', 'qty', 2)))::text,
  '{"urls": ["' || :BASE || '1%20Bonecrusher%20Giant||1%20Fire%20%2F%2F%20Ice||2%20Orim%27s%20Chant"], "lines": 3, "enabled": true, "unknown": 0, "products": ['
  || '{"qty": 3, "set": "ELD", "url": "https://www.tcgplayer.com/product/198586", "name": "Bonecrusher Giant", "number": "115", "card_id": "c1000000-0000-0000-0000-000000000003"}, '
  || '{"qty": 1, "set": "ISD", "url": "https://www.tcgplayer.com/product/55501", "name": "Delver of Secrets", "number": "51", "card_id": "c1000000-0000-0000-0000-000000000002"}]}');
select pg_temp.eq('new apps: only product links, no Mass Entry link',
  pg_temp.cart2('[{"card_id": "c1000000-0000-0000-0000-000000000003", "qty": 1}]')::text,
  '{"urls": [], "lines": 0, "enabled": true, "unknown": 0, "products": [{"qty": 1, "set": "ELD", "url": "https://www.tcgplayer.com/product/198586", "name": "Bonecrusher Giant", "number": "115", "card_id": "c1000000-0000-0000-0000-000000000003"}]}');

select pg_temp.eq('nothing to buy: no urls', pg_temp.cart('[]')::text, '{"urls": [], "lines": 0, "enabled": true, "unknown": 0, "products": []}');
select pg_temp.throws('qty 0 refused', $$select public.tcgplayer_cart('[{"oracle_id": "c0000000-0000-0000-0000-000000000001", "qty": 0}]')$$, '22023');
select pg_temp.throws('no card refused', $$select public.tcgplayer_cart('[{"qty": 1}]')$$, '22023');
select pg_temp.throws('not an array refused', $$select public.tcgplayer_cart('{}')$$, '22023');
select pg_temp.throws('2001 items refused', $$select public.tcgplayer_cart((select jsonb_agg(jsonb_build_object('oracle_id', 'c0000000-0000-0000-0000-000000000001', 'qty', 1)) from generate_series(1, 2001)))$$, '22023');
reset role;

-- Parts, the affiliate wrapper, off --------------------------------------------------------------------------
insert into t1_private.settings (name, value) values ('tcgplayer.max_url', '120');
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('a long list splits into parts (each under the limit), every line in one',
  (select (jsonb_array_length(c->'urls') > 1)::text || ':' || (select bool_and(length(u) <= 120)::text || ':' || sum(array_length(string_to_array(substr(u, 56), '||'), 1)) from jsonb_array_elements_text(c->'urls') u)
     from (select pg_temp.cart((select jsonb_agg(jsonb_build_object('oracle_id', o, 'qty', 1))
             from unnest(array['c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002',
                               'c0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000004',
                               'c0000000-0000-0000-0000-000000000005']) o)) c) x),
  'true:true:5');
reset role;
insert into t1_private.settings (name, value) values ('tcgplayer.link', 'https://partner.tcgplayer.com/c/1/2/3?u={url_encoded}');
delete from t1_private.settings where name = 'tcgplayer.max_url';
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('wrapped for the affiliate link',
  pg_temp.cart('[{"oracle_id": "c0000000-0000-0000-0000-000000000005", "qty": 2}]')->'urls'->>0,
  'https://partner.tcgplayer.com/c/1/2/3?u=https%3A%2F%2Fwww.tcgplayer.com%2Fmassentry%3Fproductline%3DMagic%26c%3D2%2520%25C3%2586ther%2520Vial');
select pg_temp.eq('product links wrapped too',
  pg_temp.cart2('[{"card_id": "c1000000-0000-0000-0000-000000000003", "qty": 1}]')->'products'->0->>'url',
  'https://partner.tcgplayer.com/c/1/2/3?u=https%3A%2F%2Fwww.tcgplayer.com%2Fproduct%2F198586');

-- Tagged with where the click came from (§ Affiliate link): the platform from the library's x-client-info header,
-- the screen from p_from (apps after 2026-11-06); anything else reads unknown.
reset role;
update t1_private.settings set value = 'https://partner.tcgplayer.com/c/1/2/3?subId1={platform}&subId2={from}&u={url_encoded}'
 where name = 'tcgplayer.link';
set role authenticated;
select pg_temp.as_user(:ANA);
create or replace function pg_temp.tags(client text, src text) returns text language plpgsql as $$
begin
  perform set_config('request.headers', json_build_object('x-client-info', client)::text, true);
  return split_part(public.tcgplayer_cart('[{"card_id": "c1000000-0000-0000-0000-000000000003", "qty": 1}]', true, src)->'products'->0->>'url', '&u=', 1);
end $$;
select pg_temp.eq('iOS, from wants', pg_temp.tags('supabase-swift/2.55.3; platform=iOS', 'wants'), 'https://partner.tcgplayer.com/c/1/2/3?subId1=ios&subId2=wants');
select pg_temp.eq('Android, from missing', pg_temp.tags('supabase-kt/3.2.0', 'missing'), 'https://partner.tcgplayer.com/c/1/2/3?subId1=android&subId2=missing');
select pg_temp.eq('web, from a card', pg_temp.tags('supabase-js-web/2.49.1', 'card'), 'https://partner.tcgplayer.com/c/1/2/3?subId1=web&subId2=card');
select pg_temp.eq('older builds send no p_from', pg_temp.tags('supabase-kt/3.2.0', null), 'https://partner.tcgplayer.com/c/1/2/3?subId1=android&subId2=unknown');
select pg_temp.eq('a made-up tag is not passed on', pg_temp.tags('curl/8', 'x&subId3=1'), 'https://partner.tcgplayer.com/c/1/2/3?subId1=unknown&subId2=unknown');
select pg_temp.eq('Mass Entry links tagged too',
  split_part(public.tcgplayer_cart('[{"oracle_id": "c0000000-0000-0000-0000-000000000005", "qty": 2}]', true, 'wants')->'urls'->>0, '&u=', 1),
  'https://partner.tcgplayer.com/c/1/2/3?subId1=unknown&subId2=wants');

-- Impact refuses a link over ~8,200 characters: parts are cut by the finished link too (tcgplayer.max_link).
reset role;
insert into t1_private.settings (name, value) values ('tcgplayer.max_link', '200');
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('parts cut by the wrapped length (each at most max_link), every line in one',
  (select (jsonb_array_length(c->'urls') > 1)::text || ':' || (select bool_and(length(u) <= 200)::text || ':'
          || sum(array_length(string_to_array(split_part(u, '%26c%3D', 2), '%7C%7C'), 1)) from jsonb_array_elements_text(c->'urls') u)
     from (select pg_temp.cart((select jsonb_agg(jsonb_build_object('oracle_id', o, 'qty', 1))
             from unnest(array['c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002',
                               'c0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000004',
                               'c0000000-0000-0000-0000-000000000005']) o)) c) x),
  'true:true:5');
select pg_temp.eq('the measured length is the real one: a part fills to just under max_link',
  (select max(length(u)) > 150 from jsonb_array_elements_text(pg_temp.cart((select jsonb_agg(jsonb_build_object('oracle_id', o, 'qty', 1))
             from unnest(array['c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002',
                               'c0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000004',
                               'c0000000-0000-0000-0000-000000000005']) o))->'urls') u)::text, 'true');
reset role;
delete from t1_private.settings where name = 'tcgplayer.max_link';
insert into t1_private.settings (name, value) values ('tcgplayer.enabled', 'false');
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('off: no rows, no urls', pg_temp.cart('[{"oracle_id": "c0000000-0000-0000-0000-000000000005", "qty": 2}]')::text,
  '{"urls": [], "lines": 0, "enabled": false, "unknown": 0, "products": []}');
reset role;

set role anon;
select pg_temp.throws('anon refused', $$select public.tcgplayer_cart('[]')$$, '42501');
select pg_temp.throws('anon refused the platform', $$select t1_private.client_platform()$$, '42501');
select pg_temp.throws('anon refused the product ids', $$select count(*) from t1_private.card_tcgplayer$$, '42501');
reset role;
