-- Spice (contract/spice-2026-10-28.md, cases testdata/spice/cases.json from testdata/spice/make_cases.py).
\ir _helpers.sql
\set cases `cat ../../testdata/spice/cases.json`

-- jsonb equality (numbers by value); on a mismatch print both.
create or replace function pg_temp.jeq(label text, got jsonb, want jsonb) returns void language plpgsql as $$
begin
  if got is distinct from want then raise exception 'FAIL %: got %, want %', label, got, want; end if;
  raise notice 'ok  %', label;
end $$;
create or replace function pg_temp.ids(v jsonb) returns uuid[] language sql as $$
  select coalesce(array_agg((x->>0)::uuid order by n), '{}') from jsonb_array_elements(v) with ordinality t(x, n) $$;
create or replace function pg_temp.qty(v jsonb) returns integer[] language sql as $$
  select coalesce(array_agg((x->>1)::int order by n), '{}') from jsonb_array_elements(v) with ordinality t(x, n) $$;
-- A printing per card: the test's own set, numbered from the Oracle id.
create or replace function pg_temp.printing(o uuid) returns uuid language sql as $$ select md5('p' || o::text)::uuid $$;
create or replace function pg_temp.entries(v jsonb, board text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(pg_temp.printing((x->>0)::uuid), board, (x->>1)::int) order by n), '[]')
    from jsonb_array_elements(v) with ordinality t(x, n) $$;

-- Corpus, dated relative to today the way the cases are relative to theirs ---------------------------------------
insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash,
                                 type_line, colors, color_identity)
select (c->>'c')::uuid, c->>'n', lower(c->>'n'), 'normal', pg_temp.printing((c->>'c')::uuid), 'a', 'h',
       case when (c->>'basic')::boolean then 'Basic Land — ' || (c->>'n') else 'Instant' end,
       case when c->>'ci' = '' then '{}' else regexp_split_to_array(c->>'ci', '') end,
       case when c->>'ci' = '' then '{}' else regexp_split_to_array(c->>'ci', '') end
  from jsonb_array_elements((:'cases'::jsonb)->'corpus'->'cards') c;
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash)
select pg_temp.printing(o.oracle_id), o.oracle_id, 'tst', left(md5(o.oracle_id::text), 8), 'en', 'common', '{nonfoil}', 'normal', 'h'
  from public.card_oracles o;

delete from t1_private.meta_archetypes;
insert into t1_private.meta_archetypes (id, format, name, family, status, rule)
select (a->>'id')::int, a->>'format', a->>'name', 'aggro', 'approved', '{}'::jsonb
  from jsonb_array_elements((:'cases'::jsonb)->'corpus'->'archetypes') a;
-- Labels for the list_spice checks: Boros Energy needs Guide of Souls + Phlage, Murktide its namesake, Hammer Time
-- Colossus Hammer.
update t1_private.meta_archetypes set r_main = array['c0000000-0000-0000-0000-000000000011',
                                                     'c0000000-0000-0000-0000-000000000013']::uuid[] where id = 1;
update t1_private.meta_archetypes set r_main = array['c0000000-0000-0000-0000-000000000020']::uuid[] where id = 2;
update t1_private.meta_archetypes set r_main = array['c0000000-0000-0000-0000-000000000030']::uuid[] where id = 3;

insert into t1_private.meta_events (id, source, source_id, format, name, kind, on_date, tier)
select (e->>'id')::bigint, e->>'source', 'e' || (e->>'id'), e->>'format', 'Event ' || (e->>'id'), 'challenge',
       current_date - ((:'cases'::jsonb->>'today')::date - (e->>'on')::date), 'regular'
  from jsonb_array_elements((:'cases'::jsonb)->'corpus'->'events') e;
insert into t1_private.meta_decks (id, event_id, format, on_date, tier, weight, player, main, main_qty, side, side_qty,
                                   colors, archetype_id)
select (d->>'id')::bigint, (d->>'event')::bigint, d->>'format',
       current_date - ((:'cases'::jsonb->>'today')::date - (d->>'on')::date), 'regular', 1, 'p' || (d->>'id'),
       pg_temp.ids(d->'main'), pg_temp.qty(d->'main')::smallint[], pg_temp.ids(d->'side'), pg_temp.qty(d->'side')::smallint[],
       d->>'colors', (d->>'archetype')::int
  from jsonb_array_elements((:'cases'::jsonb)->'corpus'->'decks') d;
select t1_private.spice_refresh() > 0 as counted \gset

-- Words -----------------------------------------------------------------------------------------------------------
select pg_temp.eq('words at every boundary',
  (select string_agg(t1_private.spice_word((w->>'score')::int), ',') from jsonb_array_elements((:'cases'::jsonb)->'words') w),
  (select string_agg(w->>'word', ',') from jsonb_array_elements((:'cases'::jsonb)->'words') w));

-- Every case against the reference -----------------------------------------------------------------------------------
select pg_temp.eq('no comparison cubes yet: no cube score',
  t1_private.spice_cube(array['c0000000-0000-0000-0000-000000000100']::uuid[], array[1])->>'reason', 'no_cubes');

insert into t1_private.cube_corpus (id, source, source_id, name, cards)
select (k->>'id')::bigint, k->>'source', k->>'source_id', k->>'name',
       (select array_agg(x::uuid) from jsonb_array_elements_text(k->'cards') x)
  from jsonb_array_elements((:'cases'::jsonb)->'corpus'->'cubes') k;

