-- Insights (contract/insights-2026-10-24.md): ingest, archetype labels, pack facts, ban studies, review, read RPCs,
-- permissions, the legality diff and 17Lands runs.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''

-- A small catalog: names → Oracle ids, types and colours as Scryfall gives them.
create function pg_temp.card(p_name text, p_type text, p_colors text[], p_faces text[] default '{}') returns uuid language sql as $$
  insert into public.card_oracles (oracle_id, name, name_norm, face_names, layout, type_line, colors, legalities, source_card_id, source_rank, content_hash)
  values (md5(p_name)::uuid, p_name, public.card_name_norm(p_name), p_faces, 'normal', p_type, p_colors, '{"modern": "legal"}', md5('s' || p_name)::uuid, 'a', 'h')
  returning oracle_id;
$$;
select pg_temp.card('Lightning Bolt', 'Instant', '{R}'), pg_temp.card('Lava Spike', 'Sorcery — Arcane', '{R}'),
       pg_temp.card('Boltwave', 'Sorcery', '{R}'), pg_temp.card('Blood Moon', 'Enchantment', '{R}'),
       pg_temp.card('Mountain', 'Basic Land — Mountain', '{}'), pg_temp.card('Plains', 'Basic Land — Plains', '{}'),
       pg_temp.card('Island', 'Basic Land — Island', '{}'), pg_temp.card('Sacred Foundry', 'Land — Mountain Plains', '{}'),
       pg_temp.card('Ocelot Pride', 'Creature — Cat', '{W}'), pg_temp.card('Guide of Souls', 'Creature — Human', '{W}'),
       pg_temp.card('Counterspell', 'Instant', '{U}'), pg_temp.card('Fire // Ice', 'Instant // Instant', '{R,U}', '{Fire,Ice}');
insert into public.card_names (name_norm, oracle_id, is_face)
select distinct on (v.nm, o.oracle_id) v.nm, o.oracle_id, v.f from public.card_oracles o,
  lateral (select o.name_norm nm, false f union all select public.card_name_norm(x), true from unnest(o.face_names) x) v
 order by v.nm, o.oracle_id, v.f on conflict do nothing;

-- Helpers ----------------------------------------------------------------------------
select pg_temp.eq('league is small', t1_private.meta_tier('league', null), 'small');
select pg_temp.eq('68 players is large', t1_private.meta_tier('challenge', 68), 'large');
select pg_temp.eq('40 players is regular', t1_private.meta_tier('challenge', 40), 'regular');
select pg_temp.eq('a showcase is major at any size', t1_private.meta_tier('showcase', 20), 'major');
select pg_temp.eq('128+ is major', t1_private.meta_tier('challenge', 140), 'major');
select pg_temp.eq('a split card by its full name', t1_private.meta_card_id('Fire // Ice')::text, md5('Fire // Ice')::uuid::text);
select pg_temp.eq('a split card by its front face', t1_private.meta_card_id('Fire')::text, md5('Fire // Ice')::uuid::text);
select pg_temp.eq('accents and case', t1_private.meta_card_id('LIGHTNING bolt')::text, md5('Lightning Bolt')::uuid::text);
select pg_temp.eq('unknown name', t1_private.meta_card_id('No Such Card')::text, null);

-- The seeded Modern rules compiled while the catalog was empty; relabelling recompiles them.
select public.meta_relabel('modern');
select pg_temp.eq('Burn compiles; its missing "any" cards are only listed', (select blocked::text || ' ' || (select string_agg(m, ',' order by m) from unnest(missing) m) from t1_private.meta_archetypes where format = 'modern' and name = 'Burn'), 'false Rift Bolt,Skewer the Critics');
select pg_temp.eq('a rule missing a main card is blocked', (select blocked::text from t1_private.meta_archetypes where format = 'modern' and name = 'Amulet Titan'), 'true');
select id as "BURN" from t1_private.meta_archetypes where format = 'modern' and name = 'Burn' \gset
select id as "BOROS" from t1_private.meta_archetypes where format = 'modern' and name = 'Boros Energy' \gset

