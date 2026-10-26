-- Collection core and trades (contract/collection-2026-10-15.md, contract/trades-2026-10-16.md).
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''

-- Two cards: Bolt (nonfoil + foil) and Opt (nonfoil only).
insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000002', 'Opt', 'opt', 'normal', 'c1000000-0000-0000-0000-000000000002', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil,foil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'xln', '65', 'en', 'common', '{nonfoil}', 'normal', 'h');
\set BOLT '''c1000000-0000-0000-0000-000000000001'''
\set OPT '''c1000000-0000-0000-0000-000000000002'''

create or replace function pg_temp.qty(u uuid, c uuid, f text default 'nonfoil') returns text language sql as
$$ select coalesce((select sum(qty)::text from public.collection_items where user_id = u and card_id = c and finish = f), '0') $$;

set role authenticated;
select pg_temp.as_user(:ANA);

-- Apply ------------------------------------------------------------------------
select public.collection_apply(
  jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'delta', 4), jsonb_build_object('card_id', :OPT, 'delta', 2)),
  'manual', null, 'e0000000-0000-0000-0000-000000000001') as r1 \gset
reset role;
select pg_temp.eq('apply adds copies', pg_temp.qty(:ANA, :BOLT) || '/' || pg_temp.qty(:ANA, :OPT), '4/2');
select pg_temp.eq('summary counts cards', (:'r1'::jsonb)->'summary'->>'total_qty', '6');
set role authenticated;

select public.collection_apply(
  jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'delta', 4), jsonb_build_object('card_id', :OPT, 'delta', 2)),
  'manual', null, 'e0000000-0000-0000-0000-000000000001') as r1b \gset
select pg_temp.eq('same idempotency key is a duplicate', (:'r1b'::jsonb)->>'duplicate', 'true');
reset role;
select pg_temp.eq('duplicate changes nothing', pg_temp.qty(:ANA, :BOLT), '4');
set role authenticated;

-- Bad batches are rejected whole.
select pg_temp.throws('below zero rejected',
  format($$select public.collection_apply('[{"card_id":"%s","delta":-1},{"card_id":"%s","delta":-9}]', 'manual', null, gen_random_uuid())$$,
         'c1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000002'));
select pg_temp.throws('finish the printing lacks rejected',
  $$select public.collection_apply('[{"card_id":"c1000000-0000-0000-0000-000000000002","finish":"foil","delta":1}]', 'manual', null, gen_random_uuid())$$);
select pg_temp.throws('unknown card rejected',
  $$select public.collection_apply('[{"card_id":"c1000000-0000-0000-0000-0000000000ff","delta":1}]', 'manual', null, gen_random_uuid())$$);
select pg_temp.throws('qty and delta for one item rejected',
  $$select public.collection_apply('[{"card_id":"c1000000-0000-0000-0000-000000000001","qty":3},{"card_id":"c1000000-0000-0000-0000-000000000001","delta":1}]', 'manual', null, gen_random_uuid())$$);
reset role;
select pg_temp.eq('rejected batches wrote nothing', pg_temp.qty(:ANA, :BOLT) || '/' || pg_temp.qty(:ANA, :OPT), '4/2');
select pg_temp.eq('ledger matches items',
  (select coalesce(sum(delta), 0)::text from public.collection_ledger where user_id = :ANA),
  (select sum(qty)::text from public.collection_items where user_id = :ANA));
set role authenticated;

-- Undo -------------------------------------------------------------------------
select public.collection_apply('[{"card_id":"c1000000-0000-0000-0000-000000000001","finish":"foil","delta":1}]',
  'scan', null, gen_random_uuid()) ->> 'batch_id' as foil_batch \gset
select public.collection_undo(:'foil_batch', gen_random_uuid());
reset role;
select pg_temp.eq('undo reverses the batch', pg_temp.qty(:ANA, :BOLT, 'foil'), '0');
set role authenticated;
select pg_temp.throws('a batch undoes once', format($$select public.collection_undo('%s', gen_random_uuid())$$, :'foil_batch'));

