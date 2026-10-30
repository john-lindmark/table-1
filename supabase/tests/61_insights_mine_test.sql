-- Insights: your decks first in the matchup grid (20261030100000_insights_mine.sql, contract/insights-2026-10-24.md
-- § What the viewer gets): your decks' archetypes and how much of each archetype's usual list your collection holds.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''

-- Five cards, one printing each.
create function pg_temp.card(p_name text, p_type text) returns uuid language sql as $$
  insert into public.card_oracles (oracle_id, name, name_norm, layout, type_line, colors, source_card_id, source_rank, content_hash)
  values (md5(p_name)::uuid, p_name, lower(p_name), 'normal', p_type, '{R}', md5('p' || p_name)::uuid, 'a', 'h');
  insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash)
  values (md5('p' || p_name)::uuid, md5(p_name)::uuid, 'tst', left(md5(p_name), 6), 'en', 'common', '{nonfoil}', 'normal', 'h');
  select md5(p_name)::uuid;
$$;
create function pg_temp.p(p_name text) returns uuid language sql as $$ select md5('p' || p_name)::uuid $$;
select pg_temp.card('Alpha', 'Creature — Monkey'), pg_temp.card('Beta', 'Instant'), pg_temp.card('Gamma', 'Instant'),
       pg_temp.card('Delta', 'Sorcery'), pg_temp.card('Mountain', 'Basic Land — Mountain');

-- Red (Alpha) and Blue (Gamma). Four Red lists play 4 Alpha, two of them 2 Beta, one 1 Delta; two Blue lists 4 Gamma.
delete from t1_private.meta_archetypes where format = 'modern';
insert into t1_private.meta_archetypes (id, format, name, family, status, rule, priority) values
  (1, 'modern', 'Red', 'aggro', 'approved', '{}', 10), (2, 'modern', 'Blue', 'control', 'approved', '{}', 10);
-- (rules compile r_main from card names on insert; set the ids directly, as 66_spice_test does)
update t1_private.meta_archetypes set r_main = array[md5('Alpha')::uuid] where id = 1;
update t1_private.meta_archetypes set r_main = array[md5('Gamma')::uuid] where id = 2;
insert into t1_private.meta_events (id, source, source_id, format, name, kind, on_date, tier)
values (1, 'topdeck', 'e1', 'modern', 'Event', 'paper', current_date - 5, 'regular'),
       (2, 'topdeck', 'e2', 'modern', 'Old event', 'paper', current_date - 120, 'regular');
insert into t1_private.meta_decks (event_id, format, on_date, tier, weight, player, main, main_qty, side, side_qty, archetype_id)
values (1, 'modern', current_date - 5, 'regular', 1, 'p1', array[md5('Alpha'), md5('Beta'), md5('Mountain')]::uuid[], '{4,2,18}', '{}', '{}', 1),
       (1, 'modern', current_date - 5, 'regular', 1, 'p2', array[md5('Alpha'), md5('Beta'), md5('Mountain')]::uuid[], '{4,2,18}', '{}', '{}', 1),
       (1, 'modern', current_date - 5, 'regular', 1, 'p3', array[md5('Alpha'), md5('Delta'), md5('Mountain')]::uuid[], '{4,1,18}', '{}', '{}', 1),
       (1, 'modern', current_date - 5, 'regular', 1, 'p4', array[md5('Alpha'), md5('Mountain')]::uuid[], '{4,20}', '{}', '{}', 1),
       (1, 'modern', current_date - 5, 'regular', 1, 'p5', array[md5('Gamma'), md5('Mountain')]::uuid[], '{4,20}', '{}', '{}', 2),
       (1, 'modern', current_date - 5, 'regular', 1, 'p6', array[md5('Gamma'), md5('Mountain')]::uuid[], '{4,20}', '{}', '{}', 2),
       -- older than 90 days: Delta in every Red list back then doesn't make it usual now
       (2, 'modern', current_date - 120, 'regular', 1, 'p7', array[md5('Alpha'), md5('Delta')]::uuid[], '{4,4}', '{}', '{}', 1);

-- Last week's event (10 days ago): one more Red list (Alpha, Beta) and a Blue one. Matches, Red's side first: this
-- week Red beat Blue twice and lost once, plus a Red mirror (left out); the week before Red lost to Blue.
insert into t1_private.meta_events (id, source, source_id, format, name, kind, on_date, tier)
values (3, 'topdeck', 'e3', 'modern', 'Last week', 'paper', current_date - 10, 'regular');
insert into t1_private.meta_decks (event_id, format, on_date, tier, weight, player, main, main_qty, side, side_qty, archetype_id)
values (3, 'modern', current_date - 10, 'regular', 1, 'p8', array[md5('Alpha'), md5('Beta')]::uuid[], '{4,2}', '{}', '{}', 1),
       (3, 'modern', current_date - 10, 'regular', 1, 'p9', array[md5('Gamma')]::uuid[], '{4}', '{}', '{}', 2);