-- Ingest -----------------------------------------------------------------------------
create function pg_temp.challenge(p_id text, p_on date) returns jsonb language sql as $$
  select jsonb_build_object('source', 'mtgo', 'source_id', p_id, 'format', 'modern', 'name', 'Modern Challenge 64', 'kind', 'challenge',
    'on', p_on::text, 'players', 70, 'url', 'https://www.mtgo.com/decklist/x', 'complete', false,
    'decks', jsonb_build_array(
      jsonb_build_object('player', '101', 'rank', 1, 'wins', 6, 'losses', 1, 'top8', true,
        'main', '[["Lava Spike", 4], ["Boltwave", 4], ["Lightning Bolt", 4], ["Blood Moon", 2], ["Mountain", 18], ["Unknown Card", 2]]'::jsonb,
        'side', '[["Blood Moon", 2]]'::jsonb),
      jsonb_build_object('player', '102', 'rank', 2, 'wins', 5, 'losses', 2, 'top8', true,
        'main', '[["Ocelot Pride", 4], ["Guide of Souls", 4], ["Lightning Bolt", 4], ["Sacred Foundry", 4], ["Plains", 8]]'::jsonb, 'side', '[]'::jsonb),
      jsonb_build_object('player', '103', 'rank', 9, 'wins', 4, 'losses', 3, 'top8', false,
        'main', '[["Counterspell", 4], ["Fire // Ice", 4], ["Island", 20]]'::jsonb, 'side', '[]'::jsonb)),
    'matches', '[{"round": "F", "a": "101", "b": "102", "a_wins": 2, "b_wins": 1, "result": "a"}, {"round": "F", "a": "101", "b": "999", "result": "a"}]'::jsonb);
$$;
select pg_temp.eq('an event is stored with its decks',
  (select (r->>'decks') || ' ' || (r->>'tier') || ' ' || (r->>'unmatched') from (select public.meta_ingest(pg_temp.challenge('E1', current_date - 3)) r) x),
  '3 large 1');
select pg_temp.eq('reading it again replaces it', (public.meta_ingest(pg_temp.challenge('E1', current_date - 3)))->>'decks', '3');
select pg_temp.eq('still one event', (select count(*)::text from t1_private.meta_events), '1');
select pg_temp.eq('still three decks', (select count(*)::text from t1_private.meta_decks), '3');
select pg_temp.eq('an unknown card is counted, not stored', (select seen::text from t1_private.meta_unmatched where name = 'Unknown Card'), '2');
select pg_temp.eq('labels: Burn, Boros Energy, Other',
  (select string_agg(coalesce(a.name, 'Other'), ', ' order by d.rank) from t1_private.meta_decks d left join t1_private.meta_archetypes a on a.id = d.archetype_id),
  'Burn, Boros Energy, Other');
select pg_temp.eq('colours from nonland cards with 4+ copies', (select string_agg(colors, ' ' order by rank) from t1_private.meta_decks), 'R WR UR');
select pg_temp.eq('weights: large ×2, top 8 ×2', (select string_agg(weight::text, ' ' order by rank) from t1_private.meta_decks), '4 4 2');
select pg_temp.eq('no player names or ids are stored',
  (select count(*)::text from t1_private.meta_decks where player in ('101', '102', '103') or length(player) <> 64), '0');
select pg_temp.eq('the final, tied to its decks; a player with no deck dropped',
  (select count(*)::text || ' ' || min(result) from t1_private.meta_matches), '1 a');
select pg_temp.throws('an unknown format', $$select public.meta_ingest('{"source": "mtgo", "source_id": "x", "format": "edh", "on": "2026-10-01"}')$$, '22023');
select pg_temp.throws('no id', $$select public.meta_ingest('{"source": "mtgo", "format": "modern", "on": "2026-10-01"}')$$, '22023');
select public.meta_ingest(jsonb_build_object('source', 'mtgo', 'source_id', 'L1', 'format', 'modern', 'name', 'Modern League', 'kind', 'league',
  'on', (current_date - 2)::text, 'decks', jsonb_build_array(jsonb_build_object('player', '104',
    'main', '[["Lava Spike", 4], ["Boltwave", 4], ["Mountain", 20]]'::jsonb, 'side', '[]'::jsonb))));

-- Pack facts ---------------------------------------------------------------------------
select pg_temp.eq('7 days, all events: shares weighted (Burn 4 + 0.5 of 10.5)',
  (select string_agg(coalesce(a.name, 'Other') || ' ' || (s->>'share'), ', ' order by (s->>'share')::numeric desc, a.name)
     from jsonb_array_elements((public.meta_pack_window('modern', 'all', 7))->'share') s
     left join t1_private.meta_archetypes a on a.id = (s->>'a')::int),
  'Burn 0.4286, Boros Energy 0.3810, Other 0.1905');
