-- A friend's new for-trade copies meet your wants (contract/follows-2026-10-25.md § Trade wants).
\ir _helpers.sql

-- Ana trades; Ben is her friend; Cal is a stranger who wants the same cards.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com', '{"full_name": "Cal Reyes"}');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''
\set CAL '''00000000-0000-0000-0000-0000000000c1'''

insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000002', 'Opt', 'opt', 'normal', 'c1000000-0000-0000-0000-000000000002', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000003', 'Counterspell', 'counterspell', 'normal', 'c1000000-0000-0000-0000-000000000003', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil,foil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'xln', '65', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000003', 'mh2', '267', 'en', 'common', '{nonfoil}', 'normal', 'h');
insert into public.card_prices (card_id, usd) values ('c1000000-0000-0000-0000-000000000001', 2.00), ('c1000000-0000-0000-0000-000000000003', 1.50);
\set BOLT '''c1000000-0000-0000-0000-000000000001'''
\set OPT '''c1000000-0000-0000-0000-000000000002'''
\set CS '''c1000000-0000-0000-0000-000000000003'''
\set BOLT_O '''c0000000-0000-0000-0000-000000000001'''
\set OPT_O '''c0000000-0000-0000-0000-000000000002'''
\set CS_O '''c0000000-0000-0000-0000-000000000003'''
\set TRADES '''b1000000-0000-0000-0000-000000000001'''
\set BOX '''b1000000-0000-0000-0000-000000000002'''

-- Due now: as if the last change was 31 minutes ago.
create or replace function pg_temp.settle() returns integer language sql as $$
  update t1_private.trade_adds set last_at = last_at - interval '31 minutes';
  select t1_private.trade_want_digest();
$$;
create or replace function pg_temp.pushes() returns text language sql as $$
  select coalesce(string_agg(right(msg->'user_ids'->>0, 2) || ':' || (msg->'data'->>'n') || ':' || (msg->'data'->'names')::text, ',' order by msg_id), '')
    from pgmq.messages where msg->>'kind' = 'trade.wants';
$$;
create or replace function pg_temp.add(card uuid, n integer, binder uuid, cond text default 'NM') returns void language sql as $$
  select public.collection_apply(jsonb_build_array(jsonb_build_object('card_id', card, 'delta', n, 'binder_id', binder, 'condition', cond)),
                                 'manual', null, gen_random_uuid()) is not null and true;
  select null::void;
$$;

set role authenticated;
select pg_temp.as_user(:BEN);
select public.friend_request(:ANA);
select public.wants_apply(jsonb_build_array(
  jsonb_build_object('oracle_id', :OPT_O, 'qty', 2),
  jsonb_build_object('oracle_id', :BOLT_O, 'qty', 1, 'max_usd', 1.00),
  jsonb_build_object('oracle_id', :CS_O, 'qty', 1, 'max_usd', 1.00)), gen_random_uuid());
select pg_temp.as_user(:CAL);
select public.wants_apply(jsonb_build_array(jsonb_build_object('oracle_id', :OPT_O, 'qty', 1)), gen_random_uuid());
select pg_temp.as_user(:ANA);
select public.friend_respond(:BEN, true);
select public.sharing_set('{"for_trade": "friends"}');
select public.binder_save(:TRADES, 'Trades', true);
select public.binder_save(:BOX, 'Box', false);

-- New copies in a trade binder --------------------------------------------------------------------------------
select pg_temp.add(:OPT, 3, :TRADES);
select pg_temp.add(:BOLT, 1, :TRADES);
select pg_temp.add(:CS, 1, :TRADES, 'HP');
select pg_temp.add(:OPT, 2, :BOX);
reset role;
select pg_temp.eq('only trade binders count', (select string_agg(qty::text, ',' order by card_id) from t1_private.trade_adds), '1,3,1');
select pg_temp.eq('nothing while she''s still adding', t1_private.trade_want_digest()::text, '0');
select pg_temp.eq('quiet: one push', pg_temp.settle()::text, '1');
select pg_temp.eq('to Ben only: Opt, and Counterspell at HP is under his max; Bolt at NM is over it',
  pg_temp.pushes(), 'b1:2:["Counterspell", "Opt"]');
select pg_temp.eq('names the owner and opens her match', (select (msg->'data'->>'owner_name') || '|' || (msg->'data'->>'user_id')
  from pgmq.messages where msg->>'kind' = 'trade.wants'), 'Ana Lind|00000000-0000-0000-0000-0000000000a1');
select pg_temp.eq('the adds are used up', (select count(*)::text from t1_private.trade_adds), '0');

-- Cancelled adds, moves, cooldown ----------------------------------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.add(:OPT, 1, :TRADES);
select pg_temp.add(:OPT, -1, :TRADES);
reset role;
select pg_temp.eq('an add taken back sends nothing', pg_temp.settle()::text || '|' || (select count(*)::text from pgmq.messages where msg->>'kind' = 'trade.wants'), '0|1');
delete from t1_private.trade_want_notices;
set role authenticated;
select pg_temp.as_user(:ANA);
select public.binder_save('b1000000-0000-0000-0000-000000000003', 'More trades', true);
select public.binder_move(jsonb_build_array(jsonb_build_object('card_id', :OPT, 'finish', 'nonfoil', 'condition', 'NM', 'lang', 'en',
  'from', :TRADES, 'to', 'b1000000-0000-0000-0000-000000000003', 'qty', 2)), gen_random_uuid());
reset role;
select pg_temp.eq('moving between trade binders is not new', pg_temp.settle()::text, '0');
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.add(:OPT, 1, :TRADES);
reset role;
select pg_temp.eq('a new copy pushes again', pg_temp.settle()::text, '1');
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.add(:OPT, 1, :TRADES);
reset role;
select pg_temp.eq('but only once in 12 hours', pg_temp.settle()::text, '0');
select pg_temp.eq('and its adds are used up', (select count(*)::text from t1_private.trade_adds), '0');

-- Who it reaches ---------------------------------------------------------------------------------------------------
delete from t1_private.trade_want_notices;
set role authenticated;
select pg_temp.as_user(:ANA);
select public.sharing_set('{"for_trade": "private"}');
select pg_temp.add(:OPT, 1, :TRADES);
reset role;
select pg_temp.eq('For trade private: nobody', pg_temp.settle()::text, '0');
set role authenticated;
select pg_temp.as_user(:ANA);
select public.sharing_set('{"for_trade": "friends"}');
select public.user_block(:BEN, true);
select pg_temp.add(:OPT, 1, :TRADES);
reset role;
select pg_temp.eq('blocked: not friends any more, nothing', pg_temp.settle()::text, '0');
select pg_temp.add(:OPT, 1, :TRADES);
update public.profiles set deleted_at = now() where id = :ANA;
select pg_temp.eq('a deleted account''s waiting adds go', (select count(*)::text from t1_private.trade_adds), '0');
