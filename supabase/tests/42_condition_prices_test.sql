-- Condition prices (contract/condition-prices-2026-10-24.md, cases testdata/condition-prices/cases.json).
\ir _helpers.sql
create or replace function pg_temp.j(v jsonb, path text[]) returns text language sql as $$ select v #>> path $$;
\set cases `cat ../../testdata/condition-prices/cases.json`

select pg_temp.eq('unit cases',
  (select count(*)::text from jsonb_array_elements((:'cases'::jsonb)->'unit') c
    where t1_private.condition_price((c->>'nm')::numeric, c->>'condition') is not distinct from (c->>'price')::numeric),
  (select jsonb_array_length((:'cases'::jsonb)->'unit')::text));
select pg_temp.eq('total case',
  (select sum((c->>'qty')::int * t1_private.condition_price((c->>'nm')::numeric, c->>'condition'))::text
     from jsonb_array_elements((:'cases'::jsonb)->'copies') c),
  (select ((:'cases'::jsonb)->>'total')::numeric(14,2)::text));
select pg_temp.eq('percent table',
  (select string_agg(k || '=' || t1_private.condition_percent(k), ' ' order by k) from jsonb_object_keys((:'cases'::jsonb)->'percent') k),
  (select string_agg(k || '=' || v, ' ' order by k) from jsonb_each_text((:'cases'::jsonb)->'percent') e(k, v)));

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil,foil}', 'normal', 'h');
insert into public.card_prices (card_id, usd, usd_foil, eur, eur_foil) values
  ('c1000000-0000-0000-0000-000000000001', 10.00, 40.00, 8.00, 30.00);
\set BOLT '''c1000000-0000-0000-0000-000000000001'''

set role authenticated;
select pg_temp.as_user(:ANA);
-- 2 NM ($20) + 3 HP ($15) + 1 LP foil ($34); EUR 16 + 12 + 25.50.
select public.collection_apply(jsonb_build_array(
  jsonb_build_object('card_id', :BOLT, 'delta', 2),
  jsonb_build_object('card_id', :BOLT, 'condition', 'HP', 'delta', 3),
  jsonb_build_object('card_id', :BOLT, 'finish', 'foil', 'condition', 'LP', 'delta', 1)),
  'manual', null, 'e0000000-0000-0000-0000-000000000001') as r \gset
select pg_temp.eq('value follows condition', pg_temp.j(:'r'::jsonb, '{summary,value_usd}') || '/' || pg_temp.j(:'r'::jsonb, '{summary,value_eur}'),
  '69.00/53.50');

-- Moving a copy from NM to DMG takes $6.50 off.
select public.collection_apply(jsonb_build_array(
  jsonb_build_object('card_id', :BOLT, 'delta', -1),
  jsonb_build_object('card_id', :BOLT, 'condition', 'DMG', 'delta', 1)),
  'manual', null, 'e0000000-0000-0000-0000-000000000002') as r \gset
select pg_temp.eq('changing condition changes the value', pg_temp.j(:'r'::jsonb, '{summary,value_usd}'), '62.50');
select public.collection_undo(((:'r'::jsonb)->>'batch_id')::uuid) as u \gset
select pg_temp.eq('undo puts it back', pg_temp.j(:'u'::jsonb, '{summary,value_usd}'), '69.00');

reset role;
update public.library_summary set value_usd = 0, value_eur = 0 where user_id = :ANA;
select t1_private.library_revalue();
select pg_temp.eq('nightly revalue agrees',
  (select value_usd || '/' || value_eur from public.library_summary where user_id = :ANA), '69.00/53.50');
