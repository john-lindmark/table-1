-- Sideboard guides (contract/sideboard-guide-2026-11-04.md): list_guide_set, guide on list_json, cleaning.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''

insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil}', 'normal', 'h');
\set BOLT '''c1000000-0000-0000-0000-000000000001'''
\set DECK '''d0000000-0000-0000-0000-0000000000d1'''
\set CUBE '''d0000000-0000-0000-0000-0000000000c1'''

set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_create(:DECK, 'deck', 'Izzet', 'modern', jsonb_build_array(jsonb_build_array(:BOLT, 'main', 4))) as c \gset
select public.list_create(:CUBE, 'cube', 'Cube', 'vintage', jsonb_build_array(jsonb_build_array(:BOLT, 'main', 1))) as k \gset
select pg_temp.eq('a new deck has no guide', (:'c'::jsonb)->>'guide', null);

-- Set ------------------------------------------------------------------------------------------------------------
select public.list_guide_set(:DECK, '{"matchups": [{"id": "m1", "name": "  Boros Energy ", "archetype": 12,
  "in": [["o-fury", 2], ["o-blood", 1], ["o-fury", 1]], "out": [["o-bolt", 2]], "notes": " Keep two removal.\n"}]}') as s \gset
select pg_temp.eq('the guide is kept cleaned: trimmed, merged in first place',
  ((:'s'::jsonb)->'guide')::text,
  '{"matchups": [{"id": "m1", "in": [["o-fury", 3], ["o-blood", 1]], "out": [["o-bolt", 2]], "name": "Boros Energy", "notes": "Keep two removal.", "archetype": 12}]}');
select pg_temp.eq('setting moves the seq', (((:'s'::jsonb)->>'seq')::bigint > ((:'c'::jsonb)->>'seq')::bigint)::text, 'true');
select pg_temp.eq('lists_changes carries the guide',
  (select l->'guide'->'matchups'->0->>'name' from jsonb_array_elements(public.lists_changes(0)->'lists') l where l->>'id' = :DECK),
  'Boros Energy');
select (:'s'::jsonb)->>'seq' as seq1 \gset
select public.list_guide_set(:DECK, (:'s'::jsonb)->'guide') as same \gset
select pg_temp.eq('the same guide again changes nothing (idempotent retry)', (:'same'::jsonb)->>'seq', :'seq1');

-- Shapes refused (each matches a make_cases.py normalize case or a limit).
select pg_temp.throws('a blank name is refused', format($$select public.list_guide_set('%s', '{"matchups": [{"id": "a", "name": "   "}]}')$$, :DECK), '22023');
select pg_temp.throws('a zero quantity is refused', format($$select public.list_guide_set('%s', '{"matchups": [{"id": "a", "name": "Burn", "in": [["o", 0]]}]}')$$, :DECK), '22023');
select pg_temp.throws('a fractional quantity is refused', format($$select public.list_guide_set('%s', '{"matchups": [{"id": "a", "name": "Burn", "in": [["o", 1.5]]}]}')$$, :DECK), '22023');
select pg_temp.throws('two matchups with one id are refused', format($$select public.list_guide_set('%s', '{"matchups": [{"id": "a", "name": "A"}, {"id": "a", "name": "B"}]}')$$, :DECK), '22023');
select pg_temp.throws('long notes are refused', format($$select public.list_guide_set('%s', '{"matchups": [{"id": "a", "name": "A", "notes": "%s"}]}')$$, :DECK, repeat('x', 1001)), '22023');
select pg_temp.throws('41 matchups are refused', format($$select public.list_guide_set('%s', %L)$$, :DECK,
  jsonb_build_object('matchups', (select jsonb_agg(jsonb_build_object('id', 'm' || i, 'name', 'M' || i)) from generate_series(1, 41) i))), '22023');
select pg_temp.throws('a cube has no guide', format($$select public.list_guide_set('%s', '{"matchups": [{"id": "a", "name": "A"}]}')$$, :CUBE), '22023');

-- Another account can't read or write it.
select pg_temp.as_user(:BEN);
select pg_temp.throws('another account cannot set the guide', format($$select public.list_guide_set('%s', null)$$, :DECK), 'P0002');
select pg_temp.eq('another account never sees it', (select count(*)::text from jsonb_array_elements(public.lists_changes(0)->'lists')), '0');
select pg_temp.as_user(null);
select pg_temp.throws('a signed-out caller is refused', format($$select public.list_guide_set('%s', null)$$, :DECK), '28000');

-- Clear ----------------------------------------------------------------------------------------------------------
select pg_temp.as_user(:ANA);
select public.list_guide_set(:DECK, '{"matchups": []}') as cleared \gset
select pg_temp.eq('no matchups clears the guide', (:'cleared'::jsonb)->>'guide', null);
reset role;
select pg_temp.eq('anon cannot call it', has_function_privilege('anon', 'public.list_guide_set(uuid, jsonb)', 'execute')::text, 'false');
select pg_temp.eq('clients cannot call the cleaner', has_function_privilege('authenticated', 't1_private.sideboard_guide_clean(jsonb)', 'execute')::text, 'false');