select pg_temp.eq('big events leave out the league',
  (select (w->>'decks') || ' ' || (w->>'weighted') || ' ' || (w->>'events') || ' ' || (w->>'thin') from (select public.meta_pack_window('modern', 'big', 7) w) x),
  '3 10.0 1 true');
select pg_temp.eq('an archetype missing from the window before reads 0, not null',
  (select (s->>'prev') from jsonb_array_elements((public.meta_pack_window('modern', 'all', 7))->'share') s where (s->>'a')::int = :BURN), null);
select pg_temp.eq('rising cards: no lands, no basics; Bolt in 8 of 10.5',
  (select string_agg((c->>'n') || ' ' || (c->>'rate'), ', ' order by (c->>'rate')::numeric desc, c->>'n')
     from jsonb_array_elements((public.meta_pack_window('modern', 'all', 7))->'cards'->'main'->'up') c),
  'Lightning Bolt 0.7619, Boltwave 0.4286, Lava Spike 0.4286, Blood Moon 0.3810, Guide of Souls 0.3810, Ocelot Pride 0.3810, Counterspell 0.1905, Fire // Ice 0.1905');
select pg_temp.eq('series: 180 days, the top archetypes, null before any deck',
  (select (s->>'days') || ' ' || jsonb_array_length(s->'lines') || ' ' || coalesce((s->'other'->>0), 'null') from (select public.meta_pack_series('modern', 'all') s) x),
  '180 3 null');
select pg_temp.eq('series: last day is the 7-day share',
  (select (l->'v'->>179) from jsonb_array_elements((public.meta_pack_series('modern', 'all'))->'lines') l where (l->>'a')::int = :BURN), '0.4286');
select pg_temp.eq('matchups: named archetypes only, oriented by position',
  ((public.meta_pack_matchups('modern'))->'cells')::text, jsonb_build_array(jsonb_build_array(:BURN, :BOROS, 1, 0, 0))::text);
select pg_temp.eq('base: Other first, then the approved archetypes; thin big events open on all',
  (select (b->'archetypes'->0->>'name') || ' ' || (b->>'default_tier') || ' ' || jsonb_array_length(b->'events') from (select public.meta_pack_base('modern') b) x),
  'Other all 1');
select pg_temp.eq('base: an event lists its top 8 and winner',
  (select ((b->'events'->0->>'winner')::int = :BURN)::text || ' ' || jsonb_array_length(b->'events'->0->'top8') from (select public.meta_pack_base('modern') b) x),
  'true 2');

-- Ban study: Lava Spike banned yesterday; Burn held it in every list before.
insert into t1_private.meta_format_changes (format, on_date, kind, cards, status) values ('modern', current_date - 1, 'ban', '{Lava Spike}', 'confirmed');
select pg_temp.eq('ban study: Burn is the loser',
  (select ((b->'losers'->0->>'a')::int = :BURN)::text || ' ' || (b->'losers'->0->>'before') || ' ' || (b->'losers'->0->>'after')
     from jsonb_array_elements(public.meta_pack_bans('modern')) b where b->>'on' = (current_date - 1)::text), 'true 0.4286 0.0000');
select pg_temp.eq('ban study: nobody gained', (select (b->'gainers')::text from jsonb_array_elements(public.meta_pack_bans('modern')) b where b->>'on' = (current_date - 1)::text), '[]');
select pg_temp.eq('ban study: no window has ended yet', (select (b->'after')::text from jsonb_array_elements(public.meta_pack_bans('modern')) b where b->>'on' = (current_date - 1)::text), '{}');
select pg_temp.eq('the seeded Modern changes of May 18 are studied too', (select count(*)::text from jsonb_array_elements(public.meta_pack_bans('modern')) b where b->>'on' = '2026-05-18'), '2');
insert into t1_private.meta_format_changes (format, on_date, kind, cards, status) values ('modern', current_date - 1, 'unban', '{Blood Moon}', 'proposed');
select pg_temp.eq('a proposed change isn''t studied', jsonb_array_length(public.meta_pack_bans('modern'))::text, '3');

