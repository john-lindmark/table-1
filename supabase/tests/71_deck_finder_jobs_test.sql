-- Deck finder jobs and Table 1's own results (20261101130000_deck_finder_jobs, contract/deck-finder-2026-10-15.md
-- § Jobs / § Table 1 results).
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000007a1', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000007b1', 'bea@example.com');
\set A '''00000000-0000-0000-0000-0000000007a1'''
\set B '''00000000-0000-0000-0000-0000000007b1'''
insert into t1_private.settings (name, value) values ('live_push_secret', 's3cret') on conflict (name) do nothing;

create or replace function pg_temp.kicks() returns text language sql security definer as $$
  select count(*)::text from net.requests where url like '%/functions/v1/deck-finder';
$$;
create or replace function pg_temp.used() returns text language sql security definer as $$
  select coalesce((select searches::text from t1_private.deck_finder_usage where user_id = '00000000-0000-0000-0000-0000000007a1' and day = (now() at time zone 'utc')::date), '0');
$$;
create or replace function pg_temp.status(p uuid) returns text language sql security definer as $$
  select status || ':' || attempts from t1_private.deck_finder_jobs where id = p;
$$;
create or replace function pg_temp.pushes() returns text language sql security definer as $$
  select coalesce(string_agg((msg->'data'->>'status') || ':' || coalesce(msg->'data'->>'name', msg->'data'->>'question', msg->'data'->>'message', '-'), ' ' order by msg_id), '-')
    from pgmq.messages where msg->>'kind' = 'deck.found';
$$;
grant execute on function pg_temp.kicks() to authenticated;
grant execute on function pg_temp.pushes() to authenticated;
grant execute on function pg_temp.used() to authenticated;
grant execute on function pg_temp.status(uuid) to authenticated;

-- Starting -------------------------------------------------------------------------------------------------------
set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('signed out can''t start', $$select public.deck_finder_start('boros energy', 'modern')$$, '42501');
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.throws('too short', $$select public.deck_finder_start('bo', 'modern')$$, '22023');
select (public.deck_finder_start('  latest Boros Energy  ', 'Modern', '[{"question": "Which?", "answer": " Boros "}, {"question": "", "answer": "x"}, 7]')->>'job_id') as job \gset
select pg_temp.eq('one kick went out', pg_temp.kicks(), '1');
select pg_temp.eq('the job reads back trimmed, with the answers cleaned',
  (select j->>'status' || '|' || (j->>'query') || '|' || (j->>'format') || '|' || (j->'answers')::text from public.deck_finder_job(:'job'::uuid) j),
  'queued|latest Boros Energy|modern|[{"answer": "Boros", "question": "Which?"}]');
select pg_temp.eq('no id: the newest job', (public.deck_finder_job()->>'job_id'), :'job');
select pg_temp.eq('the same search again is the same job, nothing spent',
  (select (s->>'job_id' = :'job')::text || ' ' || (s->>'again') from public.deck_finder_start('latest Boros Energy', 'modern', '[{"question": "Which?", "answer": "Boros"}]') s), 'true true');
select pg_temp.eq('one search counted', pg_temp.used(), '1');
select pg_temp.eq('an unknown format is none', (public.deck_finder_start('pauper affinity', 'limited')->>'status'), 'queued');
select pg_temp.eq('two searches counted', pg_temp.used(), '2');
reset role;
update t1_private.deck_finder_usage set searches = 20 where user_id = :A;
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.throws('the day''s allowance', $$select public.deck_finder_start('a third', 'modern')$$, 'P0001');
reset role;
update t1_private.deck_finder_usage set searches = 2 where user_id = :A;
set role authenticated;
select pg_temp.as_user(:A);

select pg_temp.as_user(:B);
select pg_temp.eq('another account reads nothing', coalesce(public.deck_finder_job(:'job'::uuid)::text, 'null'), 'null');
select pg_temp.eq('nor a newest job', coalesce(public.deck_finder_job()::text, 'null'), 'null');
select pg_temp.throws('clients can''t claim', $$select public.deck_finder_claim('00000000-0000-0000-0000-000000000000')$$, '42501');
select pg_temp.throws('nor finish', $$select public.deck_finder_finish('00000000-0000-0000-0000-000000000000', '{}')$$, '42501');
select pg_temp.throws('nor read the results', $$select public.deck_finder_events('modern')$$, '42501');

