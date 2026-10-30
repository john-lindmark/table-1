-- Sync a cube with Cube Cobra (contract/cube-sync-2026-10-30.md): list_source_set, list_sync, source_url on answers.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''

insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000002', 'Opt', 'opt', 'normal', 'c1000000-0000-0000-0000-000000000002', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil,foil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'xln', '65', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000001', '2xm', '141', 'en', 'common', '{nonfoil,foil}', 'normal', 'h');
\set BOLT '''c1000000-0000-0000-0000-000000000001'''
\set OPT '''c1000000-0000-0000-0000-000000000002'''
\set BOLT2 '''c1000000-0000-0000-0000-000000000003'''
\set CUBE '''d0000000-0000-0000-0000-0000000000c1'''
\set LINK '''https://cubecobra.com/cube/list/lindmark'''

set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_create(:CUBE, 'cube', 'Lindmark Cube', 'vintage', jsonb_build_array(
  jsonb_build_array(:BOLT, 'main', 1), jsonb_build_array(:OPT, 'main', 1, 'nonfoil', 'ja')), 'Imported from cubecobra.com') as c \gset
select pg_temp.eq('a new list has no source', (:'c'::jsonb)->>'source_url', null);

-- Remember the link --------------------------------------------------------------------------------------------
select public.list_source_set(:CUBE, :LINK) as s \gset
select pg_temp.eq('the link is remembered', (:'s'::jsonb)->>'source_url', 'https://cubecobra.com/cube/list/lindmark');
select pg_temp.eq('remembering moves the seq', (((:'s'::jsonb)->>'seq')::bigint > ((:'c'::jsonb)->>'seq')::bigint)::text, 'true');
select pg_temp.eq('lists_changes carries the link',
  (select l->>'source_url' from jsonb_array_elements(public.lists_changes(0)->'lists') l where l->>'id' = :CUBE), 'https://cubecobra.com/cube/list/lindmark');
select pg_temp.throws('not a link refused', format($$select public.list_source_set('%s', 'javascript:alert(1)')$$, :CUBE), '22023');
select pg_temp.as_user(null);
select pg_temp.throws('signed-out caller refused', format($$select public.list_source_set('%s', null)$$, :CUBE));

-- Another account can't touch it.
select pg_temp.as_user(:BEN);
select pg_temp.throws('another account cannot set the link', format($$select public.list_source_set('%s', null)$$, :CUBE));
select pg_temp.throws('another account cannot sync', format($$select public.list_sync('%s', 0, '[]')$$, :CUBE));
select pg_temp.as_user(:ANA);

-- Sync ---------------------------------------------------------------------------------------------------------
select ((:'s'::jsonb)->>'seq')::bigint as list_json_seq \gset
select pg_temp.throws('a stale seq is a conflict',
  format($$select public.list_sync('%s', %s, '[]')$$, :CUBE, :list_json_seq - 1), 'PT409');

-- Cube Cobra now has Bolt in 2XM foil (new printing + finish), Opt kept in Japanese, and Opt in Considering.
select public.list_sync(:CUBE, :list_json_seq, jsonb_build_array(
  jsonb_build_array(:BOLT2, 'main', 1, 'foil'), jsonb_build_array(:OPT, 'main', 1, 'nonfoil', 'ja'),
  jsonb_build_array(:OPT, 'maybe', 1)), :LINK) as r \gset
reset role;
select pg_temp.eq('the synced cube is a new version with its note',
  (select version || ' ' || note from public.card_list_versions where list_id = :CUBE order by version desc limit 1), '2 Synced with Cube Cobra');
select pg_temp.eq('the synced lines are the current contents',
  (select string_agg(board || ' ' || card_id || ' ' || finish || ' ' || lang, ', ' order by board, card_id, lang)
     from public.card_list_entries where list_id = :CUBE),
  format('main %s nonfoil ja, main %s foil en, maybe %s nonfoil en', :OPT, :BOLT2, :OPT));
select pg_temp.eq('a sync is never extended by the next edit',
  (select count(*)::text from public.card_list_versions where list_id = :CUBE and open_until is not null), '0');
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('the answer carries the link', (:'r'::jsonb)->>'source_url', 'https://cubecobra.com/cube/list/lindmark');
select pg_temp.throws('the same seq again is a conflict (retry after success)',
  format($$select public.list_sync('%s', %s, '[]')$$, :CUBE, :list_json_seq), 'PT409');
select pg_temp.throws('entries must be an array',
  format($$select public.list_sync('%s', %s, '{}')$$, :CUBE, ((:'r'::jsonb)->>'seq')), '22023');

-- An edit after a sync starts its own version.
select public.list_edit(:CUBE, jsonb_build_array(jsonb_build_object('card_id', :OPT, 'board', 'maybe', 'delta', 1))) as e \gset
select pg_temp.eq('the next edit is version 3', (:'e'::jsonb)->>'current_version', '3');

-- Forget the link.
select public.list_source_set(:CUBE, '') as f \gset
select pg_temp.eq('a blank link forgets it', (:'f'::jsonb)->>'source_url', null);

-- Grants.
reset role;
select pg_temp.eq('anon cannot sync', has_function_privilege('anon', 'public.list_sync(uuid, bigint, jsonb, text, text)', 'execute')::text, 'false');
select pg_temp.eq('anon cannot set a link', has_function_privilege('anon', 'public.list_source_set(uuid, text)', 'execute')::text, 'false');
