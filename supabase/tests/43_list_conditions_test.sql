-- Deck and cube lines record a condition (contract/lists-2026-10-15.md, "Conditions"; 2026-11-01).
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''

insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil,foil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001', 'lea', '161', 'en', 'common', '{nonfoil}', 'normal', 'h');
\set BOLT '''c1000000-0000-0000-0000-000000000001'''
\set LEA '''c1000000-0000-0000-0000-000000000002'''
\set DECK '''d0000000-0000-0000-0000-0000000000d1'''
create or replace function pg_temp.lines(l uuid, b text) returns text language sql as
$$ select coalesce((select string_agg(qty || ' ' || set_code || ' ' || finish || ' ' || e.lang || ' ' || condition, ', '
                                      order by set_code, finish, e.lang, array_position(array['NM','LP','MP','HP','DMG'], condition))
                      from public.card_list_entries e join public.cards c on c.id = e.card_id
                     where list_id = l and board = b), 'none') $$;

set role authenticated;
select pg_temp.as_user(:ANA);
-- Older entries (3–5 elements) are NM; a sixth element names the condition; lowercase reads; NM and LP are two lines.
select public.list_create(:DECK, 'deck', 'Burn', 'modern', jsonb_build_array(
  jsonb_build_array(:BOLT, 'main', 2), jsonb_build_array(:BOLT, 'main', 1, 'nonfoil', 'en', 'lp'),
  jsonb_build_array(:BOLT, 'main', 1, 'nonfoil', 'en', 'LP'), jsonb_build_array(:BOLT, 'main', 1, 'nonfoil', 'en', 'NM'),
  jsonb_build_array(:LEA, 'side', 1, 'nonfoil', 'ja', 'HP'))) is not null as created \gset
reset role;
select pg_temp.eq('NM and LP copies of one printing are two lines; NM given or left out is the same line',
  pg_temp.lines(:DECK, 'main'), '3 m10 nonfoil en NM, 2 m10 nonfoil en LP');
select pg_temp.eq('condition and language together', pg_temp.lines(:DECK, 'side'), '1 lea nonfoil ja HP');
select pg_temp.eq('the version writes the condition only when it isn''t NM, with finish and language',
  (select entries::text from public.card_list_versions where list_id = :DECK and version = 1),
  format('[["%s", "main", 3], ["%s", "main", 2, "nonfoil", "en", "LP"], ["%s", "side", 1, "nonfoil", "ja", "HP"]]', :BOLT, :BOLT, :LEA));

set role authenticated;
select pg_temp.as_user(:ANA);
-- A delta without cond is NM; with cond it's that line; moving a section keeps the condition.
select public.list_edit(:DECK, jsonb_build_array(
  jsonb_build_object('card_id', :BOLT, 'board', 'main', 'cond', 'LP', 'delta', -1),
  jsonb_build_object('card_id', :BOLT, 'board', 'main', 'delta', 1),
  jsonb_build_object('card_id', :LEA, 'lang', 'ja', 'cond', 'HP', 'from', 'side', 'to', 'maybe'))) is not null as e1 \gset
reset role;
select pg_temp.eq('delta by condition', pg_temp.lines(:DECK, 'main'), '4 m10 nonfoil en NM, 1 m10 nonfoil en LP');
select pg_temp.eq('moving a section keeps the condition', pg_temp.lines(:DECK, 'maybe'), '1 lea nonfoil ja HP');

set role authenticated;
select pg_temp.as_user(:ANA);
-- Another printing keeps the line's condition; to_cond moves copies to another condition.
select public.list_edit(:DECK, jsonb_build_array(
  jsonb_build_object('card_id', :BOLT, 'board', 'main', 'cond', 'LP', 'to_card_id', :LEA, 'qty', 1),
  jsonb_build_object('card_id', :BOLT, 'board', 'main', 'to_cond', 'MP', 'qty', 2))) is not null as e2 \gset
reset role;
select pg_temp.eq('another printing keeps the condition; to_cond splits the line',
  pg_temp.lines(:DECK, 'main'), '1 lea nonfoil en LP, 2 m10 nonfoil en NM, 2 m10 nonfoil en MP');

set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.throws('a condition that isn''t one is refused',
  format($$select public.list_edit('%s', '[{"card_id":"%s","board":"main","cond":"GD","delta":1}]')$$, :DECK, :BOLT), '22023');
select pg_temp.throws('a to_cond that isn''t one is refused',
  format($$select public.list_edit('%s', '[{"card_id":"%s","board":"main","to_cond":"X","qty":1}]')$$, :DECK, :BOLT), '22023');
select pg_temp.throws('a condition in list_create that isn''t one is refused',
  format($$select public.list_create(gen_random_uuid(), 'deck', 'X', 'modern', '[["%s", "main", 1, "nonfoil", "en", "GD"]]')$$, :BOLT), '22023');
select pg_temp.throws('another account can''t edit the list',
  format($$select public.list_edit('%s', '[{"card_id":"%s","board":"main","cond":"LP","delta":1}]')$$, :DECK, :BOLT))
  from (select pg_temp.as_user(:BEN)) x;
-- Retrying the same qty op is idempotent.
select pg_temp.as_user(:ANA);
select public.list_edit(:DECK, '[{"card_id":"c1000000-0000-0000-0000-000000000001","board":"main","cond":"MP","qty":3}]') is not null as e3 \gset
select public.list_edit(:DECK, '[{"card_id":"c1000000-0000-0000-0000-000000000001","board":"main","cond":"MP","qty":3}]') is not null as e4 \gset
reset role;
select pg_temp.eq('a repeated qty op changes nothing more',
  pg_temp.lines(:DECK, 'main'), '1 lea nonfoil en LP, 2 m10 nonfoil en NM, 3 m10 nonfoil en MP');
-- Restoring version 1 brings its conditions back.
set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_restore(:DECK, 1) is not null as r1 \gset
reset role;
select pg_temp.eq('restoring a version keeps its conditions', pg_temp.lines(:DECK, 'main'), '3 m10 nonfoil en NM, 2 m10 nonfoil en LP');
