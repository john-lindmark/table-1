-- Library RPC timings on a catalog the size of live (35k Oracle cards, 105k printings) and a large collection.
-- Run with `T1_PERF=1 supabase/tests/run.sh perf_`. Budgets are ~5x what a local Postgres 17 measured on
-- 2026-10-16 (live Supabase runs about 5x slower than local: a pack window is ~90 ms here, ~0.5 s there), so a missing index or a plan that turns sequential fails here before it reaches the 8 s
-- statement timeout on Supabase. catalog_pack_part must stay well under 8 s per 10k-card window (PACK_WINDOW).
\ir _helpers.sql
set client_min_messages = notice;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000f1', 'big@example.com');
\set BIG '''00000000-0000-0000-0000-0000000000f1'''

-- Seed: deterministic names built from word lists, so trigram search has realistic spread.
create temp table w1 as select unnest(array['Lightning','Shadow','Ancient','Crimson','Silver','Storm','Grave','Ember',
  'Frost','Iron','Verdant','Hollow','Radiant','Savage','Mystic','Brazen','Gilded','Feral','Arcane','Primal']) w, generate_series(0, 19) i;
create temp table w2 as select unnest(array['Bolt','Dragon','Knight','Sphinx','Growth','Ritual','Angel','Golem','Wurm',
  'Counsel','Strike','Ward','Herald','Oracle','Tyrant','Pact','Charm','Titan','Shade','Lotus']) w, generate_series(0, 19) i;

insert into public.card_oracles (oracle_id, name, name_norm, layout, type_line, legalities, source_card_id, source_rank, content_hash)
select md5('o' || g)::uuid,
       a.w || ' ' || b.w || ' ' || g, lower(a.w || ' ' || b.w || ' ' || g), 'normal', 'Creature — Test',
       '{"modern":"legal","legacy":"legal"}', md5('c' || g || '-0')::uuid, 'a', 'h'
  from generate_series(1, 35000) g
  join w1 a on a.i = g % 20
  join w2 b on b.i = (g / 20) % 20;
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash, released_at)
select md5('c' || g || '-' || k)::uuid, md5('o' || g)::uuid, 's' || (g % 300), g::text || chr(97 + k), 'en', 'common',
       '{nonfoil,foil}', 'normal', 'h', date '2000-01-01' + (g % 9000)
  from generate_series(1, 35000) g, generate_series(0, 2) k;
-- Every card makes some mana; one in eight makes two tokens (O lines resolve token printings to pack indexes).
update public.card_oracles o
   set produced_mana = substr('WUBRGC', 1 + abs(hashtext(o.oracle_id::text)) % 6, 1),
       token_card_ids = case when abs(hashtext(o.name)) % 8 = 0
                             then array[md5('c' || (1 + abs(hashtext(o.name)) % 35000) || '-0')::uuid,
                                        md5('c' || (1 + abs(hashtext(o.name_norm || 'x')) % 35000) || '-1')::uuid]
                             else '{}' end;
insert into public.card_names (name_norm, oracle_id, is_face)
select name_norm, oracle_id, false from public.card_oracles on conflict do nothing;
insert into public.card_prices (card_id, usd, usd_foil, eur, updated_at)
select id, (abs(hashtext(id::text)) % 5000) / 100.0, null, null, now() from public.cards;
analyze;

-- The big account owns 5,000 printings.
set role authenticated;
select pg_temp.as_user(:BIG);
do $$
declare i int;
begin
  for i in 0..9 loop
    perform public.collection_apply(
      (select jsonb_agg(jsonb_build_object('card_id', md5('c' || g || '-0'), 'delta', 1 + g % 4))
         from generate_series(i * 500 + 1, i * 500 + 500) g), 'import', null, gen_random_uuid());
  end loop;
end $$;
reset role;
select pg_temp.eq('seeded 5000 printings', (select count(*)::text from public.collection_items where user_id = :BIG), '5000');

