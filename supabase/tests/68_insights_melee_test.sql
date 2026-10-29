-- Insights' Melee source (contract/insights-2026-10-24.md § Sources and tiers): queued without a format, ingested as
-- paper, its records preferred to MTGO's top 32, counted by spice.
\ir _helpers.sql

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com');
create function pg_temp.card(p_name text, p_type text, p_colors text[]) returns uuid language sql as $$
  insert into public.card_oracles (oracle_id, name, name_norm, face_names, layout, type_line, colors, color_identity, legalities,
                                   source_card_id, source_rank, content_hash)
  values (md5(p_name)::uuid, p_name, public.card_name_norm(p_name), '{}', 'normal', p_type, p_colors, p_colors, '{"modern": "legal"}',
          md5('s' || p_name)::uuid, 'a', 'h')
  returning oracle_id;
$$;
select pg_temp.card('Lightning Bolt', 'Instant', '{R}'), pg_temp.card('Lava Spike', 'Sorcery', '{R}'),
       pg_temp.card('Counterspell', 'Instant', '{U}'), pg_temp.card('Mountain', 'Basic Land — Mountain', '{}'),
       pg_temp.card('Island', 'Basic Land — Island', '{}');
insert into public.card_names (name_norm, oracle_id, is_face) select name_norm, oracle_id, false from public.card_oracles on conflict do nothing;

-- Queue ------------------------------------------------------------------------------------------------------------
select pg_temp.eq('a Melee file is queued without a format; MTGO pages still need an enabled one',
  public.meta_queue_add('[{"source": "melee", "format": null, "slug": "2026/10/02/a.json@abc", "url": "https://raw.example/a.json"},
                          {"source": "melee", "format": "legacy", "slug": "2026/10/02/b.json@abc", "url": "https://raw.example/b.json"},
                          {"source": "mtgo", "format": "legacy", "slug": "legacy-challenge", "url": "https://www.mtgo.com/x"},
                          {"source": "mtgo", "slug": "nothing", "url": "https://www.mtgo.com/y"}]')::text, '2');
select pg_temp.eq('queued Melee rows have no format',
  (select string_agg(slug || ':' || coalesce(format, '-'), ' ' order by slug) from t1_private.meta_queue), '2026/10/02/a.json@abc:- 2026/10/02/b.json@abc:-');
select pg_temp.eq('the same file again is not queued twice',
  public.meta_queue_add('[{"source": "melee", "slug": "2026/10/02/a.json@abc", "url": "https://raw.example/a.json"}]')::text, '0');
select pg_temp.eq('a changed file (new blob sha) is queued again',
  public.meta_queue_add('[{"source": "melee", "slug": "2026/10/02/a.json@def", "url": "https://raw.example/a.json"}]')::text, '1');
select pg_temp.eq('claimed with no format', (select string_agg(coalesce(q->>'format', '-'), ' ') from jsonb_array_elements(public.meta_queue_claim(1)) q), '-');
select pg_temp.throws('an MTGO row still needs a format',
  $$insert into t1_private.meta_queue (source, slug, url) values ('mtgo', 'x', 'y')$$, '23514');

-- Ingest -----------------------------------------------------------------------------------------------------------
-- 32 players, burn and blue in turn; a TopDeck-style whole-field record for each.
create function pg_temp.melee(p_id text, p_name text) returns jsonb language sql as $$
  select jsonb_build_object('source', 'melee', 'source_id', p_id, 'format', 'modern', 'name', p_name, 'kind',
    case when p_name ilike '%regional championship%' then 'championship' else 'paper' end,
    'on', (current_date - 5)::text, 'players', 32, 'url', 'https://melee.gg/Tournament/View/1', 'complete', true,
    'decks', (select jsonb_agg(jsonb_build_object('player', 'Player ' || i, 'rank', i, 'wins', 5 - i % 3, 'losses', i % 3, 'draws', 0,
                'top8', i <= 8, 'side', '[]'::jsonb,
                'main', case when i % 2 = 1 then '[["Lightning Bolt", 4], ["Lava Spike", 4], ["Mountain", 52]]'::jsonb
                             else '[["Counterspell", 4], ["Island", 56]]'::jsonb end) order by i)
                from generate_series(1, 32) i),
    'matches', '[{"round": "Round 1", "a": "Player 1", "b": "Player 2", "a_wins": 2, "b_wins": 1, "result": "a"},
                 {"round": "Round 1", "a": "Player 3", "b": "Player 4", "a_wins": 1, "b_wins": 1, "result": "draw"}]'::jsonb);
$$;
select pg_temp.eq('a Melee event is stored as paper with every deck',
  (select (r->>'decks') || ' ' || (r->>'tier') from (select public.meta_ingest(pg_temp.melee('modern-rcq-1', 'Modern RCQ')) r) x), '32 regular');
select pg_temp.eq('and its rounds, draws included', (select string_agg(result, ' ' order by result) from t1_private.meta_matches), 'a draw');
select pg_temp.eq('a regional championship is major at any size',
  (public.meta_ingest(pg_temp.melee('rc-1', 'Regional Championship - Sydney')))->>'tier', 'major');
select pg_temp.eq('a Melee name is one player across Melee events, and only hashed',
  (select count(distinct player)::text || ' ' || bool_and(player ~ '^[0-9a-f]{64}$')::text from t1_private.meta_decks), '32 true');
select pg_temp.throws('an unknown source', $$select public.meta_ingest('{"source": "cardsrealm", "source_id": "x", "format": "modern", "on": "2026-10-01"}')$$, '22023');

-- An MTGO top-32 record for the same deck: the paper record wins.
select public.meta_ingest(jsonb_build_object('source', 'mtgo', 'source_id', 'C1', 'format', 'modern', 'name', 'Modern Challenge 32',
  'kind', 'challenge', 'on', (current_date - 3)::text, 'players', 40,
  'decks', jsonb_build_array(jsonb_build_object('player', '1', 'rank', 1, 'wins', 7, 'losses', 0, 'top8', true,
    'main', '[["Lightning Bolt", 4], ["Lava Spike", 4], ["Mountain", 52]]'::jsonb, 'side', '[]'::jsonb))));
select archetype_id as "RED" from t1_private.meta_decks where player like '%' and main @> array[md5('Lava Spike')::uuid] limit 1 \gset
select 'topdeck ' || sum(wins) || '-' || sum(losses) as "PAPER" from t1_private.meta_decks d join t1_private.meta_events e on e.id = d.event_id
 where e.source = 'melee' and d.archetype_id = :RED \gset
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.eq('an archetype''s record comes from paper events (Melee) when there are any, not MTGO''s 7-0',
  (select (a->'record'->>'basis') || ' ' || (a->'record'->>'wins') || '-' || (a->'record'->>'losses')
     from (select public.meta_archetype('modern', :RED, 'all', 30) a) x), :'PAPER');
reset role;

-- Spice ------------------------------------------------------------------------------------------------------------
select t1_private.spice_refresh(current_date);
select pg_temp.eq('spice counts the Melee lists',
  (select n || ' ' || mtgo || ' ' || topdeck || ' ' || melee from t1_private.spice_lists where format = 'modern' and days = 90 and archetype_id = -1),
  '65 1 0 64');
select pg_temp.eq('a deck''s spice names Melee among its sources',
  (select (s->'basis'->'sources')::text from (select t1_private.spice_deck('modern', 0, array[md5('Counterspell')::uuid, md5('Lightning Bolt')::uuid],
     array[4, 4], '{}', '{}') s) x), '["mtgo", "melee"]');
