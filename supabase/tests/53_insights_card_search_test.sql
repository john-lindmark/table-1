-- Insights card search and the card page (20261106140000_insights_card_search, contract/insights-2026-10-24.md
-- § Card search): only cards played in the format are found, best names first; the page covers a year of weeks,
-- the picked window, every archetype playing it and its best lists.
\ir _helpers.sql

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''

create function pg_temp.card(p_name text, p_type text, p_colors text[]) returns uuid language sql as $$
  insert into public.card_oracles (oracle_id, name, name_norm, layout, type_line, colors, legalities, source_card_id, source_rank, content_hash)
  values (md5(p_name)::uuid, p_name, public.card_name_norm(p_name), 'normal', p_type, p_colors, '{"modern": "legal"}', md5('s' || p_name)::uuid, 'a', 'h')
  returning oracle_id;
$$;
select pg_temp.card('Lightning Bolt', 'Instant', '{R}'), pg_temp.card('Boltwave', 'Sorcery', '{R}'),
       pg_temp.card('Bolt Bend', 'Instant', '{R}'), pg_temp.card('Blood Moon', 'Enchantment', '{R}'),
       pg_temp.card('Mountain', 'Basic Land — Mountain', '{}'), pg_temp.card('Counterspell', 'Instant', '{U}'),
       pg_temp.card('Island', 'Basic Land — Island', '{}');
insert into public.card_names (name_norm, oracle_id) select name_norm, oracle_id from public.card_oracles;

create function pg_temp.event(p_id text, p_on date, p_players int) returns jsonb language sql as $$
  select jsonb_build_object('source', 'mtgo', 'source_id', p_id, 'format', 'modern', 'name', 'Modern Challenge ' || p_id, 'kind', 'challenge',
    'on', p_on::text, 'players', p_players, 'url', 'https://www.mtgo.com/decklist/' || p_id, 'complete', true,
    'decks', jsonb_build_array(
      jsonb_build_object('player', '1', 'rank', 1, 'wins', 6, 'losses', 1, 'top8', true,
        'main', '[["Boltwave", 4], ["Lightning Bolt", 4], ["Mountain", 20]]'::jsonb, 'side', '[["Blood Moon", 3]]'::jsonb),
      jsonb_build_object('player', '2', 'rank', 2, 'wins', 5, 'losses', 2, 'top8', true,
        'main', '[["Counterspell", 4], ["Lightning Bolt", 2], ["Island", 20]]'::jsonb, 'side', '[["Lightning Bolt", 1]]'::jsonb),
      jsonb_build_object('player', '3', 'rank', 9, 'wins', 4, 'losses', 3, 'top8', false,
        'main', '[["Counterspell", 4], ["Island", 24]]'::jsonb, 'side', '[]'::jsonb)));
$$;
select public.meta_ingest(pg_temp.event('A', current_date - 3, 140));   -- major
select public.meta_ingest(pg_temp.event('B', current_date - 10, 40));   -- regular
select public.meta_ingest(pg_temp.event('C', current_date - 200, 40));  -- outside 90 days, inside the year
select t1_private.spice_refresh() > 0 as counted \gset

select pg_temp.throws('signed out: search', $$select public.meta_card_search('modern', 'bolt')$$, '28000');
select pg_temp.as_user(:ANA);

-- Search -----------------------------------------------------------------------------
select pg_temp.eq('only played cards; a word starting with the query ranks with a name starting with it, by play',
  (select string_agg(x->>'n', ', ' order by o) from jsonb_array_elements(public.meta_card_search('modern', 'bolt')) with ordinality r(x, o)),
  'Lightning Bolt, Boltwave');
select pg_temp.eq('an exact name first, then by play',
  (select string_agg(x->>'n', ', ' order by o) from jsonb_array_elements(public.meta_card_search('modern', 'boltwave')) with ordinality r(x, o)), 'Boltwave');
select pg_temp.eq('basics are left out before the limit (Mountain and Counterspell both hold "un")',
  (select string_agg(x->>'n', ', ') from jsonb_array_elements(public.meta_card_search('modern', 'un', 1)) x), 'Counterspell');
select pg_temp.eq('shares of the last 90 days'' lists, main and side; lists in the year',
  (select (x->>'main') || ' ' || (x->>'side') || ' ' || (x->>'year') from jsonb_array_elements(public.meta_card_search('modern', 'lightning')) x),
  '0.6667 0.3333 6');
