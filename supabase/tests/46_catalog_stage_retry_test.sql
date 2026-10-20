-- Catalog stage retry (bug #4): the daily stage step can be killed by the edge CPU limit (HTTP 546), which leaves
-- its run in 'staging' with nobody to answer. The tick fails that run and posts the stage step again, three tries
-- per bulk file, so a killed worker doesn't cost a day of prices.
\ir _helpers.sql

delete from net.requests;
insert into t1_private.catalog_runs (bulk_updated_at, source_uri, started_at)
values ('2026-10-19 21:05:50+00', 'https://data.scryfall.io/default-cards/x.jsonl.gz', now() - interval '2 minutes')
returning id as run \gset

select t1_private.catalog_dispatch();
select pg_temp.eq('a stage still working is left alone',
  (select status from t1_private.catalog_runs where id = :run) || '/' || (select count(*) from net.requests), 'staging/0');

update t1_private.catalog_runs set started_at = now() - interval '11 minutes' where id = :run;
select t1_private.catalog_dispatch();
select pg_temp.eq('a quiet stage fails its run',
  (select status || ':' || error from t1_private.catalog_runs where id = :run), 'failed:no answer from worker (stage)');
select pg_temp.eq('and posts the stage step again',
  (select string_agg(body::text, ',') from net.requests where url like '%/cards-sync'), '{"step": "stage"}');

-- The retry opens a new run for the same file (catalog_run_begin no longer sees one in flight).
select public.catalog_run_begin('2026-10-19 21:05:50+00', 'https://data.scryfall.io/default-cards/x.jsonl.gz') as run2 \gset
select pg_temp.eq('the retry gets a new run', (:run2 > :run)::text, 'true');

-- Third quiet stage for the same file: give up until tomorrow's run.
update t1_private.catalog_runs set started_at = now() - interval '11 minutes' where id = :run2;
select t1_private.catalog_dispatch();
select public.catalog_run_begin('2026-10-19 21:05:50+00', 'https://data.scryfall.io/default-cards/x.jsonl.gz') as run3 \gset
update t1_private.catalog_runs set started_at = now() - interval '11 minutes' where id = :run3;
delete from net.requests;
select t1_private.catalog_dispatch();
select pg_temp.eq('three quiet stages for one file stop retrying',
  (select status from t1_private.catalog_runs where id = :run3) || '/' || (select count(*) from net.requests), 'failed/0');

-- A run that is ingesting is not touched by the stage check.
delete from t1_private.catalog_runs;
insert into t1_private.catalog_runs (bulk_updated_at, source_uri, status, chunks, started_at)
values (now(), 'test', 'ingesting', 0, now() - interval '20 minutes') returning id as run4 \gset
select t1_private.catalog_dispatch();
select pg_temp.eq('ingesting runs are not stage retries',
  (select status from t1_private.catalog_runs where id = :run4) || '/' || (select count(*) from net.requests), 'ingesting/0');
