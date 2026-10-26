-- Want prices: daily history, the want list's trend, and price-drop pushes (contract/want-prices-2026-10-26.md).
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''

insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000002', 'Opt', 'opt', 'normal', 'c1000000-0000-0000-0000-000000000002', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000003', 'Counterspell', 'counterspell', 'normal', 'c1000000-0000-0000-0000-000000000003', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000004', 'Ponder', 'ponder', 'normal', 'c1000000-0000-0000-0000-000000000005', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil,foil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000011', 'c0000000-0000-0000-0000-000000000001', '2x2', '117', 'en', 'common', '{nonfoil,foil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000012', 'c0000000-0000-0000-0000-000000000001', '4bb', '146', 'ja', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'xln', '65', 'en', 'common', '{nonfoil,foil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000003', 'mh2', '267', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000005', 'c0000000-0000-0000-0000-000000000004', 'm12', '73', 'en', 'common', '{nonfoil}', 'normal', 'h');
\set BOLT '''c1000000-0000-0000-0000-000000000001'''
\set BOLT2 '''c1000000-0000-0000-0000-000000000011'''
\set BOLTJA '''c1000000-0000-0000-0000-000000000012'''
\set OPT '''c1000000-0000-0000-0000-000000000002'''
\set CS '''c1000000-0000-0000-0000-000000000003'''
\set PONDER '''c1000000-0000-0000-0000-000000000005'''
\set BOLT_O '''c0000000-0000-0000-0000-000000000001'''
\set OPT_O '''c0000000-0000-0000-0000-000000000002'''
\set CS_O '''c0000000-0000-0000-0000-000000000003'''
\set PONDER_O '''c0000000-0000-0000-0000-000000000004'''

insert into public.card_prices (card_id, usd, usd_foil) values
  (:BOLT, 2.00, 5.00), (:BOLT2, 3.00, 1.80), (:BOLTJA, 0.50, null), (:OPT, 0.20, 2.00), (:CS, 10.00, null), (:PONDER, 2.00, null);

create or replace function pg_temp.price(card uuid, usd numeric, foil numeric default null) returns void language sql as $$
  update public.card_prices set usd = $2, usd_foil = coalesce($3, usd_foil) where card_id = $1;
$$;
-- Ten days of history, today − 10 … today − 1, with Counterspell at $10 and Ponder at $2 throughout.
create or replace function pg_temp.history() returns void language plpgsql as $$
begin
  for i in reverse 10..1 loop perform t1_private.price_days_take(current_date - i); end loop;
end $$;
create or replace function pg_temp.pushes() returns text language sql as $$
  select coalesce(string_agg(right(msg->'user_ids'->>0, 2) || ':' || (msg->'data'->>'n') || ':' || (msg->'data'->'names')::text
                             || ':' || (msg->'data'->>'reason'), ',' order by msg_id), '')
    from pgmq.messages where msg->>'kind' = 'want.price';
$$;
create or replace function pg_temp.clear() returns void language sql as $$
  delete from pgmq.messages where msg->>'kind' = 'want.price';
$$;

set role authenticated;
select pg_temp.as_user(null);
select pg_temp.throws('signed out: refused', $$select public.wants_prices()$$, '28000');
select pg_temp.as_user(:BEN);
select public.wants_apply(jsonb_build_array(
  jsonb_build_object('oracle_id', :BOLT_O, 'qty', 4, 'max_usd', 1.50),
  jsonb_build_object('card_id', :OPT, 'finish', 'foil', 'qty', 1),
  jsonb_build_object('oracle_id', :CS_O, 'qty', 1),
  jsonb_build_object('oracle_id', :PONDER_O, 'qty', 1)), gen_random_uuid());
select pg_temp.eq('no history yet: now only', (select (public.wants_prices()->'items'->0)::text),
  '{"now": 1.80, "then": null, "avg30": null, "finish": null, "card_id": null, "oracle_id": "c0000000-0000-0000-0000-000000000001", "then_days": null, "now_finish": "foil", "now_card_id": "c1000000-0000-0000-0000-000000000011"}');
select pg_temp.eq('alerts start on', (public.wants_prices()->>'alerts'), 'true');
reset role;

-- History -----------------------------------------------------------------------------------------------------------
select pg_temp.history();
select pg_temp.eq('wanted cards only, every printing', (select count(distinct card_id)::text from t1_private.price_days), '6');
select t1_private.price_days_take(current_date - 1);
select pg_temp.eq('same day again: no duplicates', (select count(*)::text from t1_private.price_days where day = current_date - 1), '6');
select pg_temp.eq('120 days kept', (select t1_private.price_days_take(current_date - 1) is not null
  and not exists (select 1 from t1_private.price_days where day < current_date - 121))::text, 'true');

select pg_temp.price(:CS, 8.00);
select pg_temp.price(:BOLT2, 3.00, 1.40);
select pg_temp.price(:BOLTJA, 0.10);
select pg_temp.price(:OPT, 0.20, 2.10);
select pg_temp.price(:PONDER, 1.50);