create function pg_temp.deck(p text) returns bigint language sql as $$ select id from t1_private.meta_decks where player = p $$;
insert into t1_private.meta_matches (event_id, round, a, b, result) values
  (1, 'R1', pg_temp.deck('p1'), pg_temp.deck('p5'), 'a'), (1, 'R2', pg_temp.deck('p6'), pg_temp.deck('p2'), 'b'),
  (1, 'R3', pg_temp.deck('p3'), pg_temp.deck('p5'), 'b'), (1, 'R4', pg_temp.deck('p1'), pg_temp.deck('p2'), 'a'),
  (3, 'R1', pg_temp.deck('p9'), pg_temp.deck('p8'), 'a');

-- Ana owns 3 Alpha (two printings' worth of rows), 4 Beta and Mountains; a tombstoned Gamma row doesn't count.
insert into public.collection_items (user_id, card_id, finish, condition, qty, seq) values
  (:ANA, pg_temp.p('Alpha'), 'nonfoil', 'NM', 2, 1), (:ANA, pg_temp.p('Alpha'), 'foil', 'NM', 1, 2),
  (:ANA, pg_temp.p('Beta'), 'nonfoil', 'NM', 4, 3), (:ANA, pg_temp.p('Mountain'), 'nonfoil', 'NM', 40, 4),
  (:ANA, pg_temp.p('Gamma'), 'nonfoil', 'NM', 0, 5);

set role authenticated;
select pg_temp.as_user(:ANA);
\set DECK '''d2000000-0000-0000-0000-000000000001'''
select public.list_create(:DECK, 'deck', 'My Red', 'modern',
  jsonb_build_array(jsonb_build_array(pg_temp.p('Alpha'), 'main', 4), jsonb_build_array(pg_temp.p('Mountain'), 'main', 20))) is not null as made \gset
select public.list_create('d2000000-0000-0000-0000-000000000002', 'deck', 'Pioneer pile', 'pioneer',
  jsonb_build_array(jsonb_build_array(pg_temp.p('Gamma'), 'main', 4))) is not null as made \gset

select pg_temp.eq('your deck in the format, with its archetype',
  ((public.insights_mine('modern'))->'decks')::text, jsonb_build_array(jsonb_build_object('a', 1, 'id', :DECK, 'name', 'My Red'))::text);
select pg_temp.eq('coverage: 3 of 4 Alpha + 2 of 2 Beta = 5 of 6 for Red; nothing of Blue; basics and rare cards left out',
  ((public.insights_mine('modern'))->'coverage')::text, '[{"a": 1, "have": 0.833}, {"a": 2, "have": 0.000}]');
reset role;
select pg_temp.eq('the usual lists: Alpha 4 and Beta 2 for Red, Gamma 4 for Blue, built once today',
  (select string_agg(archetype_id || ':' || o.name || ' ' || copies, ', ' order by archetype_id, o.name)
     from t1_private.meta_cores k join public.card_oracles o on o.oracle_id = k.card where k.built_on = current_date),
  '1:Alpha 4, 1:Beta 2, 2:Gamma 4');
set role authenticated;

select pg_temp.as_user(:BEN);
select pg_temp.eq('another account: none of Ana''s decks or cards',
  (public.insights_mine('modern'))::text, '{"decks": [], "coverage": [{"a": 1, "have": 0.000}, {"a": 2, "have": 0.000}]}');
select pg_temp.throws('an unknown format', $$select public.insights_mine('nope')$$, '22023');
select pg_temp.as_user(null);
select pg_temp.throws('signed out', $$select public.insights_mine('modern')$$, '42501');
reset role;
set role anon;
select pg_temp.throws('anon cannot call it', $$select public.insights_mine('modern')$$, '42501');
reset role;
select pg_temp.throws('clients cannot read the usual lists', $$set role authenticated; select * from t1_private.meta_cores$$, '42501');
reset role;

-- A deck's archetype on its own screen (20261030110000_list_insight.sql) ------------------------------------------
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('your deck: its archetype, 30 days, this week, the week before, and each matchup',
  (public.list_insight(:DECK))::text,
  '{"a": 1, "name": "Red", "prev": {"wins": 0, "draws": 0, "losses": 1}, "week": {"wins": 2, "draws": 0, "losses": 1}, "month": {"wins": 2, "draws": 0, "losses": 2}, "format": "modern", "matchups": [{"vs": 2, "name": "Blue", "wins": 2, "draws": 0, "losses": 2}]}');
reset role;
select pg_temp.eq('kept for the archetype and the day', (select count(*) || ' ' || bool_and(on_day = current_date)::text from t1_private.archetype_insight), '1 true');
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('a second ask reads the kept answer', (public.list_insight(:DECK))->'week'->>'wins', '2');
select pg_temp.eq('a deck no rule names', (public.list_insight('d2000000-0000-0000-0000-000000000002'))->>'reason', 'other');
select pg_temp.as_user(:BEN);
select pg_temp.throws('someone else''s private deck', format('select public.list_insight(%L)', :DECK), '42501');
select pg_temp.as_user(null);
select pg_temp.throws('signed out without a link', format('select public.list_insight(%L)', :DECK), '42501');
reset role;
