-- Binders, "for trade" and wants (contract/binders-wants-2026-10-17.md).
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''

-- Bolt (nonfoil + foil, two printings), Opt (nonfoil).
insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000002', 'Opt', 'opt', 'normal', 'c1000000-0000-0000-0000-000000000002', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil,foil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000001', 'm11', '149', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'xln', '65', 'en', 'common', '{nonfoil}', 'normal', 'h');
\set BOLT '''c1000000-0000-0000-0000-000000000001'''
\set BOLT2 '''c1000000-0000-0000-0000-000000000003'''
\set OPT '''c1000000-0000-0000-0000-000000000002'''
\set BOLT_O '''c0000000-0000-0000-0000-000000000001'''
\set OPT_O '''c0000000-0000-0000-0000-000000000002'''
\set TRADE '''b0000000-0000-0000-0000-000000000001'''
\set BOX '''b0000000-0000-0000-0000-000000000002'''
\set ALPHA '''b0000000-0000-0000-0000-000000000003'''

-- Copies of one item a binder holds; total copies; items whose binders hold more than they have (must stay 0).
create or replace function pg_temp.bq(b uuid, c uuid, f text default 'nonfoil') returns text language sql as
$$ select coalesce((select qty::text from public.binder_items where binder_id = b and card_id = c and finish = f
                     and condition = 'NM' and lang = 'en'), '0') $$;
create or replace function pg_temp.qty(u uuid, c uuid, f text default 'nonfoil') returns text language sql as
$$ select coalesce((select sum(qty)::text from public.collection_items where user_id = u and card_id = c and finish = f), '0') $$;
create or replace function pg_temp.over() returns text language sql as $$
  select count(*)::text from (select user_id, card_id, finish, condition, lang, sum(qty) a from public.binder_items
                               group by 1, 2, 3, 4, 5) s
    left join public.collection_items i using (user_id, card_id, finish, condition, lang)
   where s.a > coalesce(i.qty, 0) $$;
create or replace function pg_temp.want(u uuid, o uuid, c uuid default null, f text default null) returns text language sql as
$$ select coalesce((select qty::text from public.wants where user_id = u and oracle_id = o
                     and card_id is not distinct from c and finish is not distinct from f), '0') $$;

set role authenticated;
select pg_temp.as_user(:ANA);

-- Binders ----------------------------------------------------------------------
select public.binder_save(:TRADE, 'Trade binder', true) as b1 \gset
select pg_temp.eq('binder created for trade', (:'b1'::jsonb)->>'for_trade', 'true');
select public.binder_save(:BOX, 'Box 3');
select public.binder_save(:ALPHA, 'Alpha');
select pg_temp.eq('creating again with the same id is the same binder',
  (public.binder_save(:TRADE, 'Trade binder', true))->>'seq', (:'b1'::jsonb)->>'seq');
select pg_temp.throws('binder names are unique per account', $$select public.binder_save(gen_random_uuid(), 'box 3')$$, '23505');
select pg_temp.throws('a binder needs a name', $$select public.binder_save(gen_random_uuid(), '  ')$$, '22023');
select pg_temp.eq('rename keeps the flag', (public.binder_save(:ALPHA, 'Alpha binder'))->>'for_trade', 'false');
select pg_temp.eq('renamed back', (public.binder_save(:ALPHA, 'Alpha'))->>'name', 'Alpha');
reset role;
select pg_temp.eq('three binders', (select count(*)::text from public.binders where user_id = :ANA), '3');

-- Clients can't write the tables directly.
set role authenticated;
select pg_temp.throws('no direct insert into binders',
  $$insert into public.binders (id, user_id, name, seq) values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', 'x', 1)$$, '42501');
select pg_temp.throws('no direct update of binder_items', $$update public.binder_items set qty = 99$$, '42501');
select pg_temp.throws('no direct insert into wants',
  $$insert into public.wants (user_id, oracle_id, qty, seq) values ('00000000-0000-0000-0000-0000000000a1', 'c0000000-0000-0000-0000-000000000002', 1, 1)$$, '42501');

-- Adding into a binder ---------------------------------------------------------
select public.collection_apply(jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'delta', 4, 'binder_id', :BOX)),
  'manual', null, 'e0000000-0000-0000-0000-000000000001') as a1 \gset
select pg_temp.eq('apply returns the allocation', jsonb_array_length((:'a1'::jsonb)->'binder_items')::text, '1');
select public.collection_apply(jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'delta', 2)),
  'manual', null, 'e0000000-0000-0000-0000-000000000002');
