-- Search finds other people's decks, cubes and binders (contract/library-search-2026-10-18.md § Collection search).
\ir _helpers.sql

-- Ana shares; Ben is her friend; Cal is a stranger with a link to her cube; Eve keeps her deck to herself.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com', '{"full_name": "Cal Reyes"}'),
  ('00000000-0000-0000-0000-0000000000e1', 'eve@example.com', '{"full_name": "Eve Moss"}');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''
\set CAL '''00000000-0000-0000-0000-0000000000c1'''
\set EVE '''00000000-0000-0000-0000-0000000000e1'''

insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil,foil}', 'normal', 'h');
\set BOLT '''c1000000-0000-0000-0000-000000000001'''
\set DECK '''d1000000-0000-0000-0000-000000000001'''
\set OPEN '''d1000000-0000-0000-0000-000000000002'''
\set CUBE '''d1000000-0000-0000-0000-000000000003'''
\set EVES '''d1000000-0000-0000-0000-000000000004'''
\set TRADES '''b1000000-0000-0000-0000-000000000001'''

create or replace function pg_temp.found(q text) returns text language sql as $$
  select coalesce(string_agg(i->>'name' || ':' || coalesce(i->>'user_id', 'link') || case when (i->>'following')::boolean then '+' else '' end,
                             ',' order by n), '')
    from jsonb_array_elements(public.library_search(q)->'items') with ordinality t(i, n);
$$;

set role authenticated;
select pg_temp.as_user(:BEN);
select public.friend_request(:ANA);
select pg_temp.as_user(:ANA);
select public.friend_respond(:BEN, true);
select public.binder_save(:TRADES, 'Trades', true);
select public.list_create(:DECK, 'deck', 'Burn', 'modern', jsonb_build_array(jsonb_build_array(:BOLT, 'main', 4)));
select public.list_create(:OPEN, 'deck', 'Open burn', 'modern', jsonb_build_array(jsonb_build_array(:BOLT, 'main', 3)));
select public.list_create(:CUBE, 'cube', 'Pauper cube', 'cube', jsonb_build_array(jsonb_build_array(:BOLT, 'main', 1)));
select public.sharing_set('{"profile": "public"}');
select public.sharing_set(jsonb_build_object('items', jsonb_build_array(
  jsonb_build_object('kind', 'deck', 'id', :DECK, 'visibility', 'friends'),
  jsonb_build_object('kind', 'deck', 'id', :OPEN, 'visibility', 'public'),
  jsonb_build_object('kind', 'binder', 'id', :TRADES, 'visibility', 'friends'))));
select (public.share_link_create('cube', :CUBE))->>'token' cube_tok \gset
select pg_temp.as_user(:EVE);
select public.list_create(:EVES, 'deck', 'Burn at home', 'modern', '[]'::jsonb);

-- What each person finds ----------------------------------------------------------------------------------------
select pg_temp.as_user(:ANA);
select pg_temp.eq('never your own', pg_temp.found('burn'), '');
select pg_temp.as_user(:BEN);
select pg_temp.eq('a friend finds both, by name', pg_temp.found('burn'),
  'Burn:00000000-0000-0000-0000-0000000000a1,Open burn:00000000-0000-0000-0000-0000000000a1');
select pg_temp.eq('names starting with the word first', pg_temp.found('bur'),
  'Burn:00000000-0000-0000-0000-0000000000a1,Open burn:00000000-0000-0000-0000-0000000000a1');
select pg_temp.eq('every word, any case, owner name too', pg_temp.found('ANA trades'), 'Trades:00000000-0000-0000-0000-0000000000a1');
select pg_temp.eq('format counts for decks', pg_temp.found('modern open'), 'Open burn:00000000-0000-0000-0000-0000000000a1');
select pg_temp.eq('a private cube stays hidden', pg_temp.found('pauper'), '');
select pg_temp.eq('one letter finds nothing', pg_temp.found('b'), '');
select pg_temp.eq('a binder says it''s for trade', (public.library_search('trades')->'items'->0)::text,
  '{"id": "b1000000-0000-0000-0000-000000000001", "kind": "binder", "name": "Trades", "cards": 0, "owner": {"display_name": "Ana Lind"}, "user_id": "00000000-0000-0000-0000-0000000000a1", "following": false, "for_trade": true}');
