-- /ranking in Discord (20261103235000_discord_rankings, contract/discord-2026-10-29.md § Rankings): the picker lists
-- your own rankings of live cubes and of sets, and one ranking comes back with its log, the cube's cards and their
-- facts, made as the linked account; someone else's ranking, an unlinked user and clients are refused.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000094a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000094b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}');
\set ANA '''00000000-0000-0000-0000-0000000094a1'''
\set BEN '''00000000-0000-0000-0000-0000000094b1'''
insert into t1_private.discord_links (discord_user_id, user_id) values ('194001', :ANA), ('194002', :BEN);

insert into public.mtg_sets (code, name, set_type, released_at, card_count) values ('new', 'New Horizons', 'expansion', current_date - 5, 300);
insert into public.card_oracles (oracle_id, name, name_norm, layout, type_line, mana_cost, colors, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000009401', 'Lightning Bolt', 'lightning bolt', 'normal', 'Instant', '{R}', '{R}', 'c1000000-0000-0000-0000-000000009401', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000009402', 'Opt', 'opt', 'normal', 'Instant', '{U}', '{U}', 'c1000000-0000-0000-0000-000000009402', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000009403', 'Strip Mine', 'strip mine', 'normal', 'Land', null, '{}', 'c1000000-0000-0000-0000-000000009403', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000009404', 'Horizon Drake', 'horizon drake', 'normal', 'Creature — Drake', '{1}{U}', '{U}', 'c1000000-0000-0000-0000-000000009404', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000009405', 'Dawn Bolt', 'dawn bolt', 'normal', 'Instant', '{W}', '{W}', 'c1000000-0000-0000-0000-000000009405', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000009401', 'c0000000-0000-0000-0000-000000009401', 'm10', '146', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000009402', 'c0000000-0000-0000-0000-000000009402', 'xln', '65', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000009403', 'c0000000-0000-0000-0000-000000009403', 'ate', '79', 'en', 'uncommon', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000009404', 'c0000000-0000-0000-0000-000000009404', 'new', '12', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000009405', 'c0000000-0000-0000-0000-000000009405', 'new', '140', 'en', 'common', '{nonfoil}', 'normal', 'h');
\set BOLT '''c0000000-0000-0000-0000-000000009401'''
\set OPT '''c0000000-0000-0000-0000-000000009402'''
\set CUBE '''e7000000-0000-0000-0000-000000009401'''
\set GONE '''e7000000-0000-0000-0000-000000009402'''
\set BCUBE '''e7000000-0000-0000-0000-000000009403'''
\set R1 '''f7000000-0000-0000-0000-000000009401'''
\set R2 '''f7000000-0000-0000-0000-000000009402'''
\set R3 '''f7000000-0000-0000-0000-000000009403'''
\set RB '''f7000000-0000-0000-0000-000000009404'''

set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_create(:CUBE, 'cube', 'Lindmark Cube', 'vintage', jsonb_build_array(
  jsonb_build_array('c1000000-0000-0000-0000-000000009401', 'main', 1),
  jsonb_build_array('c1000000-0000-0000-0000-000000009402', 'main', 1),
  jsonb_build_array('c1000000-0000-0000-0000-000000009403', 'main', 1)));
select public.list_create(:GONE, 'cube', 'Old Cube', 'vintage', jsonb_build_array(jsonb_build_array('c1000000-0000-0000-0000-000000009401', 'main', 1)));
select public.cube_ranking_create(:R1, :CUBE, 'Summer', 'full', 50);
select public.cube_ranking_push(:R1, 0, 0, jsonb_build_array(jsonb_build_object('s', 'F', 'o', jsonb_build_array(:BOLT, :OPT))), 0, 3, 2);
select public.cube_ranking_create(:R2, :GONE);
select public.cube_ranking_create(:R3, p_set => 'NEW');
select public.list_delete(:GONE);
select pg_temp.as_user(:BEN);
select public.list_create(:BCUBE, 'cube', 'Ben Cube', 'vintage', jsonb_build_array(jsonb_build_array('c1000000-0000-0000-0000-000000009401', 'main', 1)));
select public.cube_ranking_create(:RB, :BCUBE);
reset role;