reset role;
select pg_temp.eq('added copies went into the binder', pg_temp.qty(:ANA, :BOLT) || '/' || pg_temp.bq(:BOX, :BOLT), '6/4');
select pg_temp.eq('allocations within copies (add)', pg_temp.over(), '0');
set role authenticated;
select public.collection_apply(jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'delta', 4, 'binder_id', :BOX)),
  'manual', null, 'e0000000-0000-0000-0000-000000000001') as a1b \gset
select pg_temp.eq('same key replays as a duplicate', (:'a1b'::jsonb)->>'duplicate', 'true');
reset role;
select pg_temp.eq('replay added nothing', pg_temp.qty(:ANA, :BOLT) || '/' || pg_temp.bq(:BOX, :BOLT), '6/4');
set role authenticated;
select pg_temp.throws('a binder goes with deltas, not qty',
  format($$select public.collection_apply('[{"card_id":"%s","qty":3,"binder_id":"%s"}]', 'manual', null, gen_random_uuid())$$,
         'c1000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002'), '22023');
select pg_temp.throws('unknown binder rejected',
  format($$select public.collection_apply('[{"card_id":"%s","delta":1,"binder_id":"%s"}]', 'manual', null, gen_random_uuid())$$,
         'c1000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-0000000000ff'), 'P0002');
select pg_temp.throws('clients cannot use the binder source',
  format($$select public.collection_apply('[{"card_id":"%s","delta":1}]', 'binder', null, gen_random_uuid())$$,
         'c1000000-0000-0000-0000-000000000001'), '22023');

-- Moving -----------------------------------------------------------------------
select public.binder_move(jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'from', null, 'to', :TRADE, 'qty', 2)),
  'e0000000-0000-0000-0000-000000000003') as m1 \gset
reset role;
select pg_temp.eq('moved Unsorted copies into the trade binder',
  pg_temp.qty(:ANA, :BOLT) || '/' || pg_temp.bq(:BOX, :BOLT) || '/' || pg_temp.bq(:TRADE, :BOLT), '6/4/2');
select pg_temp.eq('a move is one batch with source binder, no item change',
  (select source || ':' || changes from public.collection_batches where id = 'e0000000-0000-0000-0000-000000000003'), 'binder:0');
select pg_temp.eq('a move is ledgered', (select count(*)::text from public.binder_ledger
  where batch_id = 'e0000000-0000-0000-0000-000000000003'), '1');
set role authenticated;
select pg_temp.eq('move replays as a duplicate',
  (public.binder_move(jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'from', null, 'to', :TRADE, 'qty', 2)),
    'e0000000-0000-0000-0000-000000000003'))->>'duplicate', 'true');
reset role;
select pg_temp.eq('replayed move moved nothing', pg_temp.bq(:TRADE, :BOLT), '2');
set role authenticated;
select pg_temp.throws('cannot move more than Unsorted holds',
  format($$select public.binder_move('[{"card_id":"%s","from":null,"to":"%s","qty":1}]', gen_random_uuid())$$,
         'c1000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003'), '22023');
select pg_temp.throws('cannot move more than a binder holds',
  format($$select public.binder_move('[{"card_id":"%s","from":"%s","to":null,"qty":5}]', gen_random_uuid())$$,
         'c1000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002'), '22023');
select pg_temp.throws('a move needs two different places',
  format($$select public.binder_move('[{"card_id":"%s","from":null,"to":null,"qty":1}]', gen_random_uuid())$$,
         'c1000000-0000-0000-0000-000000000001'), '22023');
select public.binder_move(jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'from', :BOX, 'to', :ALPHA, 'qty', 1)),
  gen_random_uuid());

-- Wrong account ----------------------------------------------------------------
select pg_temp.as_user(:BEN);
select pg_temp.throws('another account cannot rename my binder', $$select public.binder_save('b0000000-0000-0000-0000-000000000001', 'Mine now')$$, '42501');
select pg_temp.throws('another account cannot delete my binder', $$select public.binder_delete('b0000000-0000-0000-0000-000000000001', gen_random_uuid())$$, '42501');
select pg_temp.throws('another account cannot move into my binder',
  format($$select public.binder_move('[{"card_id":"%s","from":null,"to":"%s","qty":1}]', gen_random_uuid())$$,
         'c1000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001'), 'P0002');
