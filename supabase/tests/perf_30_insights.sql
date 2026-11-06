-- Insights (20261025120000_insights) at a year of Modern: 36,000 decks (about what 12 months of Challenges and
-- Leagues publish), 400 cards, 25 archetypes. Run with `T1_PERF=1 supabase/tests/run.sh perf_`. Budgets are ~5x
-- local, as in perf_10_library.sql; the pack builds run in the worker, not on a viewer's tap, except the two pages.
\ir _helpers.sql
set client_min_messages = notice;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com');
insert into public.card_oracles (oracle_id, name, name_norm, layout, type_line, colors, legalities, source_card_id, source_rank, content_hash)
select md5('c' || g)::uuid, 'Card ' || g, 'card ' || g, 'normal', case when g % 5 = 0 then 'Land' else 'Instant' end,
       array[(array['W', 'U', 'B', 'R', 'G'])[g % 5 + 1]], '{"modern": "legal"}', md5('s' || g)::uuid, 'a', 'h'
  from generate_series(1, 400) g;
insert into public.card_names (name_norm, oracle_id) select name_norm, oracle_id from public.card_oracles;
insert into t1_private.meta_archetypes (format, name, family, status, rule, priority, source)
select 'modern', 'Deck ' || a, 'midrange', 'approved', jsonb_build_object('main', jsonb_build_array('Card ' || a)), a, 'seed'
  from generate_series(1, 25) a;

insert into t1_private.meta_events (id, source, source_id, format, name, kind, on_date, players, tier)
select e, 'mtgo', 'p' || e, 'modern', 'Modern Challenge 32', 'challenge', current_date - (e % 365), 40 + (e % 100),
       t1_private.meta_tier('challenge', 40 + (e % 100))
  from generate_series(1, 1125) e;
select setval(pg_get_serial_sequence('t1_private.meta_events', 'id'), 1125);
-- 32 decks an event, each built around one archetype's key card plus 34 cards from the pool
insert into t1_private.meta_decks (event_id, format, on_date, tier, weight, player, rank, wins, losses, top8, main, main_qty, side, side_qty, archetype_id)
select e.id, 'modern', e.on_date, e.tier, t.weight * case when r <= 8 then 2 else 1 end, md5(e.id || '-' || r), r, 7 - r % 5, r % 5, r <= 8,
       array(select md5('c' || x)::uuid from (select (((e.id * 7 + r * 13 + k * 31) % 375) + 26) x from generate_series(1, 34) k
                                              union select ((e.id + r) % 25) + 1) xs order by 1),
       array(select 4::smallint from generate_series(1, 35)),
       array(select md5('c' || (((e.id + r * 3 + k * 17) % 375) + 26))::uuid from generate_series(1, 6) k),
       array(select 2::smallint from generate_series(1, 6)),
       0
  from t1_private.meta_events e join t1_private.meta_tiers t on t.tier = e.tier
  cross join generate_series(1, 32) r;
update t1_private.meta_decks set main_qty = array_fill(4::smallint, array[cardinality(main)]), side_qty = array_fill(2::smallint, array[cardinality(side)]);
insert into t1_private.meta_format_changes (format, on_date, kind, cards, status) values ('modern', current_date - 100, 'ban', '{Card 3}', 'confirmed');
-- a top 8 bracket per event (1v8 2v7 3v6 4v5, 1v4 2v3, 1v2): what Meta now's win rates and the matchup grid read
insert into t1_private.meta_matches (event_id, round, a, b, result)
select d.event_id, m.round, d.id, o.id, case when (d.event_id + m.ra) % 3 = 0 then 'b' else 'a' end
  from (values ('QF1', 1, 8), ('QF2', 2, 7), ('QF3', 3, 6), ('QF4', 4, 5), ('SF1', 1, 4), ('SF2', 2, 3), ('F', 1, 2)) m(round, ra, rb)
  join t1_private.meta_decks d on d.rank = m.ra join t1_private.meta_decks o on o.event_id = d.event_id and o.rank = m.rb;
analyze;

