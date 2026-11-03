-- Follow art (contract/follows-2026-10-25.md § Follow art): each followed item's tile picture.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''

insert into public.card_oracles (oracle_id, name, name_norm, layout, type_line, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'Instant', 'c1000000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000002', 'Opt', 'opt', 'normal', 'Instant', 'c1000000-0000-0000-0000-000000000002', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000003', 'Mountain', 'mountain', 'normal', 'Basic Land — Mountain', 'c1000000-0000-0000-0000-000000000003', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000004', 'Counterspell', 'counterspell', 'normal', 'Instant', 'c1000000-0000-0000-0000-000000000004', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, released_at, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil}', 'normal', '2009-07-17', 'h'),
  ('c1000000-0000-0000-0000-000000000011', 'c0000000-0000-0000-0000-000000000001', 'lea', '161', 'en', 'common', '{nonfoil}', 'normal', '1993-08-05', 'h'),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'xln', '65', 'en', 'common', '{nonfoil}', 'normal', '2017-09-29', 'h'),
  ('c1000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000003', 'm10', '242', 'en', 'common', '{nonfoil}', 'normal', '2009-07-17', 'h'),
  ('c1000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000004', 'mh2', '267', 'en', 'common', '{nonfoil}', 'normal', '2021-06-18', 'h'),
  ('c1000000-0000-0000-0000-000000000014', 'c0000000-0000-0000-0000-000000000004', 'lea', '54', 'en', 'common', '{nonfoil}', 'normal', '1993-08-05', 'h');
\set BOLT '''c1000000-0000-0000-0000-000000000001'''
\set OPT '''c1000000-0000-0000-0000-000000000002'''
\set MOUNTAIN '''c1000000-0000-0000-0000-000000000003'''
\set DECK '''d1000000-0000-0000-0000-000000000001'''
\set CUBE '''d1000000-0000-0000-0000-000000000002'''
\set TRADES '''b1000000-0000-0000-0000-000000000001'''

create or replace function pg_temp.art(p_id uuid) returns text language sql as $$
  select coalesce((select i->>'art' from jsonb_array_elements(public.follows_list()->'items') i where (i->>'id')::uuid = p_id), 'none');
$$;

set role authenticated;
select pg_temp.as_user(:BEN);
select public.friend_request(:ANA);
select pg_temp.as_user(:ANA);
select public.friend_respond(:BEN, true);
select public.binder_save(:TRADES, 'Trades', true);
select public.list_create(:DECK, 'deck', 'Burn', 'modern', jsonb_build_array(
  jsonb_build_array(:MOUNTAIN, 'main', 20), jsonb_build_array(:BOLT, 'main', 4), jsonb_build_array(:OPT, 'side', 4)));
select public.list_create(:CUBE, 'cube', 'Pauper cube', 'cube', jsonb_build_array(
  jsonb_build_array(:OPT, 'main', 1), jsonb_build_array(:BOLT, 'main', 1)));
select public.sharing_set(jsonb_build_object('items', jsonb_build_array(
  jsonb_build_object('kind', 'deck', 'id', :DECK, 'visibility', 'friends'),
  jsonb_build_object('kind', 'cube', 'id', :CUBE, 'visibility', 'friends'),
  jsonb_build_object('kind', 'binder', 'id', :TRADES, 'visibility', 'friends'))));

select pg_temp.as_user(:BEN);
select public.follow_set('deck', :DECK, true);
select public.follow_set('cube', :CUBE, true);
select public.follow_set('binder', :TRADES, true);
select pg_temp.eq('no hero: the most copies that isn''t a basic, sideboard left out', pg_temp.art(:DECK), 'c1000000-0000-0000-0000-000000000001');
select pg_temp.eq('a tie goes by name', pg_temp.art(:CUBE), 'c1000000-0000-0000-0000-000000000001');
select pg_temp.eq('an empty binder has no art', pg_temp.art(:TRADES), 'none');

select pg_temp.as_user(:ANA);
select public.library_heroes_set('list', :CUBE, array['c0000000-0000-0000-0000-000000000002']::uuid[]);
select public.library_heroes_set('list', :DECK, array['c0000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000001']::uuid[]);
select public.collection_apply(jsonb_build_array(jsonb_build_object('card_id', 'c1000000-0000-0000-0000-000000000011', 'delta', 2, 'binder_id', :TRADES)),
  'manual', null, 'e2000000-0000-0000-0000-000000000001');
select pg_temp.as_user(:BEN);
select pg_temp.eq('the owner''s hero, in the printing the cube holds', pg_temp.art(:CUBE), 'c1000000-0000-0000-0000-000000000002');
select pg_temp.eq('a hero the deck doesn''t hold: its earliest printing', pg_temp.art(:DECK), 'c1000000-0000-0000-0000-000000000014');
select pg_temp.eq('a binder by its copies', pg_temp.art(:TRADES), 'c1000000-0000-0000-0000-000000000011');

select pg_temp.as_user(:ANA);
select public.sharing_set(jsonb_build_object('items', jsonb_build_array(jsonb_build_object('kind', 'deck', 'id', :DECK, 'visibility', 'private'))));
select pg_temp.as_user(:BEN);
select pg_temp.eq('nothing once it isn''t available', pg_temp.art(:DECK), 'none');
select pg_temp.throws('clients can''t call the helper', $$select t1_private.follow_art('deck', 'd1000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1')$$, '42501');
reset role;