select pg_temp.eq('a deck carries its format and cards', (public.library_search('open')->'items'->0)::text,
  '{"id": "d1000000-0000-0000-0000-000000000002", "kind": "deck", "name": "Open burn", "cards": 3, "owner": {"display_name": "Ana Lind"}, "format": "modern", "user_id": "00000000-0000-0000-0000-0000000000a1", "following": false}');
select public.follow_set('deck', :OPEN, true);
select pg_temp.eq('what you follow comes first', pg_temp.found('burn'),
  'Open burn:00000000-0000-0000-0000-0000000000a1+,Burn:00000000-0000-0000-0000-0000000000a1');
select pg_temp.eq('the limit holds', jsonb_array_length(public.library_search('burn', 1)->'items')::text, '1');

select pg_temp.as_user(:CAL);
select pg_temp.eq('a stranger finds only what''s set to Anyone', pg_temp.found('burn'), 'Open burn:00000000-0000-0000-0000-0000000000a1');
select pg_temp.eq('not the cube without its link', pg_temp.found('pauper'), '');
select public.follow_set('cube', :CUBE, true, null, :'cube_tok');
select pg_temp.eq('a cube followed by link opens the link', pg_temp.found('pauper'), 'Pauper cube:link+');
select pg_temp.eq('with its token', public.library_search('pauper')->'items'->0->>'token', :'cube_tok');

select pg_temp.as_user(:ANA);
select public.user_block(:CAL, true);
select pg_temp.as_user(:CAL);
select pg_temp.eq('a block hides everything', pg_temp.found('burn') || pg_temp.found('pauper'), '');
select pg_temp.as_user(:ANA);
select public.user_block(:CAL, false);
select public.share_link_revoke('cube', :CUBE);
select pg_temp.as_user(:CAL);
select pg_temp.eq('a stopped link stops finding it', pg_temp.found('pauper'), '');

-- With p_all: cards inside lists, Insights archetypes, rankings (20261102140000_library_search_more.sql) -------------
create or replace function pg_temp.more(q text) returns text language sql as $$
  select coalesce(string_agg(i->>'kind' || ':' || (i->>'name')
                             || coalesce(' has ' || (i->'has'->>'qty') || ' ' || (i->'has'->>'name'), '')
                             || case when (i->>'mine')::boolean then ' mine' else '' end, ',' order by n), '')
    from jsonb_array_elements(public.library_search(q, 20, true)->'items') with ordinality t(i, n);
$$;
\set BENS '''d1000000-0000-0000-0000-000000000005'''
\set RANK '''e1000000-0000-0000-0000-000000000001'''
reset role;
delete from t1_private.meta_archetypes where format = 'modern';
insert into t1_private.meta_archetypes (id, format, name, family, status, rule, priority) values
  (9091, 'modern', 'Boros Burn', 'aggro', 'approved', '{}', 10),
  (9092, 'modern', 'Old Burn', 'aggro', 'approved', '{}', 10),
  (9093, 'modern', 'Proposed Burn', 'aggro', 'proposed', '{}', 10);
insert into t1_private.meta_events (id, source, source_id, format, name, kind, on_date, tier)
values (91, 'topdeck', 's1', 'modern', 'Event', 'paper', current_date - 5, 'regular'),
       (92, 'topdeck', 's2', 'modern', 'Old event', 'paper', current_date - 200, 'regular');