-- The function's side ---------------------------------------------------------------------------------------------
reset role;
select pg_temp.eq('claim takes the queued job', (select c->>'query' || '|' || (c->>'user_id' = :A)::text from public.deck_finder_claim(:'job'::uuid) c), 'latest Boros Energy|true');
select pg_temp.eq('a second claim gets nothing', coalesce(public.deck_finder_claim(:'job'::uuid)::text, 'null'), 'null');
select pg_temp.eq('running', (select status from t1_private.deck_finder_jobs where id = :'job'), 'running');
select pg_temp.eq('finish ends it', public.deck_finder_finish(:'job'::uuid,
  '{"status": "deck", "deck": {"name": "Boros Energy", "placement": "1st", "event": "Modern Challenge 32", "date": "2026-10-30", "main": [{"qty": 4, "name": "Guide of Souls"}]}}')::text, 'true');
select pg_temp.eq('one push, with the headline and never the list', pg_temp.pushes(), 'deck:Boros Energy');
select pg_temp.eq('the push data', (select (msg->'data')::text from pgmq.messages where msg->>'kind' = 'deck.found'),
  '{"date": "2026-10-30", "name": "Boros Energy", "event": "Modern Challenge 32", "job_id": "' || :'job' || '", "status": "deck", "placement": "1st"}');
select pg_temp.eq('finishing twice is no news', public.deck_finder_finish(:'job'::uuid, '{"status": "not_found"}')::text, 'false');
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.eq('the owner reads the result', (select j->>'status' || '|' || (j->'result'->'deck'->>'name') from public.deck_finder_job(:'job'::uuid) j), 'done|Boros Energy');
reset role;

-- The sweep -----------------------------------------------------------------------------------------------------------
delete from pgmq.messages where msg->>'kind' = 'deck.found';
select id as q2 from t1_private.deck_finder_jobs where query = 'pauper affinity' \gset
update t1_private.deck_finder_jobs set created_at = now() - interval '1 minute' where id = :'q2';
select t1_private.deck_finder_sweep();
select pg_temp.eq('an unclaimed job is kicked again', pg_temp.kicks(), '3');
select pg_temp.eq('still queued', (select status || ':' || attempts from t1_private.deck_finder_jobs where id = :'q2'), 'queued:2');
update t1_private.deck_finder_jobs set attempts = 3 where id = :'q2';
select t1_private.deck_finder_sweep();
select pg_temp.eq('after three tries it fails, and the player hears', (select status from t1_private.deck_finder_jobs where id = :'q2') || ' ' || pg_temp.pushes(),
  'failed error:The deck finder couldn''t finish that search. Try again.');
delete from pgmq.messages where msg->>'kind' = 'deck.found';
insert into t1_private.deck_finder_jobs (user_id, query, status, started_at, created_at) values (:A, 'stuck', 'running', now() - interval '5 minutes', now() - interval '5 minutes');
insert into t1_private.deck_finder_jobs (user_id, query, status, started_at) values (:A, 'fresh', 'running', now() - interval '1 minute');
insert into t1_private.deck_finder_jobs (user_id, query, status, created_at, finished_at) values (:A, 'old', 'done', now() - interval '8 days', now() - interval '8 days');
select t1_private.deck_finder_sweep();
select pg_temp.eq('a run over four minutes fails; a fresh one and an old one are left alone',
  (select string_agg(query || ':' || status, ' ' order by query) from t1_private.deck_finder_jobs where query in ('stuck', 'fresh', 'old')), 'fresh:running stuck:failed');
select pg_temp.eq('the timed-out player hears once', pg_temp.pushes(), 'error:The deck finder couldn''t finish that search. Try again.');

-- Table 1's results ---------------------------------------------------------------------------------------------
insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Guide of Souls', 'guide of souls', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000002', 'Ajani, Nacatl Pariah', 'ajani, nacatl pariah', 'normal', 'c1000000-0000-0000-0000-000000000002', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000003', 'Wear // Tear', 'wear // tear', 'split', 'c1000000-0000-0000-0000-000000000003', 'a', 'h');
insert into t1_private.meta_archetypes (id, format, name, family, colors, status, rule, priority) values
  (901, 'modern', 'Test Energy', 'aggro', 'WR', 'approved', '{}', 10),
  (902, 'modern', 'Test End', 'combo', 'UBRG', 'approved', '{}', 10);
