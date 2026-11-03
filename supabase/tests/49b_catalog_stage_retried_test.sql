-- Bug #4 kept reopening as an S1 regression although nothing was lost: the daily stage step is sometimes killed by
-- the edge CPU limit (HTTP 546 WORKER_RESOURCE_LIMIT, 2026-11-03 23:23, run 36). catalog_dispatch posts the stage
-- again, but only once the run had been quiet for 10 minutes, and it never knew which request was the stage's, so
-- the bug sweep (answers three minutes old) filed the 546 first. Now sync_catalog and the retry keep the stage
-- post's request id, the tick re-posts as soon as that answer is a failure, and notes it as retried. A third
-- failure for the same bulk file is still filed.
\ir _helpers.sql

delete from net.requests;
delete from net._http_response;
delete from t1_private.bugs where source = 'server';
delete from t1_private.catalog_chunks;
delete from t1_private.catalog_runs;
update t1_private.bug_state set cron_swept_to = now(), net_swept_to = 0;

-- 23:23: the cron job posts the stage; the function opens a run and is then killed.
select t1_private.sync_catalog();
select request_id as req1 from t1_private.catalog_stage_posts order by posted_at desc limit 1 \gset
select pg_temp.eq('sync_catalog keeps the stage post''s request id', (:req1 is not null)::text, 'true');
insert into t1_private.catalog_runs (bulk_updated_at, source_uri, status, started_at)
values ('2026-11-03 22:06:49+00', 'test', 'staging', now()) returning id as run1 \gset
insert into net._http_response (id, status_code, timed_out, content, created)
values (:req1, 546, false,
        '{"code":"WORKER_RESOURCE_LIMIT","message":"Function failed due to not having enough compute resources (please check logs)"}',
        now() - interval '5 minutes');

-- The next tick, two minutes later, does not wait for the 10 quiet minutes.
select t1_private.catalog_dispatch();
select pg_temp.eq('the killed run is failed at once',
  (select status || ' / ' || error from t1_private.catalog_runs where id = :run1), 'failed / no answer from worker (stage)');
select pg_temp.eq('the stage is posted again',
  (select count(*)::text from t1_private.catalog_stage_posts where request_id <> :req1), '1');
select pg_temp.eq('the 546 is noted as retried',
  (select count(*)::text from t1_private.net_retried where request_id = :req1), '1');
select pg_temp.eq('so the sweep does not file it', t1_private.bugs_sweep_server()::text, '0');
select pg_temp.eq('and #4 does not reopen', (select count(*)::text from t1_private.bugs where source = 'server'), '0');

-- A stage still working (its answer not in yet) is left alone.
select request_id as req2 from t1_private.catalog_stage_posts order by posted_at desc, request_id desc limit 1 \gset
insert into t1_private.catalog_runs (bulk_updated_at, source_uri, status, started_at)
values ('2026-11-03 22:06:49+00', 'test', 'staging', now()) returning id as run2 \gset
select t1_private.catalog_dispatch();
select pg_temp.eq('a stage with no answer yet keeps going',
  (select status from t1_private.catalog_runs where id = :run2), 'staging');

-- Second and third failures for the same file: the third is the last try, so it is filed.
insert into net._http_response (id, status_code, timed_out, content, created)
values (:req2, 546, false, '{"code":"WORKER_RESOURCE_LIMIT","message":"x"}', now() - interval '5 minutes');
select t1_private.catalog_dispatch();
select request_id as req3 from t1_private.catalog_stage_posts order by posted_at desc, request_id desc limit 1 \gset
select pg_temp.eq('the second failure is retried too',
  (select count(*)::text from t1_private.net_retried where request_id = :req2), '1');
insert into t1_private.catalog_runs (bulk_updated_at, source_uri, status, started_at)
values ('2026-11-03 22:06:49+00', 'test', 'staging', now()) returning id as run3 \gset
insert into net._http_response (id, status_code, timed_out, content, created)
values (:req3, 546, false, '{"code":"WORKER_RESOURCE_LIMIT","message":"x"}', now() - interval '5 minutes');
select t1_private.catalog_dispatch();
select pg_temp.eq('the third run is failed',
  (select status from t1_private.catalog_runs where id = :run3), 'failed');
select pg_temp.eq('no fourth post', (select count(*)::text from t1_private.catalog_stage_posts), '3');
select pg_temp.eq('the last failure is not marked retried',
  (select count(*)::text from t1_private.net_retried where request_id = :req3), '0');
select pg_temp.eq('and reaches the register', t1_private.bugs_sweep_server()::text, '1');

-- A quiet stage with no answer at all still fails after 10 minutes, as before.
delete from t1_private.catalog_runs;
insert into t1_private.catalog_runs (bulk_updated_at, source_uri, status, started_at)
values ('2026-11-04 22:06:49+00', 'test', 'staging', now() - interval '11 minutes') returning id as run4 \gset
select t1_private.catalog_dispatch();
select pg_temp.eq('a silent stage still fails after 10 minutes',
  (select status from t1_private.catalog_runs where id = :run4), 'failed');

select pg_temp.eq('clients cannot read the stage posts',
  has_table_privilege('authenticated', 't1_private.catalog_stage_posts', 'select')::text, 'false');