select pg_temp.throws('another account cannot add into my binder',
  format($$select public.collection_apply('[{"card_id":"%s","delta":1,"binder_id":"%s"}]', 'manual', null, gen_random_uuid())$$,
         'c1000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001'), 'P0002');
select pg_temp.throws('another account cannot replay my move key',
  $$select public.binder_move('[{}]', 'e0000000-0000-0000-0000-000000000003')$$, '23505');
select pg_temp.eq('another account sees none of my binders', (select count(*)::text from public.binders), '0');
select pg_temp.eq('another account syncs none of my binders',
  (select (jsonb_array_length(r->'binders') + jsonb_array_length(r->'binder_items'))::text
     from public.library_changes(0, 5000) r), '0');
select pg_temp.as_user(:ANA);

-- Shrinking: Unsorted first, then binders not for trade (by name), then for trade ------------------
-- Now: 6 copies; Alpha 1, Box 3, Trade 2, Unsorted 0.
select public.collection_apply(jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'delta', -2)), 'manual', null, gen_random_uuid());
reset role;
select pg_temp.eq('removal shrinks non-trade binders by name first',
  pg_temp.qty(:ANA, :BOLT) || '/' || pg_temp.bq(:ALPHA, :BOLT) || '/' || pg_temp.bq(:BOX, :BOLT) || '/' || pg_temp.bq(:TRADE, :BOLT), '4/0/2/2');
select pg_temp.eq('allocations within copies (remove)', pg_temp.over(), '0');
set role authenticated;
select public.collection_apply(jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'delta', 1)), 'manual', null, gen_random_uuid());
select public.collection_apply(jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'delta', -1)), 'manual', null, gen_random_uuid());
reset role;
select pg_temp.eq('Unsorted copies go first', pg_temp.qty(:ANA, :BOLT) || '/' || pg_temp.bq(:BOX, :BOLT) || '/' || pg_temp.bq(:TRADE, :BOLT), '4/2/2');
set role authenticated;
select public.collection_apply(jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'delta', -1, 'binder_id', :TRADE)),
  'manual', null, gen_random_uuid());
reset role;
select pg_temp.eq('a named binder gives first', pg_temp.qty(:ANA, :BOLT) || '/' || pg_temp.bq(:BOX, :BOLT) || '/' || pg_temp.bq(:TRADE, :BOLT), '3/2/1');
set role authenticated;
select public.collection_apply(jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'qty', 1)), 'adjust', null,
  'e0000000-0000-0000-0000-000000000004');
reset role;
select pg_temp.eq('setting a lower qty empties non-trade binders before trade ones',
  pg_temp.qty(:ANA, :BOLT) || '/' || pg_temp.bq(:BOX, :BOLT) || '/' || pg_temp.bq(:TRADE, :BOLT), '1/0/1');
select pg_temp.eq('allocations within copies (qty)', pg_temp.over(), '0');

-- Undo puts binder copies back -------------------------------------------------
set role authenticated;
select public.collection_undo('e0000000-0000-0000-0000-000000000004', gen_random_uuid());
reset role;
select pg_temp.eq('undo restores copies and the binder they left',
  pg_temp.qty(:ANA, :BOLT) || '/' || pg_temp.bq(:BOX, :BOLT) || '/' || pg_temp.bq(:TRADE, :BOLT), '3/2/1');
set role authenticated;
select (public.binder_move(jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'from', :BOX, 'to', :TRADE, 'qty', 1)),
  gen_random_uuid()))->>'batch_id' as mv \gset
select public.collection_undo(:'mv', gen_random_uuid());
reset role;
select pg_temp.eq('undo of a move moves them back', pg_temp.bq(:BOX, :BOLT) || '/' || pg_temp.bq(:TRADE, :BOLT), '2/1');
select pg_temp.eq('allocations within copies (undo)', pg_temp.over(), '0');

-- Wants ------------------------------------------------------------------------
set role authenticated;
select public.wants_apply(jsonb_build_array(
  jsonb_build_object('oracle_id', :OPT_O, 'qty', 3, 'max_usd', 0.5),
  jsonb_build_object('card_id', :BOLT, 'finish', 'foil', 'qty', 1)), 'e0000000-0000-0000-0000-000000000005') as w1 \gset
select pg_temp.eq('wants added', jsonb_array_length((:'w1'::jsonb)->'wants')::text, '2');
select pg_temp.eq('wants replay as a duplicate',
  (public.wants_apply(jsonb_build_array(jsonb_build_object('oracle_id', :OPT_O, 'delta', 3)),
    'e0000000-0000-0000-0000-000000000005'))->>'duplicate', 'true');