-- Review -------------------------------------------------------------------------------
select pg_temp.eq('a proposal', (public.meta_archetype_propose('modern', 'Blue Tempo', 'midrange', 'U', '{"main": ["Counterspell"]}', '{Counterspell}', 9) is not null)::text, 'true');
select pg_temp.eq('the same name again is ignored', (public.meta_archetype_propose('modern', 'Blue Tempo', 'midrange', 'U', '{"main": ["Counterspell"]}', '{Counterspell}', 9))::text, null);
select id as "BLUE" from t1_private.meta_archetypes where name = 'Blue Tempo' \gset
select id as "CHANGE" from t1_private.meta_format_changes where status = 'proposed' \gset
select pg_temp.eq('a proposal labels nothing', (select count(*)::text from t1_private.meta_decks where archetype_id = (select id from t1_private.meta_archetypes where name = 'Blue Tempo')), '0');
set role authenticated;
select pg_temp.as_user(:BEN);
select pg_temp.throws('review is for moderators', $$select public.insights_review()$$, '42501');
select pg_temp.throws('approving is for moderators', $$select public.insights_review_archetype(1, 'approve')$$, '42501');
reset role;
insert into t1_private.moderators (user_id) values (:ANA);
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('review lists proposals, changes and unknown names',
  (select jsonb_array_length(r->'archetypes') || ' ' || jsonb_array_length(r->'changes') || ' ' || (r->'unmatched'->0->>'name') from (select public.insights_review() r) x),
  '1 1 Unknown Card');
select pg_temp.throws('a taken name', format('select public.insights_review_archetype(%s, %L, %L)', :BLUE, 'rename', 'Burn'), '23505');
select pg_temp.throws('an unknown family', format('select public.insights_review_archetype(%s, %L, null, %L)', :BLUE, 'rename', 'tempo'), '22023');
select pg_temp.eq('approve with a new name',
  (public.insights_review_archetype(:BLUE, 'approve', 'Mono-Blue Tempo'))->>'status', 'approved');
reset role;
select pg_temp.eq('approving relabels the format',
  (select coalesce(a.name, 'Other') from t1_private.meta_decks d left join t1_private.meta_archetypes a on a.id = d.archetype_id where d.rank = 9), 'Mono-Blue Tempo');
select pg_temp.eq('audited', (select string_agg(action, ' ') from t1_private.insights_audit), 'archetype_approve');
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('confirm a change', (public.insights_review_change(:CHANGE, 'confirm'))->>'status', 'confirmed');
select pg_temp.throws('an unknown change', $$select public.insights_review_change(-1, 'confirm')$$, '22023');

-- Read RPCs -------------------------------------------------------------------------------
select pg_temp.eq('archetype page: decks, core, best finish first',
  (select (a->>'decks') || ' ' || (select string_agg(c->>'n', ', ' order by c->>'n') from jsonb_array_elements(a->'core') c) || ' ' || (a->'finishes'->0->>'rank')
     from (select public.meta_archetype('modern', :BURN, 'all', 30) a) x),
  '2 Blood Moon, Boltwave, Lava Spike, Lightning Bolt 1');
select pg_temp.eq('archetype record: top-32 finishers, leagues left out',
  (select (a->'record')::text from (select public.meta_archetype('modern', :BURN, 'all', 30) a) x),
  '{"wins": 6, "basis": "mtgo_top32", "draws": 0, "losses": 1}');
select pg_temp.eq('archetype matchups', (select (a->'matchups'->0->>'wins') || '-' || (a->'matchups'->0->>'losses') from (select public.meta_archetype('modern', :BURN) a) x), '1-0');
select pg_temp.eq('Other has a page', (public.meta_archetype('modern', 0))->'archetype'->>'name', 'Other');
select pg_temp.throws('unknown archetype', $$select public.meta_archetype('modern', -5)$$, '22023');
select pg_temp.throws('another format''s archetype', format('select public.meta_archetype(%L, %s)', 'pauper', :BURN), '22023');
select pg_temp.throws('a format that isn''t on', $$select public.meta_archetype('legacy', 0)$$, '22023');
select pg_temp.throws('a bad tier', $$select public.meta_archetype('modern', 0, 'huge')$$, '22023');
select pg_temp.eq('card page: 26 weeks, the archetypes playing it',
  (select jsonb_array_length(c->'series'->'main') || ' ' || jsonb_array_length(c->'by_archetype') || ' ' || (c->>'copies')
     from (select public.meta_card('modern', md5('Lightning Bolt')::uuid) c) x), '26 2 4.00');