select set_config('t1.cases', :'cases', false) is not null as loaded \gset
do $$
declare c jsonb; got jsonb; n integer := 0;
begin
  for c in select jsonb_array_elements(current_setting('t1.cases')::jsonb->'cases') loop
    if c->>'kind' = 'cube' then
      got := t1_private.spice_cube(pg_temp.ids(c->'main'), pg_temp.qty(c->'main'));
    else
      got := t1_private.spice_deck(c->>'format', (c->>'label')::int, pg_temp.ids(c->'main'), pg_temp.qty(c->'main'),
                                   pg_temp.ids(c->'side'), pg_temp.qty(c->'side'), current_date);
    end if;
    if got is distinct from c->'expect' then
      raise exception 'FAIL case "%": got %, want %', c->>'name', got, c->'expect';
    end if;
    n := n + 1;
  end loop;
  raise notice 'ok  % reference cases', n;
end $$;

-- list_spice: who may ask, the cache ---------------------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''
\set DECK '''d1000000-0000-0000-0000-000000000001'''
\set CUBE '''d1000000-0000-0000-0000-000000000002'''
\set LEGACY '''d1000000-0000-0000-0000-000000000003'''

select c->'main' tuned_main, c->'expect' tuned_expect from jsonb_array_elements((:'cases'::jsonb)->'cases') c
 where c->>'name' = 'tuned Boros Energy' \gset
select c->'main' cube_main, c->'expect' cube_expect from jsonb_array_elements((:'cases'::jsonb)->'cases') c
 where c->>'name' = 'cube among close cubes' \gset

set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_create(:DECK, 'deck', 'Boros', 'modern', pg_temp.entries(:'tuned_main', 'main')) is not null as made \gset
select public.list_create(:CUBE, 'cube', 'My cube', 'cube', pg_temp.entries(:'cube_main', 'main')) is not null as made \gset
select public.list_create(:LEGACY, 'deck', 'Burn', 'legacy',
  jsonb_build_array(jsonb_build_array(pg_temp.printing('c0000000-0000-0000-0000-000000000010'), 'main', 4))) is not null as made \gset

select pg_temp.jeq('owner: the deck labels as Boros Energy and matches the reference', public.list_spice(:DECK), :'tuned_expect');
select pg_temp.jeq('owner: the cube matches the reference', public.list_spice(:CUBE), :'cube_expect');
select pg_temp.eq('a format without lists', public.list_spice(:LEGACY)->>'reason', 'no_data');
reset role;
select pg_temp.eq('cached for the list''s seq today',
  (select count(*)::text from t1_private.list_spice c join public.card_lists l on l.id = c.list_id
    where c.list_id = :DECK and c.seq = l.seq and c.on_day = current_date), '1');
update t1_private.list_spice set result = result || '{"cached": true}' where list_id = :DECK;
set role authenticated;
select pg_temp.eq('asking again reads the cache', public.list_spice(:DECK)->>'cached', 'true');

-- An edit (new seq) computes again: the commander slot counts as the main deck.
select public.list_edit(:DECK, jsonb_build_array(jsonb_build_object('card_id', pg_temp.printing('c0000000-0000-0000-0000-000000000041'),
  'board', 'commander', 'delta', 1))) is not null as edited \gset
reset role;
select t1_private.spice_deck('modern', 1,
    pg_temp.ids(:'tuned_main') || 'c0000000-0000-0000-0000-000000000041'::uuid, pg_temp.qty(:'tuned_main') || 1,
    '{}', '{}', current_date) after_edit \gset
set role authenticated;
select pg_temp.jeq('after an edit: computed again, commander counted', public.list_spice(:DECK), :'after_edit');

select pg_temp.throws('an unknown list is private', $$select public.list_spice('d1000000-0000-0000-0000-0000000000ff')$$, '42501');

-- Ben: refused while the deck is private, allowed once it's shared with anyone, refused again once blocked.
select pg_temp.as_user(:BEN);
select pg_temp.throws('a stranger can''t read a private deck', format('select public.list_spice(%L)', :DECK), '42501');
select pg_temp.as_user(:ANA);
select public.sharing_set(jsonb_build_object('profile', 'public', 'items', jsonb_build_array(
  jsonb_build_object('kind', 'deck', 'id', :DECK, 'visibility', 'public')))) is not null as shared \gset
select pg_temp.as_user(:BEN);
select pg_temp.eq('shared with anyone: Ben sees the score', ((public.list_spice(:DECK)->>'score') is not null)::text, 'true');
select pg_temp.throws('the cube is still private', format('select public.list_spice(%L)', :CUBE), '42501');
select pg_temp.as_user(:ANA);
select public.user_block(:BEN, true) is not null as blocked \gset
select pg_temp.as_user(:BEN);
select pg_temp.throws('a block wins', format('select public.list_spice(%L)', :DECK), '42501');

-- Links: the holder of the cube's link may ask, signed out too; another item's link doesn't open it.
select pg_temp.as_user(:ANA);
select public.share_link_create('cube', :CUBE)->>'token' cube_tok \gset
select public.share_link_create('deck', :LEGACY)->>'token' legacy_tok \gset
set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('signed out without a link', format('select public.list_spice(%L)', :CUBE), '42501');
select pg_temp.jeq('signed out with the link', public.list_spice(:CUBE, :'cube_tok'), :'cube_expect');
select pg_temp.throws('another item''s link', format('select public.list_spice(%L, %L)', :CUBE, :'legacy_tok'), '42501');

-- A deleted list is gone.
set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_delete(:LEGACY) is not null as gone \gset
select pg_temp.throws('a deleted list', format('select public.list_spice(%L)', :LEGACY), '42501');