reset role;
select pg_temp.eq('replayed wants changed nothing', pg_temp.want(:ANA, :OPT_O), '3');
select pg_temp.eq('max price kept', (select max_usd::text from public.wants where user_id = :ANA and oracle_id = :OPT_O), '0.50');
set role authenticated;
select pg_temp.throws('a finish needs a printing', $$select public.wants_apply('[{"oracle_id":"c0000000-0000-0000-0000-000000000002","finish":"foil","qty":1}]', gen_random_uuid())$$, '22023');
select pg_temp.throws('a finish the printing lacks', $$select public.wants_apply('[{"card_id":"c1000000-0000-0000-0000-000000000002","finish":"foil","qty":1}]', gen_random_uuid())$$, '22023');
select pg_temp.throws('unknown card in wants', $$select public.wants_apply('[{"oracle_id":"c0000000-0000-0000-0000-0000000000ff","qty":1}]', gen_random_uuid())$$, '22023');
select pg_temp.throws('wishlist batches are not undone', $$select public.collection_undo('e0000000-0000-0000-0000-000000000005', gen_random_uuid())$$, '22023');
select pg_temp.as_user(:BEN);
select pg_temp.eq('another account sees none of my wants', (select count(*)::text from public.wants), '0');
select pg_temp.throws('another account cannot replay my wants key',
  $$select public.wants_apply('[{"oracle_id":"c0000000-0000-0000-0000-000000000002","qty":1}]', 'e0000000-0000-0000-0000-000000000005')$$, '23505');
select pg_temp.as_user(:ANA);

-- Trades: gives from a binder, gets go into one, wants are met --------------------------------
-- Bolt: 3 copies, Box 2, Trade 1. Give the trade-binder copy; get 2 Opt into Box and a foil Bolt.
select (public.trade_save(null, 'Ben', null,
  jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'finish', 'nonfoil', 'condition', 'NM', 'lang', 'en', 'qty', 1, 'binder_id', :TRADE)),
  jsonb_build_array(jsonb_build_object('card_id', :OPT, 'qty', 2, 'binder_id', :BOX),
                    jsonb_build_object('card_id', :BOLT, 'finish', 'foil', 'qty', 1))))->>'id' as trade \gset
select pg_temp.eq('trade lines keep their binder',
  (select gives->0->>'binder_id' from public.trades where id = :'trade'), 'b0000000-0000-0000-0000-000000000001');
select public.trade_confirm(:'trade', 'e0000000-0000-0000-0000-0000000000c1') as tc \gset
reset role;
select pg_temp.eq('the give came out of the trade binder',
  pg_temp.qty(:ANA, :BOLT) || '/' || pg_temp.bq(:BOX, :BOLT) || '/' || pg_temp.bq(:TRADE, :BOLT), '2/2/0');
select pg_temp.eq('the get went into its binder', pg_temp.qty(:ANA, :OPT) || '/' || pg_temp.bq(:BOX, :OPT), '2/2');
select pg_temp.eq('allocations within copies (trade)', pg_temp.over(), '0');
select pg_temp.eq('the trade met the wants',
  pg_temp.want(:ANA, :OPT_O) || '/' || pg_temp.want(:ANA, :BOLT_O, :BOLT, 'foil'), '1/0');
select pg_temp.eq('confirm returns the wants it changed', jsonb_array_length((:'tc'::jsonb)->'wants')::text, '2');
select pg_temp.eq('wants met in the trade batch', (select count(*)::text from public.want_ledger
  where batch_id = 'e0000000-0000-0000-0000-0000000000c1'), '2');
set role authenticated;
select pg_temp.eq('confirm replays as a duplicate',
  (public.trade_confirm(:'trade', 'e0000000-0000-0000-0000-0000000000c1'))->>'duplicate', 'true');
reset role;
select pg_temp.eq('replayed confirm met no more wants', pg_temp.want(:ANA, :OPT_O), '1');
set role authenticated;
select public.collection_undo('e0000000-0000-0000-0000-0000000000c1', gen_random_uuid());
reset role;
select pg_temp.eq('undoing the trade restores copies, binders and wants',
  pg_temp.qty(:ANA, :BOLT) || '/' || pg_temp.bq(:TRADE, :BOLT) || '/' || pg_temp.qty(:ANA, :OPT) || '/' || pg_temp.bq(:BOX, :OPT)
  || '/' || pg_temp.want(:ANA, :OPT_O) || '/' || pg_temp.want(:ANA, :BOLT_O, :BOLT, 'foil'), '3/1/0/0/3/1');