-- The picker -------------------------------------------------------------------------------------------------------
select pg_temp.eq('your rankings of live cubes and sets, newest first',
  (select string_agg(x->>'subject' || ' ' || (x->>'kind'), ', ' order by o) from jsonb_array_elements(public.discord_my_rankings('194001')) with ordinality t(x, o)),
  'New Horizons set, Lindmark Cube cube');
select pg_temp.eq('with label, depth and progress', (select x->>'name' || '/' || (x->>'top') || '/' || (x->>'ranked')
  from jsonb_array_elements(public.discord_my_rankings('194001')) x where x->>'kind' = 'cube'), 'Summer/50/2');
select pg_temp.eq('matched on the subject', (select string_agg(x->>'subject', ',') from jsonb_array_elements(public.discord_my_rankings('194001', 'lindm')) x), 'Lindmark Cube');
select pg_temp.eq('on the label', (select string_agg(x->>'subject', ',') from jsonb_array_elements(public.discord_my_rankings('194001', 'summ')) x), 'Lindmark Cube');
select pg_temp.eq('on the set code', (select string_agg(x->>'set', ',') from jsonb_array_elements(public.discord_my_rankings('194001', 'new')) x), 'NEW');
select pg_temp.eq('only your own', (select string_agg(x->>'subject', ',') from jsonb_array_elements(public.discord_my_rankings('194002')) x), 'Ben Cube');
select pg_temp.throws('an unlinked Discord user is asked to link', $$select public.discord_my_rankings('194999')$$, '28000');

-- One ranking ------------------------------------------------------------------------------------------------------
select public.discord_ranking('194001', :R1) as r1 \gset
select pg_temp.eq('the ranking with its log', (:'r1'::jsonb)->>'name' || '/' || ((:'r1'::jsonb)->>'depth') || '/' || jsonb_array_length((:'r1'::jsonb)->'log')::text, 'Summer/full/1');
select pg_temp.eq('the cube''s cards', jsonb_array_length((:'r1'::jsonb)->'cards')::text, '3');
select pg_temp.eq('with their facts', (select string_agg((f->>1) || ':' || coalesce(f->>2, '') || ':' || (f->4)::text, ', ' order by f->>1) from jsonb_array_elements((:'r1'::jsonb)->'facts') f),
  'Lightning Bolt:Instant:["R"], Opt:Instant:["U"], Strip Mine:Land:[]');
select pg_temp.eq('the cube without its card list or the change log',
  ((:'r1'::jsonb)->'cube'->>'name') || '/' || ((:'r1'::jsonb)->'cube' ? 'cards')::text || '/' || ((:'r1'::jsonb) ? 'changes')::text || '/' || ((:'r1'::jsonb)->'cube' ? 'printings')::text,
  'Lindmark Cube/false/false/true');
select pg_temp.eq('by its person', (:'r1'::jsonb)->'by'->>'display_name', 'Ana Lind');
select public.discord_ranking('194001', :R3) as r3 \gset
select pg_temp.eq('a set ranking: the set''s cards', ((:'r3'::jsonb)->'cube'->>'name') || '/' || jsonb_array_length((:'r3'::jsonb)->'facts')::text, 'New Horizons/2');
select pg_temp.throws('someone else''s ranking is refused', format($$select public.discord_ranking('194001', %L)$$, :RB), '22023');
select pg_temp.throws('as is your ranking of a deleted cube', format($$select public.discord_ranking('194001', %L)$$, :R2), '22023');
select pg_temp.throws('no ranking at all', $$select public.discord_ranking('194001', null)$$, '22023');
select pg_temp.throws('unlinked', format($$select public.discord_ranking('194999', %L)$$, :R1), '28000');

-- Grants -----------------------------------------------------------------------------------------------------------
select pg_temp.eq('clients can''t call them',
  has_function_privilege('authenticated', 'public.discord_ranking(text, uuid)', 'execute')::text || '/'
  || has_function_privilege('anon', 'public.discord_my_rankings(text, text, integer)', 'execute')::text || '/'
  || has_function_privilege('service_role', 'public.discord_ranking(text, uuid)', 'execute')::text, 'false/false/true');