insert into t1_private.meta_decks (event_id, format, on_date, tier, weight, player, main, main_qty, side, side_qty, archetype_id)
values (91, 'modern', current_date - 5, 'regular', 1, 'x1', '{}', '{}', '{}', '{}', 9091),
       (91, 'modern', current_date - 5, 'regular', 1, 'x2', '{}', '{}', '{}', '{}', 9091),
       (91, 'modern', current_date - 5, 'regular', 1, 'x3', '{}', '{}', '{}', '{}', 9093),
       (92, 'modern', current_date - 200, 'regular', 1, 'x4', '{}', '{}', '{}', '{}', 9092);
set role authenticated;

select pg_temp.as_user(:BEN);
select public.list_create(:BENS, 'deck', 'Mono red', 'modern', jsonb_build_array(jsonb_build_array(:BOLT, 'main', 2)));
select pg_temp.eq('without p_all, as before', pg_temp.found('lightning'), '');
select pg_temp.eq('a card finds the lists that hold it, yours too', pg_temp.more('lightning bolt'),
  'deck:Mono red has 2 Lightning Bolt mine,deck:Open burn has 3 Lightning Bolt,deck:Burn has 4 Lightning Bolt');
select pg_temp.eq('a list found by name doesn''t say what it has', pg_temp.more('burn'),
  'deck:Open burn,deck:Burn,archetype:Boros Burn');
select pg_temp.eq('an archetype carries its format and lists', (public.library_search('boros', 20, true)->'items'->0)::text,
  '{"id": "9091", "kind": "archetype", "name": "Boros Burn", "decks": 2, "format": "modern"}');
select pg_temp.eq('archetypes by format too', pg_temp.more('modern boros'), 'archetype:Boros Burn');
select pg_temp.eq('your own lists by name stay on the device', pg_temp.more('mono red'), '');
select pg_temp.eq('two letters don''t look for cards (Bolt)', pg_temp.more('bo'), 'archetype:Boros Burn');

select pg_temp.as_user(:ANA);
select public.sharing_set(jsonb_build_object('items', jsonb_build_array(jsonb_build_object('kind', 'cube', 'id', :CUBE, 'visibility', 'friends'))));
select public.cube_ranking_create(:RANK, :CUBE, 'Power only');
select pg_temp.eq('your ranking, by what it ranks', pg_temp.more('pauper'), 'ranking:Pauper cube mine');
select pg_temp.eq('a ranking carries its subject, label and who', (public.library_search('power', 20, true)->'items'->0)::text,
  '{"id": "e1000000-0000-0000-0000-000000000001", "kind": "ranking", "mine": true, "name": "Pauper cube", "label": "Power only", "owner": {"display_name": "Ana Lind"}, "subject": "d1000000-0000-0000-0000-000000000003"}');
select pg_temp.as_user(:BEN);
select pg_temp.eq('a friend finds the cube and its ranking', pg_temp.more('pauper'), 'cube:Pauper cube,ranking:Pauper cube');
select pg_temp.eq('a ranking by who ranked it', pg_temp.more('ana power'), 'ranking:Pauper cube');
select pg_temp.as_user(:CAL);
select pg_temp.eq('a stranger sees neither', pg_temp.more('pauper'), '');

reset role;
insert into public.moderation_restrictions (user_id, until, reason, by_user) values (:ANA, now() + interval '1 day', 'test', :BEN);
set role authenticated;
select pg_temp.as_user(:BEN);
select pg_temp.eq('a restricted account shares nothing', pg_temp.found('burn') || pg_temp.more('pauper'), '');
reset role;
delete from public.moderation_restrictions where user_id = :ANA;
set role authenticated;

-- Refusals -------------------------------------------------------------------------------------------------------
select pg_temp.as_user(null);
select pg_temp.throws('signed out', $$select public.library_search('burn')$$, '28000');
reset role;
set role anon;
select pg_temp.throws('anon is refused', $$select public.library_search('burn')$$);
reset role;
