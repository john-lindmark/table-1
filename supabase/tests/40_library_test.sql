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