select pg_temp.eq('accents and case', (public.meta_card_search('modern', 'LIGHTNÍNG bolt'))->0->>'n', 'Lightning Bolt');
select pg_temp.eq('a typo still finds it', (public.meta_card_search('modern', 'lightning blot'))->0->>'n', 'Lightning Bolt');
select pg_temp.eq('basic lands are left out', public.meta_card_search('modern', 'mountain')::text, '[]');
select pg_temp.eq('one letter finds nothing', public.meta_card_search('modern', 'b')::text, '[]');
select pg_temp.eq('another format has none of them', public.meta_card_search('pauper', 'bolt')::text, '[]');
select pg_temp.eq('the limit', jsonb_array_length(public.meta_card_search('modern', 'o', 1))::text, '0');
select pg_temp.eq('the limit holds', jsonb_array_length(public.meta_card_search('modern', 'bolt', 1))::text, '1');
select pg_temp.throws('unknown format', $$select public.meta_card_search('edh', 'bolt')$$, '22023');

-- Card page --------------------------------------------------------------------------
select pg_temp.eq('a year of weeks; weighted share in event C''s week and this week',
  (select (c->'series'->>'weeks') || ' ' || jsonb_array_length(c->'series'->'main') || ' ' ||
          (c->'series'->'main'->>(51 - 200 / 7)) || ' ' || coalesce(c->'series'->'main'->>51, 'null')
     from (select public.meta_card('modern', md5('Lightning Bolt')::uuid) c) x),
  '52 52 0.8000 0.8000');
select pg_temp.eq('the window: lists with it of all lists, copies main and side',
  (select (w->>'days') || ' ' || (w->>'decks') || '/' || (w->>'of') || ' ' || (w->>'copies') || ' ' || (w->>'side_copies')
     from (select public.meta_card('modern', md5('Lightning Bolt')::uuid, 'all', 30)->'window' w) x),
  '30 4/6 3.00 1.00');
select pg_temp.eq('big events only',
  (select (w->>'decks') || '/' || (w->>'of') from (select public.meta_card('modern', md5('Lightning Bolt')::uuid, 'big', 30)->'window' w) x), '2/3');
select pg_temp.eq('every archetype playing it, with its own count',
  (select count(*)::text || ' ' || sum((b->>'decks')::int) from jsonb_array_elements(public.meta_card('modern', md5('Lightning Bolt')::uuid)->'by_archetype') b),
  (select count(distinct archetype_id)::text || ' 4' from t1_private.meta_decks
    where on_date > current_date - 30 and main @> array[md5('Lightning Bolt')::uuid]));
select pg_temp.eq('best lists first, with the archetype and its copies',
  (select string_agg((f->>'rank') || '@' || (f->>'players') || ' ' || (f->'qty')::text, '; ')
     from jsonb_array_elements(public.meta_card('modern', md5('Lightning Bolt')::uuid)->'finishes') f),
  '1@140 [4, 0]; 2@140 [2, 1]; 1@40 [4, 0]; 2@40 [2, 1]');
select pg_temp.eq('a list reads lands last',
  (select f->'main'->-1->>0 from (select public.meta_card('modern', md5('Lightning Bolt')::uuid)->'finishes'->0 f) x), 'Mountain');
select pg_temp.eq('a year window reaches event C',
  ((public.meta_card('modern', md5('Lightning Bolt')::uuid, 'all', 365))->'window'->>'decks'), '6');
select pg_temp.eq('an odd window reads 30 days', ((public.meta_card('modern', md5('Lightning Bolt')::uuid, 'all', 11))->'window'->>'days'), '30');
select pg_temp.eq('first and last seen',
  (select (c->>'first_seen') || ' ' || (c->>'last_seen') from (select public.meta_card('modern', md5('Lightning Bolt')::uuid) c) x),
  (current_date - 200)::text || ' ' || (current_date - 3)::text);
select pg_temp.eq('old builds call with three arguments',
  (select jsonb_array_length(c->'by_archetype')::text from (select public.meta_card('modern', md5('Blood Moon')::uuid, 'all') c) x), '1');
select pg_temp.eq('a card never played: no lists',
  (select jsonb_array_length(c->'finishes') || ' ' || coalesce(c->>'last_seen', 'null') from (select public.meta_card('modern', md5('Bolt Bend')::uuid) c) x),
  '0 null');
select pg_temp.throws('a bad tier', $$select public.meta_card('modern', md5('Lightning Bolt')::uuid, 'huge')$$, '22023');

set role anon;
select pg_temp.throws('anon can''t search', $$select public.meta_card_search('modern', 'bolt')$$, '42501');
select pg_temp.throws('anon can''t open a card page', $$select public.meta_card('modern', md5('Lightning Bolt')::uuid)$$, '42501');