-- Delta sync -------------------------------------------------------------------
select pg_temp.eq('changes from 0 return every live item',
  (select jsonb_array_length(public.collection_changes(0, 5000)->'items')::text), '3');
select (public.collection_changes(0, 5000))->>'next' as cur \gset
select pg_temp.eq('nothing new after the cursor',
  (select jsonb_array_length(public.collection_changes(:'cur'::bigint, 5000)->'items')::text), '0');

-- Isolation: Ben sees none of Ana's collection.
select pg_temp.as_user(:BEN);
select pg_temp.eq('other accounts see no items', (select count(*)::text from public.collection_items), '0');
select pg_temp.eq('other accounts sync nothing',
  (select jsonb_array_length(public.collection_changes(0, 5000)->'items')::text), '0');

-- Trades -----------------------------------------------------------------------
select pg_temp.as_user(:ANA);
select (public.trade_save(null, 'Ben at FNM', null,
  '[{"card_id":"c1000000-0000-0000-0000-000000000001","finish":"nonfoil","condition":"NM","lang":"en","qty":2}]',
  '[{"card_id":"c1000000-0000-0000-0000-000000000002","finish":"nonfoil","condition":"NM","lang":"en","qty":3}]'))->>'id' as trade \gset
select pg_temp.eq('draft listed', (select (public.trades_list(50)->0->>'status')), 'draft');
select public.trade_confirm(:'trade', 'e0000000-0000-0000-0000-0000000000c1') as tc \gset
reset role;
select pg_temp.eq('confirmed trade moves the collection', pg_temp.qty(:ANA, :BOLT) || '/' || pg_temp.qty(:ANA, :OPT), '2/5');
select pg_temp.eq('trade is one batch with source trade',
  (select count(*)::text || ':' || min(source) from public.collection_batches where user_id = :ANA and source = 'trade'), '1:trade');
set role authenticated;
select public.trade_confirm(:'trade', 'e0000000-0000-0000-0000-0000000000c1') as tc2 \gset
reset role;
select pg_temp.eq('confirm retry does not apply twice', pg_temp.qty(:ANA, :BOLT), '2');
set role authenticated;

select (public.trade_save(null, 'Too generous', null,
  '[{"card_id":"c1000000-0000-0000-0000-000000000001","finish":"nonfoil","condition":"NM","lang":"en","qty":9}]', '[]'))->>'id' as big \gset
select pg_temp.throws('cannot give more than you own', format($$select public.trade_confirm('%s', gen_random_uuid())$$, :'big'));
reset role;
select pg_temp.eq('failed trade wrote nothing', pg_temp.qty(:ANA, :BOLT), '2');

-- Lists: a line asking for a finish its printing doesn't come in is saved in one it does (2026-10-22) -----------
-- A foil-only Bolt printing (a Secret Lair). An imported cube listed it without a finish and was refused outright.
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000001', 'sld', '9', 'en', 'rare', '{foil}', 'normal', 'h');
\set SLD '''c1000000-0000-0000-0000-000000000003'''
\set CUBE '''d0000000-0000-0000-0000-0000000000c1'''
create or replace function pg_temp.line(l uuid, c uuid, b text) returns text language sql as
$$ select coalesce((select string_agg(qty || ' ' || finish, ', ' order by finish) from public.card_list_entries
                     where list_id = l and card_id = c and board = b), 'none') $$;
set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_create(:CUBE, 'cube', 'Imported', 'vintage', jsonb_build_array(
  jsonb_build_array(:SLD, 'main', 1), jsonb_build_array(:SLD, 'main', 1, 'foil'),
  jsonb_build_array(:OPT, 'main', 2, 'foil'), jsonb_build_array(:BOLT, 'main', 1, 'etched'))) is not null as created \gset