set role authenticated;
select pg_temp.as_user(:BIG);
select pg_temp.ms('search_cards prefix "lig"', $$select public.search_cards('lig', 20)$$, 100);
select pg_temp.ms('search_cards two words', $$select public.search_cards('storm dragon', 20)$$, 100);
select pg_temp.ms('search_cards typo "ligtning bolt"', $$select public.search_cards('ligtning bolt', 20)$$, 120);
select pg_temp.ms('card_printings', $$select public.card_printings(md5('o1')::uuid)$$, 10);
select pg_temp.ms('card_prices_get 500 ids',
  $$select public.card_prices_get(array(select md5('c' || g || '-0')::uuid from generate_series(1, 500) g))$$, 10);
select pg_temp.ms('collection_changes first page (5000)', $$select public.collection_changes(0, 5000)$$, 30);
select pg_temp.ms('library_summary_get', $$select public.library_summary_get()$$, 5);
select pg_temp.ms('collection_apply 500 ops',
  $$select public.collection_apply((select jsonb_agg(jsonb_build_object('card_id', md5('c' || g || '-1'), 'delta', 1))
      from generate_series(20001, 20500) g), 'scan', null, gen_random_uuid())$$, 300, 1);
reset role;

select pg_temp.ms('catalog_pack_part oracles, 10k window', $$select length(public.catalog_pack_part(0, 0, 10000))$$, 200, 1);
select pg_temp.ms('catalog_pack_part printings, 10k window', $$select length(public.catalog_pack_part(1, 0, 10000))$$, 500, 1);

-- Binders (contract/binders-wants-2026-10-17.md): 4,000 of the 5,000 printings sorted into 20 binders, plus 500 wants.
set role authenticated;
select pg_temp.as_user(:BIG);
do $$
declare i int;
begin
  for i in 1..20 loop
    perform public.binder_save(md5('binder' || i)::uuid, 'Binder ' || i, i <= 2);
  end loop;
  for i in 0..7 loop
    perform public.binder_move(
      (select jsonb_agg(jsonb_build_object('card_id', md5('c' || g || '-0'), 'from', null,
                                           'to', md5('binder' || (1 + g % 20))::uuid, 'qty', 1))
         from generate_series(i * 500 + 1, i * 500 + 500) g), gen_random_uuid());
  end loop;
  perform public.wants_apply((select jsonb_agg(jsonb_build_object('oracle_id', md5('o' || g)::uuid, 'qty', 1 + g % 3))
                                from generate_series(30001, 30500) g), gen_random_uuid());
end $$;
reset role;
select pg_temp.eq('seeded 4000 allocations', (select count(*)::text from public.binder_items where user_id = :BIG and qty > 0), '4000');
set role authenticated;
select pg_temp.as_user(:BIG);
select pg_temp.ms('library_changes first page (4500 rows)', $$select public.library_changes(0, 5000)$$, 40);
select pg_temp.ms('library_changes nothing new', $$select public.library_changes(1000000000, 5000)$$, 5);
select pg_temp.ms('binder_move 500 moves',
  $$select public.binder_move((select jsonb_agg(jsonb_build_object('card_id', md5('c' || g || '-0'),
      'from', md5('binder' || (1 + g % 20))::uuid, 'to', md5('binder' || (1 + (g + 1) % 20))::uuid, 'qty', 1))
      from generate_series(1, 500) g), gen_random_uuid())$$, 300, 1);
select pg_temp.ms('collection_apply 500 removals that shrink binders',
  $$select public.collection_apply((select jsonb_agg(jsonb_build_object('card_id', md5('c' || g || '-0'), 'delta', -1))
      from generate_series(501, 1000) g), 'manual', null, gen_random_uuid())$$, 300, 1);
