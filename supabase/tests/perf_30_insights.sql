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
analyze;

select pg_temp.eq('36,000 decks', (select count(*)::text from t1_private.meta_decks), '36000');
select pg_temp.ms('relabel a year of Modern', $$select public.meta_relabel('modern')$$, 9000, 1);
select pg_temp.eq('every deck labelled', (select count(*)::text from t1_private.meta_decks where archetype_id = 0), '0');
select pg_temp.ms('relabel only Other (each build)', $$select public.meta_relabel('modern', true)$$, 500, 1);
select pg_temp.ms('pack window: 90 days, all events', $$select public.meta_pack_window('modern', 'all', 90)$$, 800);
select pg_temp.ms('pack window: 30 days, big events', $$select public.meta_pack_window('modern', 'big', 30)$$, 250);
select pg_temp.ms('pack series: 180 days', $$select public.meta_pack_series('modern', 'all')$$, 4200);
select pg_temp.ms('pack bans: one study', $$select public.meta_pack_bans('modern')$$, 1400, 1);
select pg_temp.ms('pack matchups', $$select public.meta_pack_matchups('modern')$$, 50);
select pg_temp.ms('pack base', $$select public.meta_pack_base('modern')$$, 50);
select pg_temp.ms('ingest a 32-deck event', $$select public.meta_ingest(jsonb_build_object('source', 'mtgo', 'source_id', 'new', 'format', 'modern',
  'name', 'Modern Challenge 32', 'kind', 'challenge', 'on', current_date::text, 'players', 40,
  'decks', (select jsonb_agg(jsonb_build_object('player', g, 'main', (select jsonb_agg(jsonb_build_array('Card ' || (g + k), 4)) from generate_series(1, 15) k)))
              from generate_series(1, 32) g)))$$, 150);

set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.ms('archetype page (a viewer''s tap)', $$select public.meta_archetype('modern', (select 1 + 0), 'all', 30)$$, 100);
select pg_temp.ms('card page (a viewer''s tap)', $$select public.meta_card('modern', md5('c40')::uuid, 'all')$$, 200);
reset role;