set role authenticated;
select pg_temp.as_user(:BEN);
select pg_temp.eq('trend: now vs 7 days ago and the 30-day average',
  (select string_agg(concat_ws('|', i->>'oracle_id', i->>'card_id', i->>'finish', i->>'now', i->>'then', i->>'then_days', i->>'avg30'), ' ; ')
     from jsonb_array_elements(public.wants_prices()->'items') i),
  'c0000000-0000-0000-0000-000000000001|1.40|1.80|7|1.80 ; '
  'c0000000-0000-0000-0000-000000000002|c1000000-0000-0000-0000-000000000002|foil|2.10|2.00|7|2.00 ; '
  'c0000000-0000-0000-0000-000000000003|8.00|10.00|7|10.00 ; '
  'c0000000-0000-0000-0000-000000000004|1.50|2.00|7|2.00');
select pg_temp.eq('any printing: the cheapest English printing and finish (the Japanese one is left out)',
  (select (i->>'now_card_id') || ':' || (i->>'now_finish') from jsonb_array_elements(public.wants_prices()->'items') i
    where i->>'oracle_id' = 'c0000000-0000-0000-0000-000000000001'), 'c1000000-0000-0000-0000-000000000011:foil');
select pg_temp.as_user(:ANA);
select pg_temp.eq('only your own wants', (public.wants_prices()->'items')::text, '[]');
reset role;

-- Pushes ------------------------------------------------------------------------------------------------------------
select pg_temp.eq('one push for Ben', t1_private.want_price_digest()::text, '1');
select pg_temp.eq('Bolt fell under his max, Counterspell 20% ($2) under its average; Ponder is 25% but only 50 cents; Opt went up',
  pg_temp.pushes(), 'b1:2:["Lightning Bolt", "Counterspell"]:under_max');
select pg_temp.eq('the first names the card, price and max',
  (select (msg->'data'->>'name') || '|' || (msg->'data'->>'price') || '|' || (msg->'data'->>'max') from pgmq.messages where msg->>'kind' = 'want.price'),
  'Lightning Bolt|1.40|1.50');
select pg_temp.clear();
select pg_temp.eq('the same day again: nothing', t1_private.want_price_digest()::text, '0');

-- Still under the max: no repeat. Back over, then under again: once more.
select pg_temp.price(:BOLT2, 3.00, 1.60);
select pg_temp.eq('over the max: re-armed, no push', t1_private.want_price_digest()::text || pg_temp.pushes(), '0');
select pg_temp.price(:BOLT2, 3.00, 1.45);
select pg_temp.eq('under again: pushes', t1_private.want_price_digest()::text || pg_temp.pushes(), '1b1:1:["Lightning Bolt"]:under_max');
select pg_temp.clear();

-- Drops: a week's cooldown, then only 5% under the last pushed price.
update t1_private.want_price_alerts set sent_at = sent_at - interval '8 days';
select pg_temp.eq('after the cooldown, the same price: nothing', t1_private.want_price_digest()::text, '0');
select pg_temp.price(:CS, 7.50);
select pg_temp.eq('5% under the last push: pushes', t1_private.want_price_digest()::text || pg_temp.pushes(), '1b1:1:["Counterspell"]:drop');
select pg_temp.eq('pct against the average', (select msg->'data'->>'pct' from pgmq.messages where msg->>'kind' = 'want.price'), '25');
select pg_temp.clear();
select pg_temp.price(:CS, 6.00);
select pg_temp.eq('within the week: nothing', t1_private.want_price_digest()::text, '0');

-- Off and on ------------------------------------------------------------------------------------------------------------
update t1_private.want_price_alerts set sent_at = sent_at - interval '8 days';
set role authenticated;
select pg_temp.as_user(:BEN);
select pg_temp.eq('off', (public.want_alerts_set(false))::text, '{"alerts": false}');
select public.want_alerts_set(false);
select pg_temp.eq('wants_prices says so', public.wants_prices()->>'alerts', 'false');
reset role;
select pg_temp.eq('muted once, audited once', (select array_to_string(muted_kinds, ',') from public.notification_prefs where user_id = :BEN)
  || '|' || (select count(*) from public.account_audit where actor = :BEN and action = 'want_alerts.set'), 'want.price|1');
select pg_temp.eq('off: no push', t1_private.want_price_digest()::text, '0');
set role authenticated;
select pg_temp.as_user(:BEN);
select public.want_alerts_set(true);
select pg_temp.throws('p_on is required', $$select public.want_alerts_set(null)$$, '22023');
reset role;
select pg_temp.eq('on again', (select array_to_string(muted_kinds, ',') from public.notification_prefs where user_id = :BEN), '');
select pg_temp.eq('on: the drop pushes', t1_private.want_price_digest()::text || pg_temp.pushes(), '1b1:1:["Counterspell"]:drop');
select pg_temp.clear();

-- Demo and deleted accounts get nothing ----------------------------------------------------------------------------------
update t1_private.want_price_alerts set sent_at = sent_at - interval '40 days', price = null where user_id = :BEN;
update public.profiles set is_demo = true where id = :BEN;
select pg_temp.eq('demo: nothing', t1_private.want_price_digest()::text, '0');
update public.profiles set is_demo = false, deleted_at = now() where id = :BEN;
select pg_temp.eq('deleted: nothing, and forgotten', t1_private.want_price_digest()::text
  || (select count(*) from t1_private.want_price_alerts where user_id = :BEN), '00');

set role anon;
select pg_temp.throws('anon cannot read prices', $$select public.wants_prices()$$, '42501');
select pg_temp.throws('anon cannot run the digest', $$select t1_private.want_price_digest()$$, '42501');
reset role;