insert into t1_private.meta_events (id, source, source_id, format, name, kind, on_date, players, tier, url) values
  (9001, 'mtgo', 'DF1', 'modern', 'Modern Challenge 32', 'challenge', current_date - 1, 58, 'regular', 'https://www.mtgo.com/decklist/modern-challenge-32'),
  (9002, 'melee', 'DF2', 'modern', 'Regional Championship', 'championship', current_date - 2, 400, 'major', 'https://melee.gg/Tournament/View/1'),
  (9003, 'mtgo', 'DF3', 'modern', 'Modern Challenge 32', 'challenge', current_date - 100, 50, 'regular', 'https://www.mtgo.com/decklist/old'),
  (9004, 'mtgo', 'DF4', 'pauper', 'Pauper Challenge 32', 'challenge', current_date - 1, 50, 'regular', 'https://www.mtgo.com/decklist/pauper');
insert into t1_private.meta_decks (id, event_id, format, on_date, tier, weight, player, rank, wins, losses, draws, top8, main, main_qty, side, side_qty, colors, archetype_id) values
  (99001, 9001, 'modern', current_date - 1, 'regular', 1, 'p1', 1, 8, 1, 0, true,
    array['c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002']::uuid[], array[4, 3]::smallint[],
    array['c0000000-0000-0000-0000-000000000003']::uuid[], array[2]::smallint[], 'WR', 901),
  (99002, 9001, 'modern', current_date - 1, 'regular', 1, 'p2', 2, 7, 2, 0, true, '{}', '{}', '{}', '{}', 'UBRG', 902),
  (99003, 9001, 'modern', current_date - 1, 'regular', 1, 'p3', 9, 5, 3, 0, false, '{}', '{}', '{}', '{}', 'G', 0),
  (99004, 9002, 'modern', current_date - 2, 'major', 4, 'p4', 3, 10, 2, 1, true, '{}', '{}', '{}', '{}', 'WR', 901),
  (99005, 9003, 'modern', current_date - 100, 'regular', 1, 'p5', 1, 6, 1, 0, true, '{}', '{}', '{}', '{}', 'WR', 901),
  (99006, 9004, 'pauper', current_date - 1, 'regular', 1, 'p6', 1, 6, 1, 0, true, '{}', '{}', '{}', '{}', 'UR', 0);
select pg_temp.eq('events of the last 30 days, newest first, with their decks best first',
  (select string_agg((e->>'event_id') || ':' || (select string_agg(d->>'deck_id', ',') from jsonb_array_elements(e->'decks') d), ' ')
     from jsonb_array_elements(public.deck_finder_events('modern')) e),
  '9001:99001,99002,99003 9002:99004');
select pg_temp.eq('an archetype narrows both',
  (select string_agg((e->>'event_id') || ':' || (select string_agg(d->>'deck_id', ',') from jsonb_array_elements(e->'decks') d), ' ')
     from jsonb_array_elements(public.deck_finder_events('Modern', 30, 'energy')) e),
  '9001:99001 9002:99004');
select pg_temp.eq('a longer window reaches the old event', (select count(*)::text from jsonb_array_elements(public.deck_finder_events('modern', 365, 'Test Energy'))), '3');
select pg_temp.eq('Other is Other',
  (select string_agg(coalesce(d->>'archetype', 'null'), ',') from jsonb_array_elements(public.deck_finder_events('modern')->0->'decks') d) || ' '
  || (public.deck_finder_events('pauper')->0->'decks'->0->>'archetype'), 'Test Energy,Test End,Other Other');
select pg_temp.eq('the deck, as published', (select (d->>'event') || '|' || (d->>'rank') || '|' || (d->'main')::text || '|' || (d->'side')::text from public.deck_finder_deck(99001) d),
  'Modern Challenge 32|1|[{"qty": 4, "name": "Guide of Souls"}, {"qty": 3, "name": "Ajani, Nacatl Pariah"}]|[{"qty": 2, "name": "Wear // Tear"}]');
select pg_temp.eq('no such deck', coalesce(public.deck_finder_deck(1)::text, 'null'), 'null');
select pg_temp.eq('no such format', public.deck_finder_events('commander')::text, '[]');
