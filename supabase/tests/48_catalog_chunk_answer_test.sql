-- Catalog chunk answers (bug #18, cards-sync): the dispatcher sends three chunks at once, and the edge runtime
-- refused one of the three cold boots on 2026-10-29 (HTTP 503 BOOT_ERROR after 10 s). The chunk kept its 'running'
-- status for five minutes before the tick called it quiet, which held the whole run. Now each chunk remembers its
-- pg_net request id, and a failed answer (5xx, timed out, no connection) puts the chunk back at the next tick.
\ir _helpers.sql

delete from net.requests;
delete from net._http_response;
insert into t1_private.catalog_runs (bulk_updated_at, source_uri, status, chunks, started_at)
values (now(), 'test', 'ingesting', 4, now() - interval '1 minute') returning id as run \gset
insert into t1_private.catalog_chunks (run_id, n) select :run, n from generate_series(0, 3) n;

select t1_private.catalog_dispatch();
select pg_temp.eq('three chunks go out at once',
  (select string_agg(body->>'n', ',' order by id) from net.requests where url like '%/cards-sync'), '0,1,2');
select pg_temp.eq('each running chunk remembers its request',
  (select string_agg(n || ':' || coalesce(request_id::text, '-'), ',' order by n)
     from t1_private.catalog_chunks where run_id = :run and status = 'running'), '0:1,1:2,2:3');
select pg_temp.eq('the fourth waits', (select status from t1_private.catalog_chunks where run_id = :run and n = 3), 'pending');

-- The third boot is refused. Its chunk goes back and out again on the next tick, not five minutes later.
insert into net._http_response (id, status_code, timed_out, content)
values (3, 503, false, '{"code":"BOOT_ERROR","message":"Function failed to start (please check logs)"}');
delete from net.requests;
select t1_private.catalog_dispatch();
select pg_temp.eq('a refused chunk is sent again at once',
  (select string_agg(body->>'n', ',' order by id) from net.requests where url like '%/cards-sync'), '2');
select pg_temp.eq('with a second attempt and a new request',
  (select attempts || '/' || request_id || '/' || status from t1_private.catalog_chunks where run_id = :run and n = 2),
  '2/4/running');
select pg_temp.eq('the other two are untouched',
  (select string_agg(n || ':' || attempts || ':' || request_id, ',' order by n)
     from t1_private.catalog_chunks where run_id = :run and n in (0, 1)), '0:1:1,1:1:2');

-- A 2xx answer means the worker is at work (catalog_chunk_finish ends it); the tick leaves it alone.
insert into net._http_response (id, status_code, timed_out) values (1, 200, false);
delete from net.requests;
select t1_private.catalog_dispatch();
select pg_temp.eq('an answered chunk keeps running',
  (select status || '/' || attempts from t1_private.catalog_chunks where run_id = :run and n = 0) || '/' ||
  (select count(*) from net.requests), 'running/1/0');

-- Timed out and no-connection answers count as failures too; the third failure fails the chunk and the run.
insert into net._http_response (id, status_code, timed_out) values (4, null, true);
select t1_private.catalog_dispatch();
select pg_temp.eq('a timed-out answer is a third try',
  (select attempts || '/' || status from t1_private.catalog_chunks where run_id = :run and n = 2), '3/running');
insert into net._http_response (id, status_code, timed_out, error_msg) values (5, null, false, 'Couldn''t connect');
select t1_private.catalog_dispatch();
select pg_temp.eq('three failed answers fail the chunk',
  (select status || ':' || error from t1_private.catalog_chunks where run_id = :run and n = 2),
  'failed:no answer from worker (Couldn''t connect)');
select pg_temp.eq('and the run',
  (select status || ':' || error from t1_private.catalog_runs where id = :run), 'failed:chunk failed');

-- A chunk with no answer at all is still called quiet after five minutes (the edge worker killed mid-way).
delete from t1_private.catalog_runs;
delete from net.requests;
delete from net._http_response;
insert into t1_private.catalog_runs (bulk_updated_at, source_uri, status, chunks, started_at)
values (now(), 'test', 'ingesting', 1, now() - interval '1 minute') returning id as run2 \gset
insert into t1_private.catalog_chunks (run_id, n) values (:run2, 0);
select t1_private.catalog_dispatch();
select t1_private.catalog_dispatch();
select pg_temp.eq('an unanswered chunk is left alone for now',
  (select attempts::text from t1_private.catalog_chunks where run_id = :run2 and n = 0), '1');
update t1_private.catalog_chunks set started_at = now() - interval '6 minutes' where run_id = :run2;
select t1_private.catalog_dispatch();
select pg_temp.eq('and sent again once quiet for five minutes',
  (select attempts || '/' || count(*) from t1_private.catalog_chunks, net.requests
     where run_id = :run2 and n = 0 group by attempts), '2/2');