select pg_temp.eq('index: nothing published yet', public.insights_index()::text, '[]');
select pg_temp.throws('workers only: ingest', $$select public.meta_ingest('{}')$$, '42501');
select pg_temp.throws('workers only: pack facts', $$select public.meta_pack_window('modern', 'all', 7)$$, '42501');
select pg_temp.throws('workers only: the TopDeck key', $$select public.meta_topdeck_key()$$, '42501');
-- The live API runs pg_safeupdate: an UPDATE or DELETE without a WHERE fails there (meta_state_put did, 2026-10-25),
-- though it passes here.
select pg_temp.eq('every update and delete in an Insights function has a WHERE',
  (select coalesce(string_agg(distinct p.proname, ', '), '') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     cross join lateral regexp_matches(p.prosrc, '(\m(?:update\s+[a-z0-9_.]+(?:\s+(?:as\s+)?[a-z]+)?\s+set|delete\s+from\s+[a-z0-9_.]+)[^;]*)', 'gi') m
    where n.nspname in ('public', 't1_private') and p.proname ~ '^(meta_|insight|limited_)' and m[1] !~* '\mwhere\M'), '');
select pg_temp.throws('workers only: limited runs', $$select public.limited_run_open('X', 'PremierDraft', 'game', 'u', now(), 1)$$, '42501');
select pg_temp.throws('no direct reads', $$select * from t1_private.meta_decks$$, '42501');
select pg_temp.as_user(null);
select pg_temp.throws('signed out', $$select public.meta_archetype('modern', 0)$$, '28000');
reset role;
set role anon;
select pg_temp.throws('anon can''t list packs', $$select public.insights_index()$$, '42501');
reset role;
select public.insight_pack_publish('constructed', 'modern', 'Modern', 3, 'c-1', 'insights/constructed/modern.json', 100, 'abc', current_date);
select public.insight_pack_publish('constructed', 'modern', 'Modern', 3, 'c-2', 'insights/constructed/modern.json', 120, 'def', current_date);
set role authenticated;
select pg_temp.as_user(:BEN);
select pg_temp.eq('index: one pack per key, the latest version',
  (select (i->>'version') || ' ' || (i->>'url') from jsonb_array_elements(public.insights_index()) i),
  'c-2 https://aaozhfcbvqrgkkrihkrd.supabase.co/storage/v1/object/public/catalog/insights/constructed/modern.json');
reset role;

-- Briefs ----------------------------------------------------------------------------------
select public.insight_brief_put('arch:modern:' || :BURN, 'h1', 'Burn leads.', 'claude-haiku-5-5');
select public.insight_brief_put('arch:modern:' || :BURN, 'h2', 'Burn still leads.', 'claude-haiku-5-5');
select pg_temp.eq('one brief per view', (public.insight_brief_get('arch:modern:' || :BURN))->>'facts_hash', 'h2');
select pg_temp.eq('the archetype page carries it', (public.meta_archetype('modern', :BURN))->>'brief', 'Burn still leads.');

-- Legality diff ---------------------------------------------------------------------------
update public.card_oracles set legalities = '{"modern": "banned"}' where name = 'Boltwave';
update public.card_oracles set content_hash = 'h2' where name = 'Opt';
select pg_temp.eq('a legality change is logged', (select before || '→' || after from t1_private.meta_legality_log), 'legal→banned');
select t1_private.meta_legality_propose();
select pg_temp.eq('and proposed as a ban', (select kind || ' ' || array_to_string(cards, ',') || ' ' || status from t1_private.meta_format_changes where kind = 'ban' and status = 'proposed'), 'ban Boltwave proposed');
select t1_private.meta_legality_propose();
select pg_temp.eq('proposed once', (select count(*)::text from t1_private.meta_format_changes where kind = 'ban' and status = 'proposed'), '1');
insert into public.mtg_sets (code, name, set_type, released_at) values ('tst', 'Test Set', 'expansion', current_date - 20);
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, released_at, content_hash)
values (md5('tst1')::uuid, md5('Lightning Bolt')::uuid, 'tst', '1', 'en', 'common', '{nonfoil}', 'normal', current_date - 20, 'h');
select t1_private.meta_legality_propose();
select pg_temp.eq('a set release with legal cards is a confirmed change', (select status from t1_private.meta_format_changes where kind = 'set_release' and set_code = 'tst' and format = 'modern'), 'confirmed');