reset role;
select pg_temp.eq('a list with a finish its printing lacks is saved', :'created', 't');
select pg_temp.eq('foil-only printing listed as non-foil is foil, merged with the foil line', pg_temp.line(:CUBE, :SLD, 'main'), '2 foil');
select pg_temp.eq('non-foil-only printing asked as foil is non-foil', pg_temp.line(:CUBE, :OPT, 'main'), '2 nonfoil');
select pg_temp.eq('etched asked of a non-foil + foil printing is non-foil', pg_temp.line(:CUBE, :BOLT, 'main'), '1 nonfoil');
select pg_temp.eq('the version holds the same lines',
  (select entries::text from public.card_list_versions where list_id = :CUBE and version = 1),
  format('[["%s", "main", 1], ["%s", "main", 2], ["%s", "main", 2, "foil"]]', :BOLT, :OPT, :SLD));
set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_edit(:CUBE, jsonb_build_array(jsonb_build_object('card_id', :SLD, 'board', 'maybe', 'delta', 1))) is not null as edited \gset
reset role;
select pg_temp.eq('an edit adding it without a finish adds it as foil', pg_temp.line(:CUBE, :SLD, 'maybe'), '1 foil');

-- Lists: lines name a language (2026-10-25) --------------------------------------------------------------------
-- A Japanese-only printing of Opt (cards.lang 'ja') is always Japanese, whatever the entry says.
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000002', 'war', '65', 'ja', 'common', '{nonfoil}', 'normal', 'h');
\set OPTJA '''c1000000-0000-0000-0000-000000000004'''
\set DECK '''d0000000-0000-0000-0000-0000000000d1'''
create or replace function pg_temp.langs(l uuid, c uuid, b text) returns text language sql as
$$ select coalesce((select string_agg(qty || ' ' || finish || ' ' || lang, ', ' order by finish, lang) from public.card_list_entries
                     where list_id = l and card_id = c and board = b), 'none') $$;
set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_create(:DECK, 'deck', 'Burn', 'modern', jsonb_build_array(
  jsonb_build_array(:BOLT, 'main', 2), jsonb_build_array(:BOLT, 'main', 2, 'nonfoil', 'ja'),
  jsonb_build_array(:BOLT, 'main', 1, 'nonfoil', 'JA'), jsonb_build_array(:BOLT, 'side', 1, 'foil', 'de'),
  jsonb_build_array(:OPTJA, 'main', 1), jsonb_build_array(:OPTJA, 'main', 1, 'nonfoil', 'fr'))) is not null as created \gset
reset role;
select pg_temp.eq('English and Japanese copies of one printing are two lines', pg_temp.langs(:DECK, :BOLT, 'main'), '2 nonfoil en, 3 nonfoil ja');
select pg_temp.eq('a foil German line keeps finish and language', pg_temp.langs(:DECK, :BOLT, 'side'), '1 foil de');
select pg_temp.eq('a Japanese printing is Japanese, merged into one line', pg_temp.langs(:DECK, :OPTJA, 'main'), '2 nonfoil ja');
select pg_temp.eq('the version writes the language only when it isn''t English',
  (select entries::text from public.card_list_versions where list_id = :DECK and version = 1),
  format('[["%s", "main", 2], ["%s", "main", 3, "nonfoil", "ja"], ["%s", "main", 2, "nonfoil", "ja"], ["%s", "side", 1, "foil", "de"]]',
         :BOLT, :BOLT, :OPTJA, :BOLT));

set role authenticated;
select pg_temp.as_user(:ANA);
-- Change a count by language; an op without lang is English; move a section keeps the language.
select public.list_edit(:DECK, jsonb_build_array(
  jsonb_build_object('card_id', :BOLT, 'board', 'main', 'lang', 'ja', 'delta', -1),
  jsonb_build_object('card_id', :BOLT, 'board', 'main', 'delta', 1),
  jsonb_build_object('card_id', :BOLT, 'finish', 'foil', 'lang', 'de', 'from', 'side', 'to', 'maybe'))) is not null as e1 \gset