select pg_temp.eq('36,000 decks', (select count(*)::text from t1_private.meta_decks), '36000');
select pg_temp.ms('relabel a year of Modern', $$select public.meta_relabel('modern')$$, 9000, 1);
select pg_temp.eq('every deck labelled', (select count(*)::text from t1_private.meta_decks where archetype_id = 0), '0');
select pg_temp.ms('relabel only Other (each build)', $$select public.meta_relabel('modern', true)$$, 500, 1);
-- Live Standard had 21,000 decks in Other: meta_label called once a deck took 4.7 s there and the build's relabel
-- passed the 8 s statement timeout (bug #23, 20261030070000_fix_meta_relabel_inline)
update t1_private.meta_decks set archetype_id = 0 where id % 3 <> 0;
select pg_temp.ms('relabel 24,000 decks in Other', $$select public.meta_relabel('modern', true)$$, 1500, 1);
select pg_temp.eq('every deck labelled again', (select count(*)::text from t1_private.meta_decks where archetype_id = 0), '0');
select pg_temp.ms('pack window: 90 days, all events', $$select public.meta_pack_window('modern', 'all', 90)$$, 800);
select pg_temp.ms('pack window: 30 days, big events', $$select public.meta_pack_window('modern', 'big', 30)$$, 250);
-- 4.2 s before 20261030090000 summed each day once (per-line, per-day subqueries)
select pg_temp.ms('pack series: 180 days', $$select public.meta_pack_series('modern', 'all')$$, 400);
select pg_temp.ms('pack bans: one study', $$select public.meta_pack_bans('modern')$$, 1400, 1);
select pg_temp.ms('pack matchups', $$select public.meta_pack_matchups('modern')$$, 50);
select pg_temp.ms('pack base', $$select public.meta_pack_base('modern')$$, 50);
-- Your decks first (20261030100000): the usual lists once a day (~280 ms on live Modern), then each signed-in call
select pg_temp.ms('insights mine: usual lists, first call of the day', $$select t1_private.meta_cores_for('modern')$$, 3000, 1);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
select pg_temp.ms('insights mine: a signed-in call', $$select public.insights_mine('modern')$$, 100);
select pg_temp.as_user(null);
select pg_temp.ms('ingest a 32-deck event', $$select public.meta_ingest(jsonb_build_object('source', 'mtgo', 'source_id', 'new', 'format', 'modern',
  'name', 'Modern Challenge 32', 'kind', 'challenge', 'on', current_date::text, 'players', 40,
  'decks', (select jsonb_agg(jsonb_build_object('player', g, 'main', (select jsonb_agg(jsonb_build_array('Card ' || (g + k), 4)) from generate_series(1, 15) k)))
              from generate_series(1, 32) g)))$$, 150);
-- a Regional Championship from Melee: 1,500 players, 75 lines each, every round (the per-deck card gathering was
-- quadratic and timed out from ~1,000 players, 20261030020000_meta_ingest_big_events)
select pg_temp.ms('ingest a 1,500-player paper event', $$select public.meta_ingest(jsonb_build_object('source', 'melee', 'source_id', 'rc', 'format', 'modern',
  'name', 'Regional Championship', 'kind', 'championship', 'on', current_date::text, 'players', 1500,
  'decks', (select jsonb_agg(jsonb_build_object('player', 'P' || g, 'rank', g, 'wins', 5, 'losses', 3,
              'main', (select jsonb_agg(jsonb_build_array('Card ' || ((g + k * 7) % 400 + 1), 4)) from generate_series(1, 15) k),
              'side', (select jsonb_agg(jsonb_build_array('Card ' || ((g * 3 + k) % 400 + 1), 1)) from generate_series(1, 15) k)))
              from generate_series(1, 1500) g),
  'matches', (select jsonb_agg(jsonb_build_object('round', 'Round ' || r, 'a', 'P' || g, 'b', 'P' || (g + 1), 'result', 'a'))
                from generate_series(1, 9) r, generate_series(1, 1499, 2) g)))$$, 3000, 1);

-- card search reads the daily counts (spice_refresh, 04:40 UTC)
select t1_private.spice_refresh() > 0 as counted \gset
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.ms('archetype page (a viewer''s tap)', $$select public.meta_archetype('modern', (select 1 + 0), 'all', 30)$$, 100);
select pg_temp.ms('card page (a viewer''s tap)', $$select public.meta_card('modern', md5('c40')::uuid, 'all')$$, 200);
-- 20261106140000: a year of weeks, the window, every archetype and the ten best lists
select pg_temp.ms('card page, 90 days', $$select public.meta_card('modern', md5('c40')::uuid, 'all', 90)$$, 300);
select pg_temp.ms('card search (each keystroke)', $$select public.meta_card_search('modern', 'card 4')$$, 50);
reset role;

-- Spice (contract/spice-2026-10-28.md): a 60-card deck against that year of Modern. The archetype path is what most
-- decks take; Other tries every archetype first (the closest), the slowest path. list_spice caches per seq and day.
select pg_temp.ms('spice: daily counts for a year of Modern', $$select t1_private.spice_refresh()$$, 3000, 1);
select array(select md5('c' || (26 + k * 11))::uuid from generate_series(1, 15) k) || md5('c7')::uuid spice_main \gset
select archetype_id spice_arch from t1_private.meta_decks where on_date > current_date - 90 group by 1 order by count(*) desc limit 1 \gset
select pg_temp.ms('spice: deck in its archetype', format($$select t1_private.spice_deck('modern', %s, %L::uuid[],
  array_fill(4, array[16]), '{}', '{}')$$, :spice_arch, :'spice_main'), 15);
select pg_temp.ms('spice: Other, the closest archetype', format($$select t1_private.spice_deck('modern', 0, %L::uuid[],
  array_fill(4, array[16]), '{}', '{}')$$, :'spice_main'), 25);
-- A deck's similarity to its archetype (20261101140000_list_insight_similarity.sql): every list of the largest
-- archetype in 90 days, worked out on each open of the deck screen.
select pg_temp.ms('deck screen: similarity to the largest archetype', format($$select t1_private.meta_similarity('modern', %s,
  %L::uuid[], array_fill(4, array[16]))$$, :spice_arch, :'spice_main'), 30);

-- A Limited set at 17Lands' size (bug #15: FRA's pack took 10 s on live, past the 8 s statement timeout): five event
-- types, each a game run of ~7,000 sums (300 cards, 16 pairs, 12 weeks, both groups) and a draft run for ATA.
insert into t1_private.limited_runs (set_code, event_type, kind, uri, last_modified, total_bytes, status)
select 'PRF', e, k, 'https://x/' || e || k, now(), 1, 'done'
  from unnest(array['PremierDraft', 'TradDraft', 'PickTwoDraft', 'Sealed', 'TradSealed']) e cross join unnest(array['game', 'draft']) k;
