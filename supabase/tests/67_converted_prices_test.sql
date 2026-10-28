-- Converted prices (contract/converted-prices-2026-10-28.md, cases testdata/converted-prices/cases.json).
\ir _helpers.sql
create or replace function pg_temp.j(v jsonb, path text[]) returns text language sql as $$ select v #>> path $$;
\set cases `cat ../../testdata/converted-prices/cases.json`

-- The ECB answer parses.
select pg_temp.eq('ecb answer parses',
  t1_private.fx_parse_day((:'cases'::jsonb)#>>'{ecb,xml}') || ' ' || t1_private.fx_parse_rate((:'cases'::jsonb)#>>'{ecb,xml}'),
  ((:'cases'::jsonb)#>>'{ecb,day}') || ' ' || ((:'cases'::jsonb)#>>'{ecb,rate}'));
select pg_temp.eq('no rate in junk', coalesce(t1_private.fx_parse_rate('<html>Service unavailable</html>')::text, 'none'), 'none');

-- The cases' printings, one Oracle card per name.
insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash)
select distinct on (c->>'card') md5(c->>'card')::uuid, c->>'card', lower(c->>'card'), 'normal', (c->>'id')::uuid, 'a', 'h'
  from jsonb_array_elements((:'cases'::jsonb)->'printings') c;
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash)
select (c->>'id')::uuid, md5(c->>'card')::uuid, c->>'set', right(c->>'id', 2), 'en', 'rare', '{nonfoil,foil}', 'normal', 'h'
  from jsonb_array_elements((:'cases'::jsonb)->'printings') c;
insert into public.card_prices (card_id, usd, usd_foil, usd_etched, eur, eur_foil)
select (c->>'id')::uuid, (c->>'usd')::numeric, (c->>'usd_foil')::numeric, (c->>'usd_etched')::numeric,
       (c->>'eur')::numeric, (c->>'eur_foil')::numeric
  from jsonb_array_elements((:'cases'::jsonb)->'printings') c;

-- The migration seeded the spike day's rate; the cases use the same one.
select pg_temp.eq('seeded rate', (select usd_per_eur::numeric(10,4)::text from t1_private.fx_rates order by day desc limit 1),
  (:'cases'::jsonb)->>'rate');
select pg_temp.eq('refresh writes the converted rows', t1_private.card_price_fallback_refresh()::text, '5');
select pg_temp.eq('refresh again changes nothing', t1_private.card_price_fallback_refresh()::text, '0');

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
set role authenticated;
select pg_temp.as_user(:ANA);
select public.card_prices_get(array(select (c->>'id')::uuid from jsonb_array_elements((:'cases'::jsonb)->'printings') c)) as got \gset
select pg_temp.eq('every case',
  (select count(*)::text from jsonb_array_elements((:'cases'::jsonb)->'printings') c
     join jsonb_array_elements(:'got'::jsonb) g on g->>0 = c->>'id'
    where (select jsonb_agg(x) from (select (g->>1)::numeric x union all select (g->>2)::numeric union all select (g->>3)::numeric
                                     union all select (g->>6)::numeric) s)
          = (select jsonb_agg(x::numeric) from jsonb_array_elements_text(c->'want') x)),
  (select jsonb_array_length((:'cases'::jsonb)->'printings')::text));
select pg_temp.eq('rows have seven elements', (select jsonb_array_length(:'got'::jsonb->0)::text), '7');

-- The collection is valued with the converted price, in the copy's condition: Beta Mox LP = 90% of $7,992.55.
select public.collection_apply(jsonb_build_array(
  jsonb_build_object('card_id', 'c1000000-0000-0000-0000-000000000002', 'condition', 'LP', 'delta', 1),
  jsonb_build_object('card_id', 'c1000000-0000-0000-0000-000000000004', 'delta', 1)),
  'manual', null, 'e0000000-0000-0000-0000-000000000001') as r \gset
select pg_temp.eq('value uses the converted price', pg_temp.j(:'r'::jsonb, '{summary,value_usd}'), '7193.30');
reset role;
select pg_temp.throws('signed out is refused',
  $$ select pg_temp.as_user(null); set role anon; select public.card_prices_get(array['c1000000-0000-0000-0000-000000000001'::uuid]) $$);
reset role;

-- A new rate: the hourly tick asks the ECB (the seeded rate is a day old), reads the answer, then rests.
select pg_temp.eq('tick asks', t1_private.fx_tick(), 'asked');
select pg_temp.eq('asks the ECB', (select url from net.requests order by id desc limit 1),
  'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml');
select pg_temp.eq('tick waits for the answer', t1_private.fx_tick(), 'waiting');
insert into net._http_response (id, status_code, content)
select request_id, 500, 'oops' from t1_private.fx_state;
select pg_temp.eq('a failed answer is not a rate', t1_private.fx_tick(), 'bad answer 500');
select pg_temp.eq('then asks again', t1_private.fx_tick(), 'asked');
insert into net._http_response (id, status_code, content)
select request_id, 200, replace(replace((:'cases'::jsonb)#>>'{ecb,xml}', '2026-10-28', '2026-10-29'), '1.1133', '1.2000')
  from t1_private.fx_state;
select pg_temp.eq('reads the rate', t1_private.fx_tick(), 'rate 2026-10-29 1.2000');
select pg_temp.eq('then rests', t1_private.fx_tick(), 'fresh');

-- Prices follow the new rate at the next refresh; the nightly revalue follows them.
select t1_private.card_price_fallback_refresh();
select pg_temp.eq('converted at the new rate',
  (select usd::text from t1_private.card_price_fallback where card_id = 'c1000000-0000-0000-0000-000000000002'), '8614.98');
update public.library_summary set value_usd = 0 where user_id = :ANA;
select t1_private.library_revalue();
select pg_temp.eq('revalue uses the new rate', (select value_usd::text from public.library_summary where user_id = :ANA), '7753.48');

-- TCGplayer prices it again: the real price wins at once, and the converted row goes at the next refresh.
update public.card_prices set usd = 9500.00 where card_id = 'c1000000-0000-0000-0000-000000000002';
select pg_temp.eq('real price wins',
  (select usd || '/' || converted from t1_private.card_prices_usd where card_id = 'c1000000-0000-0000-0000-000000000002'), '9500.00/0');
select t1_private.card_price_fallback_refresh();
select pg_temp.eq('converted row gone',
  (select count(*)::text from t1_private.card_price_fallback where card_id = 'c1000000-0000-0000-0000-000000000002'), '0');

-- Want prices stay on TCGplayer: a card only Cardmarket prices has no want price.
insert into public.wants (user_id, oracle_id, qty, seq) values (:ANA, md5('Lone Card')::uuid, 1, 1);
select pg_temp.eq('wants ignore converted prices',
  (select coalesce(now::text, 'none') from t1_private.want_prices_of(:ANA) where oracle_id = md5('Lone Card')::uuid), 'none');

-- The value functions read the view; card_prices itself is never written.
select pg_temp.eq('readers use the view',
  (select string_agg(p.proname, ' ' order by p.proname) from pg_proc p
    where p.proname in ('collection_apply_as', 'library_revalue', 'trade_matches_for', 'redraft_list', 'card_prices_get')
      and p.prosrc like '%card_prices_usd%'),
  'card_prices_get collection_apply_as library_revalue redraft_list trade_matches_for');
select pg_temp.eq('nothing else can read the fallback',
  (has_table_privilege('authenticated', 't1_private.card_price_fallback', 'select')
   or has_table_privilege('authenticated', 't1_private.card_prices_usd', 'select'))::text, 'false');