reset role;
select pg_temp.eq('delta by language', pg_temp.langs(:DECK, :BOLT, 'main'), '3 nonfoil en, 2 nonfoil ja');
select pg_temp.eq('moving a section keeps the language', pg_temp.langs(:DECK, :BOLT, 'maybe'), '1 foil de');

set role authenticated;
select pg_temp.as_user(:ANA);
-- Change the language of 2 English copies: the line splits and merges into the Japanese one.
select public.list_edit(:DECK, jsonb_build_array(
  jsonb_build_object('card_id', :BOLT, 'board', 'main', 'to_lang', 'ja', 'qty', 2))) is not null as e2 \gset
reset role;
select pg_temp.eq('to_lang moves copies to another language', pg_temp.langs(:DECK, :BOLT, 'main'), '1 nonfoil en, 4 nonfoil ja');

set role authenticated;
select pg_temp.as_user(:ANA);
-- Another printing keeps the line's language unless to_lang says otherwise.
select public.list_edit(:DECK, jsonb_build_array(
  jsonb_build_object('card_id', :BOLT, 'board', 'main', 'lang', 'ja', 'to_card_id', :SLD, 'qty', 1))) is not null as e3 \gset
reset role;
select pg_temp.eq('another printing keeps the language', pg_temp.langs(:DECK, :SLD, 'main'), '1 foil ja');

set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.throws('a language that isn''t one is refused',
  format($$select public.list_edit('%s', '[{"card_id":"%s","board":"main","lang":"j|a","delta":1}]')$$, :DECK, :BOLT), '22023');
select pg_temp.throws('another account can''t edit the list',
  format($$select public.list_edit('%s', '[{"card_id":"%s","board":"main","lang":"ja","delta":1}]')$$, :CUBE, :BOLT))
  from (select pg_temp.as_user(:BEN)) x;
-- Retrying the same qty op is idempotent.
select pg_temp.as_user(:ANA);
select public.list_edit(:DECK, '[{"card_id":"c1000000-0000-0000-0000-000000000001","board":"main","lang":"ja","qty":4}]') is not null as e4 \gset
select public.list_edit(:DECK, '[{"card_id":"c1000000-0000-0000-0000-000000000001","board":"main","lang":"ja","qty":4}]') is not null as e5 \gset
reset role;
select pg_temp.eq('a repeated qty op changes nothing more', pg_temp.langs(:DECK, :BOLT, 'main'), '1 nonfoil en, 4 nonfoil ja');
-- The migration's backfill: a line saved before languages that lists a Japanese printing becomes Japanese.
insert into public.card_list_entries (list_id, card_id, board, qty, finish, lang) values (:DECK, :OPTJA, 'side', 1, 'nonfoil', 'en');
update public.card_list_versions set entries = entries || jsonb_build_array(jsonb_build_array(:OPTJA, 'side', 1))
 where list_id = :DECK and version = (select current_version from public.card_lists where id = :DECK);
select (select seq from public.card_lists where id = :DECK) as seq_before \gset
do $$
declare l public.card_lists;
begin
  for l in select * from public.card_lists where deleted_at is null and id in (
             select e.list_id from public.card_list_entries e join public.cards c on c.id = e.card_id where c.lang <> 'en') loop
    perform t1_private.list_write(l, (select v.entries from public.card_list_versions v
                                       where v.list_id = l.id and v.version = l.current_version), 'Edited', true);
  end loop;
end $$;
select pg_temp.eq('backfill: a Japanese printing''s old line is Japanese', pg_temp.langs(:DECK, :OPTJA, 'side'), '1 nonfoil ja');
select pg_temp.eq('backfill moved the list''s seq', ((select seq from public.card_lists where id = :DECK) > :seq_before)::text, 'true');
