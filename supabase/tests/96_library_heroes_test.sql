-- Hero cards (contract/library-heroes-2026-10-19.md).
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''

insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000002', 'Opt', 'opt', 'normal', 'c1000000-0000-0000-0000-000000000002', 'a', 'h');
\set BOLT '''c0000000-0000-0000-0000-000000000001'''
\set OPT '''c0000000-0000-0000-0000-000000000002'''
\set DECK '''d1000000-0000-0000-0000-000000000001'''
\set BINDER '''b0000000-0000-0000-0000-000000000001'''

set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_create(:DECK, 'deck', 'Burn', 'modern', '[]'::jsonb);
select public.binder_save(:BINDER, 'Trade binder', true);

-- Setting -------------------------------------------------------------------------
select pg_temp.eq('collection heroes in the order given, duplicates dropped',
  (public.library_heroes_set('collection', null, array[:OPT, :BOLT, :OPT]::uuid[]))::text,
  jsonb_build_object('scope', 'collection', 'target_id', null, 'oracle_ids', jsonb_build_array(:OPT, :BOLT))::text);
select pg_temp.eq('a deck hero', (public.library_heroes_set('list', :DECK, array[:BOLT]::uuid[]))->'oracle_ids'->>0,
  'c0000000-0000-0000-0000-000000000001');
select pg_temp.eq('setting again is the same row',
  (public.library_heroes_set('list', :DECK, array[:BOLT]::uuid[]))->>'target_id', 'd1000000-0000-0000-0000-000000000001');
select public.library_heroes_set('binder', :BINDER, array[:OPT]::uuid[]);
select pg_temp.eq('three scopes', jsonb_array_length(public.library_heroes())::text, '3');
select pg_temp.eq('clearing deletes the row', (public.library_heroes_set('binder', :BINDER, '{}'))->>'oracle_ids', '[]');
select pg_temp.eq('two scopes left', jsonb_array_length(public.library_heroes())::text, '2');

-- Refusals --------------------------------------------------------------------------
select pg_temp.throws('unknown card', $$select public.library_heroes_set('collection', null, array[gen_random_uuid()])$$, '22023');
select pg_temp.throws('bad scope', $$select public.library_heroes_set('trade', null, '{}')$$, '22023');
select pg_temp.throws('a list needs its id', $$select public.library_heroes_set('list', null, '{}')$$, '22023');
select pg_temp.throws('at most 10', $$select public.library_heroes_set('collection', null,
  array(select gen_random_uuid() from generate_series(1, 11)))$$, '22023');
select pg_temp.as_user(:BEN);
select pg_temp.throws('not your deck', $$select public.library_heroes_set('list', 'd1000000-0000-0000-0000-000000000001', array['c0000000-0000-0000-0000-000000000001'::uuid])$$, '42501');
select pg_temp.throws('not your binder', $$select public.library_heroes_set('binder', 'b0000000-0000-0000-0000-000000000001', '{}')$$, '42501');
select pg_temp.eq('someone else sees none of them', jsonb_array_length(public.library_heroes())::text, '0');
select pg_temp.throws('no direct reads', $$select * from public.library_heroes$$, '42501');
select pg_temp.throws('no direct writes', $$insert into public.library_heroes values ('00000000-0000-0000-0000-0000000000b1', 'collection', '00000000-0000-0000-0000-000000000000', array['c0000000-0000-0000-0000-000000000001'::uuid])$$, '42501');
select pg_temp.as_user(null);
select pg_temp.throws('signed out', $$select public.library_heroes_set('collection', null, '{}')$$, '28000');

-- Deleting a deck drops its heroes -------------------------------------------------------
select pg_temp.as_user(:ANA);
select public.list_delete(:DECK);
select pg_temp.eq('only the collection is left', (public.library_heroes())->0->>'scope', 'collection');
reset role;
select pg_temp.eq('the deck row is gone', (select count(*)::text from public.library_heroes where scope = 'list'), '0');