insert into t1_private.limited_acc (run_id, k, g, w)
select r.id, x.k, x.g, x.g / 2
  from t1_private.limited_runs r cross join lateral (
    select 'T|' || grp k, 100000 g from unnest(array['a', 't']) grp
    union all select t || '|' || grp, 50000 from unnest(array['P', 'D', 'M', 'K', 'N', 'MP']) t, unnest(array['a', 't']) grp
    union all select t || '|' || p || '|' || grp, 5000 from unnest(array['p', 'pp', 'ps']) t, unnest(array['WU', 'WB', 'WR', 'WG', 'UB', 'UR', 'UG', 'BR', 'BG', 'RG', 'WUB', 'UBR', 'BRG', 'RGW', 'GWU', 'WUBRG']) p, unnest(array['a', 't']) grp
    union all select 'pw|' || p || '|' || wk || '|' || grp, 500 from unnest(array['WU', 'WB', 'WR', 'WG', 'UB', 'UR', 'UG', 'BR', 'BG', 'RG', 'WUB', 'UBR', 'BRG', 'RGW', 'GWU', 'WUBRG']) p, generate_series(1, 12) wk, unnest(array['a', 't']) grp
    union all select 'dc|' || p || '||' || grp, 3000 from unnest(array['WU', 'WB', 'WR', 'WG', 'UB', 'UR', 'UG', 'BR', 'BG', 'RG']) p, unnest(array['a', 't']) grp
    union all select t || '|Card ' || c || '|' || grp, 1000 + c from unnest(array['cd', 'ch', 'co', 'cg', 'cn']) t, generate_series(1, 300) c, unnest(array['a', 't']) grp
    union all select 'cw|Card ' || c || '|' || wk, 300 from generate_series(1, 300) c, generate_series(1, 12) wk
    union all select 'cp|Card ' || c || '|' || p, 300 from generate_series(1, 300) c, unnest(array['WU', 'WB', 'WR', 'WG', 'UB', 'UR', 'UG', 'BR', 'BG', 'RG']) p
  ) x where r.set_code = 'PRF' and r.kind = 'game'
union all
select r.id, 'a|Card ' || c || '|' || grp, 1000, 5000 from t1_private.limited_runs r, generate_series(1, 300) c, unnest(array['a', 't']) grp
 where r.set_code = 'PRF' and r.kind = 'draft';
analyze t1_private.limited_acc;
select pg_temp.eq('a Limited pack: five events, 300 cards each, both groups',
  (select count(*)::text from jsonb_each(public.limited_pack_facts('PRF')->'events') e, jsonb_array_elements(e.value->'groups'->'all'->'cards')), '1500');
select pg_temp.ms('Limited pack facts (one set, five events)', $$select public.limited_pack_facts('PRF')$$, 1500, 1);