select pg_temp.eq('allocations within copies (trade undo)', pg_temp.over(), '0');

-- Specific wants are met before any-printing ones.
set role authenticated;
select public.wants_apply(jsonb_build_array(jsonb_build_object('oracle_id', :BOLT_O, 'qty', 2),
                                            jsonb_build_object('card_id', :BOLT2, 'qty', 1)), gen_random_uuid());
select (public.trade_save(null, null, null, '[]'::jsonb,
  jsonb_build_array(jsonb_build_object('card_id', :BOLT2, 'qty', 2))))->>'id' as trade2 \gset
select public.trade_confirm(:'trade2', gen_random_uuid());
reset role;
select pg_temp.eq('exact printing first, then any printing',
  pg_temp.want(:ANA, :BOLT_O, :BOLT2) || '/' || pg_temp.want(:ANA, :BOLT_O), '0/1');

-- A binder deleted since the draft just drops out of the confirm.
set role authenticated;
select public.binder_save('b0000000-0000-0000-0000-000000000009', 'Gone soon');
select (public.trade_save(null, null, null, '[]'::jsonb,
  jsonb_build_array(jsonb_build_object('card_id', :OPT, 'qty', 1, 'binder_id', 'b0000000-0000-0000-0000-000000000009'))))->>'id' as trade3 \gset
select public.binder_delete('b0000000-0000-0000-0000-000000000009', gen_random_uuid());
select pg_temp.eq('confirm with a deleted binder still works', (public.trade_confirm(:'trade3', gen_random_uuid()))->'trade'->>'status', 'confirmed');

-- Deleting a binder ------------------------------------------------------------
select (public.binder_delete(:BOX, 'e0000000-0000-0000-0000-000000000006'))->>'duplicate' as d1 \gset
reset role;
select pg_temp.eq('deleting returns copies to Unsorted', pg_temp.qty(:ANA, :BOLT) || '/' || pg_temp.bq(:BOX, :BOLT), '3/0');
select pg_temp.eq('deleting is ledgered', (select count(*)::text from public.binder_ledger
  where batch_id = 'e0000000-0000-0000-0000-000000000006'), '1');
set role authenticated;
select pg_temp.eq('deleting again is a duplicate', (public.binder_delete(:BOX, gen_random_uuid()))->>'duplicate', 'true');
select pg_temp.throws('a deleted binder cannot be renamed', $$select public.binder_save('b0000000-0000-0000-0000-000000000002', 'Back')$$, 'P0002');
select pg_temp.throws('deleting a binder is not undone', $$select public.collection_undo('e0000000-0000-0000-0000-000000000006', gen_random_uuid())$$, '22023');
select pg_temp.eq('a deleted name can be used again', (public.binder_save(gen_random_uuid(), 'Box 3'))->>'name', 'Box 3');

-- Sync -------------------------------------------------------------------------
select public.library_changes(0, 5000) as lc \gset
select pg_temp.eq('sync from 0 carries binders, deleted ones flagged',
  (select count(*)::text || ':' || count(*) filter (where (b->>'deleted')::boolean)
     from jsonb_array_elements((:'lc'::jsonb)->'binders') b), '5:2');
select pg_temp.eq('sync carries wants', (select count(*)::text from jsonb_array_elements((:'lc'::jsonb)->'wants') w
  where (w->>3)::int > 0), '3');
select pg_temp.eq('nothing new after the cursor',
  (select (jsonb_array_length(r->'binders') + jsonb_array_length(r->'binder_items') + jsonb_array_length(r->'wants'))::text
     from public.library_changes(((:'lc'::jsonb)->>'next')::bigint, 5000) r), '0');
select pg_temp.eq('pages by seq',
  (select (r->>'more') || ':' || (jsonb_array_length(r->'binder_items') + jsonb_array_length(r->'wants'))
     from public.library_changes(0, 2) r), 'true:2');
-- Sync from a cursor behind the tombstone horizon resyncs.
reset role;
update public.library_summary set extras_floor = 999999999 where user_id = :ANA;
set role authenticated;
select pg_temp.eq('behind the floor resyncs', (public.library_changes(5, 100))->>'resync', 'true');
reset role;
update public.library_summary set extras_floor = 0 where user_id = :ANA;

