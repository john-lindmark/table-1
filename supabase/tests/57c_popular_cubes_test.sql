-- Popular cubes to rank (20261110140000_popular_cubes.sql; contract/cube-rankings-2026-10-21.md § Popular cubes): the
-- four cubes are seeded, popular_cube_put matches a list by printing, Oracle id or name and refuses a thin one,
-- a popular cube ranks like a set (subject, cards, printings), friends see each other's shared rankings of it and
-- strangers don't, popular_cubes() counts them, and the cubes never show up as Limited sets.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000057c0a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-00000057c0b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}'),
  ('00000000-0000-0000-0000-00000057c0c1', 'cal@example.com', '{"full_name": "Cal Reyes"}');
\set ANA '''00000000-0000-0000-0000-00000057c0a1'''
\set BEN '''00000000-0000-0000-0000-00000057c0b1'''
\set CAL '''00000000-0000-0000-0000-00000057c0c1'''

-- 320 cards: card n has Oracle c57c…n and printings p57c…n (set aaa) and q57c…n (set bbb); names "Card n".
insert into public.card_oracles (oracle_id, name, name_norm, layout, type_line, source_card_id, source_rank, content_hash)
select ('c57c0000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 'Card ' || n, 'card ' || n, 'normal', 'Instant',
       ('a57c0000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 'a', 'h'
  from generate_series(1, 320) n;
insert into public.card_names (name_norm, oracle_id)
select public.card_name_norm('Card ' || n), ('c57c0000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid from generate_series(1, 320) n;
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash)
select (pfx || lpad(n::text, 12, '0'))::uuid, ('c57c0000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, s, n::text, 'en',
       'common', '{nonfoil}', 'normal', 'h'
  from generate_series(1, 320) n, (values ('d57c0000-0000-0000-0000-', 'aaa'), ('e57c0000-0000-0000-0000-', 'bbb')) v(pfx, s);
\set C1 '''c57c0000-0000-0000-0000-000000000001'''
\set R1 '''f57c0000-0000-0000-0000-000000000001'''
\set R2 '''f57c0000-0000-0000-0000-000000000002'''
\set R3 '''f57c0000-0000-0000-0000-000000000003'''
\set R4 '''f57c0000-0000-0000-0000-000000000004'''

select pg_temp.eq('the four cubes are seeded in John''s order',
  (select string_agg(key || ':' || source, ' ' order by position) from t1_private.popular_cubes),
  'PLSV:cubecobra LSV:cubecobra VCUBE:mtgo APCUBE:scryfall');
select pg_temp.eq('a cube with no list yet is not a subject', t1_private.limited_subject_ok('PLSV')::text, 'false');

-- Putting a list ---------------------------------------------------------------------------------------------
-- Cards 1–100 by printing (bbb), 101–200 by Oracle id, 201–320 by name, plus a name nothing matches and a repeat.
create or replace function pg_temp.mixed() returns jsonb language sql as $$
  select jsonb_agg(x) from (
    select jsonb_build_object('name', 'Card ' || n, 'card_id', 'e57c0000-0000-0000-0000-' || lpad(n::text, 12, '0')) x from generate_series(1, 100) n
    union all select jsonb_build_object('name', 'whatever', 'oracle_id', 'c57c0000-0000-0000-0000-' || lpad(n::text, 12, '0')) from generate_series(101, 200) n
    union all select jsonb_build_object('name', 'Card ' || n) from generate_series(201, 320) n
    union all select jsonb_build_object('name', 'Nothing Like It')
    union all select jsonb_build_object('name', 'Card 5')) y;
$$;
select pg_temp.eq('a list matches by printing, Oracle id or name',
  (select (r->>'cards') || ' ' || (r->'missing')::text || ' ' || (r->>'changed') from public.popular_cube_put('plsv', pg_temp.mixed()) r),
  '320 ["Nothing Like It"] true');
select pg_temp.eq('printings kept for the cards given by printing only',
  (select (printings->>(:C1)::text) || ' ' || (select count(*) from jsonb_object_keys(printings)) from t1_private.popular_cubes where key = 'PLSV'),
  'e57c0000-0000-0000-0000-000000000001 100');
select pg_temp.eq('the same list again changes nothing',
  (select r->>'changed' from public.popular_cube_put('PLSV', pg_temp.mixed()) r), 'false');
select pg_temp.throws('a thin list is refused, keeping the old one',
  $$select public.popular_cube_put('PLSV', (select jsonb_agg(jsonb_build_object('name', 'Card ' || n)) from generate_series(1, 50) n))$$, '22023');
select pg_temp.eq('the old list is still there', (select cardinality(cards)::text from t1_private.popular_cubes where key = 'PLSV'), '320');
select pg_temp.throws('an unknown cube is refused', $$select public.popular_cube_put('NOPE', '[]')$$, '22023');
select pg_temp.eq('sources for limited-sync', public.popular_cube_sources()->2->>'ref', 'https://www.mtgo.com/vintage-cube-cardlist');

-- As a subject -------------------------------------------------------------------------------------------------
select pg_temp.eq('a cube with a list is a subject', t1_private.limited_subject_ok('PLSV')::text, 'true');
select pg_temp.eq('it reads as a popular cube',
  (select (j->>'id') || ' ' || (j->>'kind') || ' ' || (j->>'name') || ' ' || (j->>'curator') || ' ' || (j->>'url')
     from t1_private.set_subject_json('PLSV') j),
  'set:PLSV popular PowerLSV LSV https://cubecobra.com/cube/list/786d3a10-43bd-438e-acf4-bb150b881254');

set role authenticated;
select pg_temp.as_user(:ANA);
select public.friend_request(:BEN);
select pg_temp.as_user(:BEN);
select public.friend_respond(:ANA, true);

select pg_temp.as_user(:ANA);
select pg_temp.eq('Ana ranks PowerLSV like a set',
  (select (r->>'set_key') || ' ' || (r->>'sharing') from public.cube_ranking_create(:R1, p_set => 'PLSV') r), 'PLSV cube');
select public.cube_ranking_create(:R2, p_set => 'PLSV', p_sharing => 'private');
select pg_temp.eq('get: the cube''s 320 cards, drawn in its printings',
  (select (c->>'kind') || ' ' || jsonb_array_length(c->'cards') || ' ' || (c->'printings'->>(:C1)::text)
     from (select public.cube_ranking_get(:R1)->'cube' c) x),
  'popular 320 e57c0000-0000-0000-0000-000000000001');
select pg_temp.eq('its baseline is the cube''s cards', jsonb_array_length(public.cube_ranking_get(:R1)->'baseline')::text, '320');
select pg_temp.throws('a cube without a list can''t be ranked yet',
  $$select public.cube_ranking_create('f57c0000-0000-0000-0000-0000000000ff', p_set => 'LSV')$$, '22023');

select pg_temp.as_user(:BEN);
select public.cube_ranking_create(:R3, p_set => 'PLSV');
select pg_temp.eq('Ben sees his own and Ana''s shared one, his first',
  (select string_agg(case when (r->>'mine')::boolean then 'mine' else r->'by'->>'display_name' end, ',' order by i)
     from jsonb_array_elements(public.cube_rankings(p_set => 'PLSV')->'rankings') with ordinality t(r, i)), 'mine,Ana Lind');
select pg_temp.eq('the subject comes back as the popular cube', public.cube_rankings(p_set => 'PLSV')->'cube'->>'kind', 'popular');
select pg_temp.eq('popular_cubes: only cubes with a list, with counts',
  (select string_agg((c->>'key') || ' ' || (c->>'cards') || ' ' || (c->>'mine') || '/' || (c->>'rankings') || '/' || (c->>'friends'), ',')
     from jsonb_array_elements(public.popular_cubes()) c), 'PLSV 320 1/2/1');
select pg_temp.eq('Ana''s shared ranking opens for her friend', public.cube_ranking_get(:R1)->>'set_key', 'PLSV');
select pg_temp.throws('her Only me ranking doesn''t', $$select public.cube_ranking_get('f57c0000-0000-0000-0000-000000000002')$$, '42501');

select pg_temp.as_user(:CAL);
select public.cube_ranking_create(:R4, p_set => 'PLSV');
select pg_temp.eq('a stranger sees only his own', (select string_agg(r->>'mine', ',') from jsonb_array_elements(public.cube_rankings(p_set => 'PLSV')->'rankings') r), 'true');
select pg_temp.eq('and counts only his own', public.popular_cubes()->0->>'rankings', '1');
select pg_temp.throws('and can''t open Ana''s', $$select public.cube_ranking_get('f57c0000-0000-0000-0000-000000000001')$$, '42501');

select pg_temp.as_user(:ANA);
select pg_temp.eq('Ana''s profile lists her PowerLSV ranking as a popular cube',
  (select string_agg((r->'subject'->>'kind') || ':' || (r->'subject'->>'name'), ',')
     from jsonb_array_elements(public.profile_view(:ANA)->'sections'->'rankings') r where r->'subject'->>'id' = 'set:PLSV'),
  'popular:PowerLSV,popular:PowerLSV');
select pg_temp.eq('popular cubes are never Limited sets to rank',
  (select count(*)::text from jsonb_array_elements(public.limited_rankable()) s where s->>'key' in ('PLSV', 'LSV', 'VCUBE', 'APCUBE')), '0');

-- Who may call what ----------------------------------------------------------------------------------------------
select pg_temp.throws('clients can''t put a list', $$select public.popular_cube_put('PLSV', '[]')$$, '42501');
select pg_temp.throws('clients can''t read the sources', $$select public.popular_cube_sources()$$, '42501');
select pg_temp.as_user(null);
select pg_temp.throws('signed out is refused', $$select public.popular_cubes()$$, '28000');
reset role;
set role anon;
select pg_temp.throws('anon can''t call popular_cubes', $$select public.popular_cubes()$$, '42501');
reset role;