-- Share links (contract/share-links-2026-10-23.md): the whole collection and the for-trade binders, signed out.
select public.share_link_create('all_cards')->>'token' as all_tok \gset
select public.share_link_create('for_trade')->>'token' as trade_tok \gset
set role anon;
select pg_temp.as_user(null);
select pg_temp.ms('shared_view all cards', format('select public.shared_view(%L)', :'all_tok'), 10);
select pg_temp.ms('shared_cards all cards first page (5000)', format('select public.shared_cards(%L, 0, 5000)', :'all_tok'), 60);
select pg_temp.ms('shared_cards for trade', format('select public.shared_cards(%L, 0, 5000)', :'trade_tok'), 40);
set role authenticated;
select pg_temp.as_user(:BIG);
reset role;
select pg_temp.eq('allocations within copies after the perf writes',
  (select count(*)::text from (select card_id, finish, condition, lang, sum(qty) a from public.binder_items
                                where user_id = :BIG group by 1, 2, 3, 4) s
     left join public.collection_items i on i.user_id = :BIG and i.card_id = s.card_id and i.finish = s.finish
                                       and i.condition = s.condition and i.lang = s.lang
    where s.a > coalesce(i.qty, 0)), '0');

-- Trade matches (contract/friends-sharing-2026-10-18.md): 200 friends, each with a for-trade binder of 500 printings
-- and 200 wants spread over the catalog, shared with friends; one of them a big trader (5,000 for trade, 2,000 wants
-- overlapping the big account's). The big account wants 500 and has 400 copies in for-trade binders.
insert into auth.users (id, email)
select md5('friend' || i)::uuid, 'f' || i || '@example.com' from generate_series(1, 200) i;
insert into public.friendships (user_lo, user_hi, requested_by, status)
select least(:BIG::uuid, md5('friend' || i)::uuid), greatest(:BIG::uuid, md5('friend' || i)::uuid), :BIG, 'accepted'
  from generate_series(1, 200) i;
insert into public.share_settings (user_id, for_trade, wants)
select md5('friend' || i)::uuid, 'friends', 'friends' from generate_series(1, 200) i;
insert into public.binders (id, user_id, name, for_trade, seq)
select md5('fbinder' || i)::uuid, md5('friend' || i)::uuid, 'Trade', true, nextval('public.collection_seq')
  from generate_series(1, 200) i;
create temp table fcopies as
select distinct on (u, g) md5('friend' || i)::uuid u, md5('fbinder' || i)::uuid b, g, 1 + (i + g) % 3 q
  from (select i, 1 + (i::bigint * 7919 + k::bigint * 104729) % 35000 g from generate_series(2, 200) i, generate_series(1, 500) k
        union all
        select 1, 29001 + k from generate_series(0, 4999) k) s;
insert into public.collection_items (user_id, card_id, finish, condition, lang, qty, seq)
select u, md5('c' || g || '-0')::uuid, 'nonfoil', 'NM', 'en', q, nextval('public.collection_seq') from fcopies;
insert into public.binder_items (user_id, binder_id, card_id, finish, condition, lang, qty, seq)
select u, b, md5('c' || g || '-0')::uuid, 'nonfoil', 'NM', 'en', q, nextval('public.collection_seq') from fcopies;
insert into public.wants (user_id, oracle_id, qty, seq)
select distinct on (u, g) u, md5('o' || g)::uuid, 1 + g % 2, nextval('public.collection_seq')
  from (select md5('friend' || i)::uuid u, 1 + (i::bigint * 15485863 + k::bigint * 32452843) % 35000 g
          from generate_series(2, 200) i, generate_series(1, 200) k
        union all
        select md5('friend1')::uuid, k from generate_series(1, 2000) k) s;
analyze;
set role authenticated;
select pg_temp.as_user(:BIG);
select public.trade_matches() as tm \gset
select pg_temp.eq('matches found across friends', (jsonb_array_length((:'tm'::jsonb)->'people') > 40)::text, 'true');
select pg_temp.ms('trade_matches, 200 friends', $$select public.trade_matches()$$, 500);
select pg_temp.ms('trade_matches, the big trader', $$select public.trade_matches(md5('friend1')::uuid)$$, 150);
select pg_temp.ms('profile_view of a friend', $$select public.profile_view(md5('friend1')::uuid)$$, 25);
-- Cube rankings: a 540-card cube ranked over 6,000 screens (the most a ranking holds).
select public.list_create('e7000000-0000-0000-0000-0000000000f1', 'cube', 'Big cube', 'vintage',
  (select jsonb_agg(jsonb_build_array(md5('c' || g || '-0')::uuid, 'main', 1)) from generate_series(1, 540) g));
select public.cube_ranking_create('f7000000-0000-0000-0000-0000000000f1', 'e7000000-0000-0000-0000-0000000000f1', 'Big run');
create temp table rank_screens as
select jsonb_agg(jsonb_build_object('s', 'F', 't', k, 'o', jsonb_build_array(
         md5('o' || (1 + (k * 4) % 540))::uuid, md5('o' || (1 + (k * 4 + 1) % 540))::uuid,
         md5('o' || (1 + (k * 4 + 2) % 540))::uuid, md5('o' || (1 + (k * 4 + 3) % 540))::uuid))) a
  from generate_series(1, 1000) k;
do $$ begin
  for i in 0..5 loop
    perform public.cube_ranking_push('f7000000-0000-0000-0000-0000000000f1', i, i * 1000, (select a from rank_screens));
  end loop;
end $$;
select pg_temp.eq('6000 screens', public.cube_ranking_get('f7000000-0000-0000-0000-0000000000f1')->>'screens', '6000');
select pg_temp.ms('cube_ranking_get, 6000 screens', $$select public.cube_ranking_get('f7000000-0000-0000-0000-0000000000f1')$$, 150);
select pg_temp.ms('cube_ranking_push, one screen onto 5999', $$select public.cube_ranking_push('f7000000-0000-0000-0000-0000000000f1',
  (public.cube_rankings('e7000000-0000-0000-0000-0000000000f1')->'rankings'->0->>'rev')::int, 5999,
  jsonb_build_array((select a->0 from rank_screens)))$$, 250);
-- The guard matches the p_drop screens against the whole log: a redo of the first of 6000, the new apps' way.
select pg_temp.ms('cube_ranking_push, redo of the first of 6000 (p_drop)', $$select public.cube_ranking_push('f7000000-0000-0000-0000-0000000000f1',
  (public.cube_rankings('e7000000-0000-0000-0000-0000000000f1')->'rankings'->0->>'rev')::int, 6000, '[]', p_count := 6000, p_removed := 1,
  p_drop := jsonb_build_array(public.cube_ranking_get('f7000000-0000-0000-0000-0000000000f1')->'log'->0))$$, 400, 1);
select pg_temp.ms('cube_rankings of a cube', $$select public.cube_rankings('e7000000-0000-0000-0000-0000000000f1')$$, 25);
-- Follows (contract/follows-2026-10-25.md): the big account follows its 200 friends' trade binders (500 printings
-- each, the big trader's 5,000), then all 200 change at once and one digest run sends them.
reset role;
update public.share_settings set binders = 'friends' where user_id in (select md5('friend' || i)::uuid from generate_series(1, 200) i);
set role authenticated;
select pg_temp.as_user(:BIG);
select count(public.follow_set('binder', md5('fbinder' || i)::uuid, true)) from generate_series(1, 100) i;
reset role;
delete from public.account_audit where action = 'follow.set';   -- 100 follows an hour
set role authenticated;
select count(public.follow_set('binder', md5('fbinder' || i)::uuid, true)) from generate_series(101, 200) i;
select pg_temp.ms('follow_set, pushes off', $$select public.follow_set('binder', md5('fbinder1')::uuid, true, false)$$, 25);
reset role;
update public.binder_items set qty = qty + 1
 where binder_id in (select md5('fbinder' || i)::uuid from generate_series(1, 200) i) and card_id in (select md5('c' || g || '-0')::uuid from generate_series(1, 35000, 7) g);
update t1_private.follow_items set dirty_last = dirty_last - interval '31 minutes' where dirty_last is not null;
select pg_temp.ms('follow_digest, one run of 200 changed binders', $$select t1_private.follow_digest()$$, 1500, 1);
select pg_temp.eq('every binder got its update', (select count(*)::text from t1_private.follow_updates), '200');
-- The same writes went into for-trade binders: 200 friends' new copies against the big account's 500 wants.
update t1_private.trade_adds set last_at = last_at - interval '31 minutes';
select pg_temp.ms('trade_want_digest, 200 friends'' new trade copies', $$select t1_private.trade_want_digest()$$, 2500, 1);
select pg_temp.eq('the big account hears about its friends'' new copies', ((select count(*) from pgmq.messages where msg->>'kind' = 'trade.wants') > 20)::text, 'true');
set role authenticated;
select pg_temp.as_user(:BIG);
select pg_temp.ms('follows_list, 200 follows', $$select public.follows_list()$$, 350);
select pg_temp.ms('follow_changes of the big binder', $$select public.follow_changes('binder', md5('fbinder1')::uuid)$$, 25);
reset role;
-- Want prices (contract/want-prices-2026-10-26.md): the big account's 500 wants (any printing, 3 printings each)
-- and 200 friends' 50 wants each on top of the ~42k already seeded (52k wants), with 30 days of history; then a
-- third off a tenth of the prices and one digest run. Live has 8 wants (2026-10-26).
reset role;
insert into public.wants (user_id, oracle_id, qty, seq)
select md5('friend' || i)::uuid, md5('o' || (1 + (i * 50 + k) % 35000))::uuid, 1, 1
  from generate_series(1, 200) i, generate_series(1, 50) k
on conflict do nothing;
do $$ begin for i in reverse 30..2 loop perform t1_private.price_days_take(current_date - i); end loop; end $$;
analyze;
select pg_temp.ms('price_days_take, 52k wants', $$select t1_private.price_days_take(current_date - 1)$$, 1500, 1);
update public.card_prices set usd = round(usd * 0.66, 2) where card_id in (select id from public.cards where set_code < 's2');
set role authenticated;
select pg_temp.as_user(:BIG);
select pg_temp.ms('wants_prices, 500 wants with 30 days', $$select public.wants_prices()$$, 100);
reset role;
select pg_temp.ms('want_price_digest, 52k wants', $$select t1_private.want_price_digest()$$, 15000, 1);
select pg_temp.eq('drops pushed', ((select count(*) from pgmq.messages where msg->>'kind' = 'want.price') > 20)::text, 'true');
-- Buy on TCGplayer (contract/tcgplayer-cart-2026-10-26.md): the most a cart takes, 2000 printings.
set role authenticated;
select pg_temp.as_user(:BIG);
select pg_temp.ms('tcgplayer_cart, 2000 printings', $$select public.tcgplayer_cart((select jsonb_agg(jsonb_build_object('card_id', md5('c' || g || '-1')::uuid, 'qty', 1 + g % 4)) from generate_series(1, 2000) g))$$, 300);
reset role;
-- Limited set rankings (contract/cube-rankings-2026-10-21.md § Sets): 20 recent sets of ~350 printings each in the
-- live-size catalog, a 600-card set ranking opened (watchers re-read it every 10 s) and the new-set check.
insert into public.mtg_sets (code, name, set_type, released_at, card_count)
select 's' || g, 'Set ' || g, 'expansion', current_date - g * 15, 400 from generate_series(0, 19) g
on conflict (code) do update set set_type = 'expansion', released_at = excluded.released_at, card_count = 400;
analyze public.mtg_sets;
set role authenticated;
select pg_temp.as_user(:BIG);
select pg_temp.ms('limited_rankable, 20 sets', $$select public.limited_rankable()$$, 150);
select public.cube_ranking_create('f5800000-0000-0000-0000-000000000001', p_set => 'S1');
select pg_temp.ms('cube_ranking_get, a set ranking', $$select public.cube_ranking_get('f5800000-0000-0000-0000-000000000001')$$, 60);
select pg_temp.ms('cube_rankings of a set', $$select public.cube_rankings(p_set => 'S1')$$, 20);
reset role;
select pg_temp.ms('catalog_set_gaps', $$select public.catalog_set_gaps()$$, 60);