-- The invariant under a long run of mixed writes -----------------------------------------------
set role authenticated;
select public.binder_save('b0000000-0000-0000-0000-000000000011', 'Red', false);
select public.binder_save('b0000000-0000-0000-0000-000000000012', 'Trades two', true);
reset role;   -- still acting as Ana (auth.uid()); as the owner so the loop can age batches past the rate limit
do $$
declare
  bs uuid[] := array['b0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000011',
                     'b0000000-0000-0000-0000-000000000012']::uuid[];
  cs uuid[] := array['c1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000002',
                     'c1000000-0000-0000-0000-000000000003']::uuid[];
  i int; c uuid; b uuid; d int; have int; held int; r double precision; over int;
begin
  perform setseed(0.17);
  for i in 1..300 loop
    c := cs[1 + floor(random() * 3)::int];
    b := bs[1 + floor(random() * 3)::int];
    r := random();
    select coalesce(sum(qty), 0) into have from public.collection_items where card_id = c and finish = 'nonfoil' and condition = 'NM' and lang = 'en';
    if r < 0.3 then
      perform public.collection_apply(jsonb_build_array(jsonb_build_object('card_id', c, 'delta', 1 + floor(random() * 3)::int,
                'binder_id', case when random() < 0.6 then b end)), 'manual', null, gen_random_uuid());
    elsif r < 0.55 and have > 0 then
      perform public.collection_apply(jsonb_build_array(jsonb_build_object('card_id', c, 'delta', -(1 + floor(random() * have)::int),
                'binder_id', case when random() < 0.5 then b end)), 'manual', null, gen_random_uuid());
    elsif r < 0.65 then
      perform public.collection_apply(jsonb_build_array(jsonb_build_object('card_id', c, 'qty', floor(random() * 5)::int)),
                'adjust', null, gen_random_uuid());
    elsif r < 0.9 then
      select coalesce(sum(qty), 0) into held from public.binder_items where card_id = c and finish = 'nonfoil' and binder_id = b;
      if held > 0 and random() < 0.5 then
        perform public.binder_move(jsonb_build_array(jsonb_build_object('card_id', c, 'from', b, 'to',
                  case when random() < 0.5 then null else bs[1 + floor(random() * 3)::int] end, 'qty', 1)), gen_random_uuid());
      elsif have - (select coalesce(sum(qty), 0) from public.binder_items where card_id = c and finish = 'nonfoil') > 0 then
        perform public.binder_move(jsonb_build_array(jsonb_build_object('card_id', c, 'from', null, 'to', b, 'qty', 1)), gen_random_uuid());
      end if;
    else
      begin
        perform public.collection_undo((select id from public.collection_batches
          where source in ('manual', 'adjust', 'binder') and undone_by is null order by created_at desc, random() limit 1), gen_random_uuid());
      exception when others then null;   -- an undo whose copies are gone since is refused; that's fine here
      end;
    end if;
    select count(*) into over from (select card_id, finish, condition, lang, sum(qty) a from public.binder_items
                                     group by 1, 2, 3, 4) s
      left join public.collection_items it using (card_id, finish, condition, lang)
     where s.a > coalesce(it.qty, 0);
    if over > 0 then raise exception 'FAIL invariant broken after step %', i; end if;
    -- Stay under 120 batches a minute.
    if i % 100 = 0 then
      update public.collection_batches set created_at = created_at - interval '2 minutes';
    end if;
  end loop;
end $$;
reset role;
select pg_temp.eq('allocations within copies after 300 mixed writes', pg_temp.over(), '0');
select pg_temp.eq('the run moved, shrank and undid allocations',
  (select (count(*) > 150 and count(distinct b.source) >= 4)::text from public.binder_ledger l
     join public.collection_batches b on b.id = l.batch_id where l.user_id = :ANA), 'true');
select pg_temp.eq('binder ledger matches allocations',
  (select coalesce(sum(delta), 0)::text from public.binder_ledger where user_id = :ANA),
  (select coalesce(sum(qty), 0)::text from public.binder_items where user_id = :ANA));

-- Account deletion -------------------------------------------------------------
set role authenticated;
select public.delete_account();
reset role;
select pg_temp.eq('deletion removes binders, allocations and wants',
  (select count(*)::text from public.binders where user_id = :ANA) || (select count(*)::text from public.binder_items where user_id = :ANA)
  || (select count(*)::text from public.wants where user_id = :ANA) || (select count(*)::text from public.binder_ledger where user_id = :ANA), '0000');