-- 17Lands runs -----------------------------------------------------------------------------
\set LM '''2026-10-17 12:00:00+00'''
select pg_temp.eq('a new dump opens a run', (public.limited_run_open('tst', 'PremierDraft', 'game', 'https://x/game.csv.gz', :LM, 1000) is not null)::text, 'true');
select pg_temp.eq('the same dump again doesn''t', (public.limited_run_open('TST', 'PremierDraft', 'game', 'https://x/game.csv.gz', :LM, 1000))::text, null);
\set RUN '(select id from t1_private.limited_runs where set_code = ''TST'' and kind = ''game'')'
select pg_temp.eq('claiming a run', (public.limited_run_state(:RUN))->>'step', '0');
select pg_temp.eq('first slice', public.limited_step_commit(:RUN, 0, 800, 'w', '', '{"cols": ["a"]}', 10,
  '{"T|a": [1000, 560], "P|a": [500, 290], "D|a": [500, 270], "M|a": [100, 40], "K|a": [900, 520], "N|a": [1000, 9000],
    "p|UB|a": [300, 180], "pp|UB|a": [150, 95], "pw|UB|1|a": [300, 180],
    "dc|UB||a": [240, 140], "dc|UB|R|a": [60, 40], "dc|WUB||a": [3, 1],
    "cd|Lightning Bolt|a": [600, 350], "ch|Lightning Bolt|a": [400, 250], "co|Lightning Bolt|a": [150, 100],
    "cg|Lightning Bolt|a": [250, 150], "cn|Lightning Bolt|a": [200, 100], "cw|Lightning Bolt|1": [400, 250]}', false), 'next');
select pg_temp.eq('a replayed slice is ignored', public.limited_step_commit(:RUN, 0, 800, 'w', '', null, 10, '{"T|a": [1000, 560]}', false), 'stale');
select pg_temp.eq('sums are added once', (select g::text from t1_private.limited_acc where run_id = :RUN and k = 'T|a'), '1000');
select pg_temp.eq('last slice', public.limited_step_commit(:RUN, 1, 900, 'w', '', null, 5, '{"ch|Lightning Bolt|a": [200, 130], "cd|Lightning Bolt|a": [200, 130]}', true), 'done');
select pg_temp.eq('a finished run takes no more', public.limited_step_commit(:RUN, 2, 900, 'w', '', null, 5, '{}', true), 'gone');
select pg_temp.eq('pack: one event, one group (no top players in the sums)',
  (select string_agg(e.key || ':' || (select string_agg(g, ',') from jsonb_object_keys(e.value->'groups') g), ' ')
     from jsonb_each((public.limited_pack_facts('TST'))->'events') e), 'PremierDraft:all');
select pg_temp.eq('pack: game facts',
  (select (v->>'games') || ' ' || (v->>'wr') || ' ' || (v->'facts'->>'play_wr') || ' ' || (v->'facts'->>'turns')
     from (select public.limited_pack_facts('TST')->'events'->'PremierDraft'->'groups'->'all' v) x), '1000 0.5600 0.5800 9.0');
select pg_temp.eq('pack: a card with 600 games in hand is rated, with its Oracle id and rarity in the set',
  (select (c->>'gih') || ' ' || (c->>'gih_n') || ' ' || (c->>'iwd') || ' ' || (c->>'r') || ' ' || (c->>'col') || ' ' || ((c->>'c') = md5('Lightning Bolt')::uuid::text)::text
     from jsonb_array_elements(public.limited_pack_facts('TST')->'events'->'PremierDraft'->'groups'->'all'->'cards') c), '0.6333 600 0.1333 common R true');
select pg_temp.eq('pack: a pair with its play and draw win rates',
  (select (p->>'p') || ' ' || (p->>'wr') || ' ' || (p->>'play_wr') || ' ' || (p->>'draw_wr')
     from jsonb_array_elements(public.limited_pack_facts('TST')->'events'->'PremierDraft'->'groups'->'all'->'pairs') p), 'UB 0.6000 0.6333 0.5667');
select pg_temp.eq('pack: deck colours with their splashes, rare ones left out',
  (select string_agg((x->>'m') || '+' || (x->>'s') || ' ' || (x->>'games') || ' ' || (x->>'wr'), ', ')
     from jsonb_array_elements(public.limited_pack_facts('TST')->'events'->'PremierDraft'->'groups'->'all'->'colors') x),
  'UB+ 240 0.5833, UB+R 60 0.6667');
select pg_temp.eq('no pack without a finished run', (public.limited_pack_facts('NOPE'))::text, null);
select pg_temp.eq('a newer dump opens a new run', (public.limited_run_open('TST', 'PremierDraft', 'game', 'https://x/game.csv.gz', '2026-10-24 12:00:00+00', 1200) is not null)::text, 'true');
select pg_temp.eq('the finished run keeps serving until the new one is done', (public.limited_pack_facts('TST')->'events'->'PremierDraft'->>'updated'), '2026-10-17');
