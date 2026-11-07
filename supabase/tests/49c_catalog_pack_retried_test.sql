-- Bug #4 reopened again (2026-11-07 23:24, run 43): the pack step hit the edge CPU limit (HTTP 546) after it had
-- published the pack, and the sweep filed it. A pack killed before publishing was never posted again (the tick
-- ignored 'packing' runs until the 3-hour timeout). Now pack posts are kept with their run and the tick reads
-- their answers: after the run is done the failure is noted as retried, while still packing it is posted again
-- (three tries per run), and a third failure is filed and fails the run.
\ir _helpers.sql

delete from net.requests;
delete from net._http_response;
delete from t1_private.bugs where source = 'server';
delete from t1_private.catalog_chunks;
delete from t1_private.catalog_runs;
update t1_private.bug_state set cron_swept_to = now(), net_swept_to = 0;

-- Run 43's case: the pack is posted, publishes (the run is done), then the worker is killed on its way out.
insert into t1_private.catalog_runs (bulk_updated_at, source_uri, status, started_at)
values ('2026-11-07 22:06:35+00', 'test', 'packing', now()) returning id as run1 \gset
select t1_private.catalog_post(jsonb_build_object('step', 'pack', 'run', :run1));
select request_id as req1 from t1_private.catalog_pack_posts where run_id = :run1 \gset
select pg_temp.eq('catalog_post keeps the pack post''s request id', (:req1 is not null)::text, 'true');
select pg_temp.eq('other steps are not kept',
  (select count(*)::text from t1_private.catalog_pack_posts), '1');
update t1_private.catalog_runs set status = 'done', finished_at = now() where id = :run1;
insert into net._http_response (id, status_code, timed_out, content, created)
values (:req1, 546, false,
        '{"code":"WORKER_RESOURCE_LIMIT","message":"Function failed due to not having enough compute resources (please check logs)"}',
        now() - interval '5 minutes');
select t1_private.catalog_dispatch();
select pg_temp.eq('a pack killed after publishing is noted as retried',
  (select count(*)::text from t1_private.net_retried where request_id = :req1), '1');
select pg_temp.eq('and not posted again', (select count(*)::text from t1_private.catalog_pack_posts), '1');
select pg_temp.eq('the run stays done', (select status from t1_private.catalog_runs where id = :run1), 'done');
select pg_temp.eq('so the sweep does not file it', t1_private.bugs_sweep_server()::text, '0');
select pg_temp.eq('and #4 does not reopen', (select count(*)::text from t1_private.bugs where source = 'server'), '0');

-- Killed before publishing: posted again at once.
insert into t1_private.catalog_runs (bulk_updated_at, source_uri, status, started_at)
values ('2026-11-08 22:06:35+00', 'test', 'packing', now()) returning id as run2 \gset
select t1_private.catalog_post(jsonb_build_object('step', 'pack', 'run', :run2));
select request_id as req2 from t1_private.catalog_pack_posts where run_id = :run2 \gset
select t1_private.catalog_dispatch();
select pg_temp.eq('a pack with no answer yet is left alone',
  (select count(*)::text from t1_private.catalog_pack_posts where run_id = :run2), '1');
insert into net._http_response (id, status_code, timed_out, content, created)
values (:req2, 546, false, '{"code":"WORKER_RESOURCE_LIMIT","message":"x"}', now() - interval '5 minutes');
select t1_private.catalog_dispatch();
select pg_temp.eq('a pack killed while packing is posted again',
  (select count(*)::text from t1_private.catalog_pack_posts where run_id = :run2), '2');
select pg_temp.eq('its failure noted as retried',
  (select count(*)::text from t1_private.net_retried where request_id = :req2), '1');
select pg_temp.eq('the run keeps packing', (select status from t1_private.catalog_runs where id = :run2), 'packing');
select t1_private.catalog_dispatch();
select pg_temp.eq('a handled failure is not posted again on the next tick',
  (select count(*)::text from t1_private.catalog_pack_posts where run_id = :run2), '2');

-- Second failure retried, third filed and the run failed.
select request_id as req3 from t1_private.catalog_pack_posts
 where run_id = :run2 and request_id <> :req2 \gset
insert into net._http_response (id, status_code, timed_out, content, created)
values (:req3, 546, false, '{"code":"WORKER_RESOURCE_LIMIT","message":"x"}', now() - interval '5 minutes');
select t1_private.catalog_dispatch();
select request_id as req4 from t1_private.catalog_pack_posts
 where run_id = :run2 order by posted_at desc, request_id desc limit 1 \gset
insert into net._http_response (id, status_code, timed_out, content, created)
values (:req4, 546, false, '{"code":"WORKER_RESOURCE_LIMIT","message":"x"}', now() - interval '5 minutes');
select t1_private.catalog_dispatch();
select pg_temp.eq('three tries per run', (select count(*)::text from t1_private.catalog_pack_posts where run_id = :run2), '3');
select pg_temp.eq('the third failure fails the run',
  (select status || ' / ' || error from t1_private.catalog_runs where id = :run2), 'failed / no answer from worker (pack)');
select pg_temp.eq('the last failure is not marked retried',
  (select count(*)::text from t1_private.net_retried where request_id = :req4), '0');
select pg_temp.eq('and reaches the register', t1_private.bugs_sweep_server()::text, '1');

-- A pack that threw (cards-sync failed the run itself, HTTP 500) is filed, not retried.
delete from t1_private.bugs where source = 'server';
insert into t1_private.catalog_runs (bulk_updated_at, source_uri, status, started_at)
values ('2026-11-09 22:06:35+00', 'test', 'packing', now()) returning id as run3 \gset
select t1_private.catalog_post(jsonb_build_object('step', 'pack', 'run', :run3));
select request_id as req5 from t1_private.catalog_pack_posts where run_id = :run3 \gset
update t1_private.catalog_runs set status = 'failed', error = 'pack upload: x' where id = :run3;
insert into net._http_response (id, status_code, timed_out, content, created)
values (:req5, 500, false, '{"error":"pack upload: x"}', now() - interval '5 minutes');
select t1_private.catalog_dispatch();
select pg_temp.eq('a pack that threw is not posted again',
  (select count(*)::text from t1_private.catalog_pack_posts where run_id = :run3), '1');
select pg_temp.eq('nor noted as retried',
  (select count(*)::text from t1_private.net_retried where request_id = :req5), '0');

select pg_temp.eq('clients cannot read the pack posts',
  has_table_privilege('authenticated', 't1_private.catalog_pack_posts', 'select')::text, 'false');
