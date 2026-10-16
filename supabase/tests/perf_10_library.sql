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
