-- Bug #18 kept coming back: a cold boot the edge refuses (503 BOOT_ERROR) is already sent again by the caller that
-- watches its answer (catalog_dispatch for cards-sync chunks, meta_build_next for meta-sync builds), and the work
-- finishes a minute later; but the server sweep filed every refused boot, so the register reopened #18 as an S1
-- regression (2026-11-02 23:23, run 35 chunk 2, re-sent and done by 23:25). Now a failure the caller put back for
-- another try is noted in t1_private.net_retried and the sweep leaves it out; the sweep also waits three minutes so
-- the caller's tick gets there first. A last try that fails is still filed.
\ir _helpers.sql

delete from net.requests;
delete from net._http_response;
delete from t1_private.bugs where source = 'server';
update t1_private.bug_state set cron_swept_to = now(), net_swept_to = 0;

-- A cards-sync chunk refused once, then sent again.
insert into t1_private.catalog_runs (bulk_updated_at, source_uri, status, chunks, started_at)
values (now(), 'test', 'ingesting', 1, now() - interval '1 minute') returning id as run \gset
insert into t1_private.catalog_chunks (run_id, n) values (:run, 0);
select t1_private.catalog_dispatch();
select request_id as req1 from t1_private.catalog_chunks where run_id = :run \gset
insert into net._http_response (id, status_code, timed_out, content, created)
values (:req1, 503, false, '{"code":"BOOT_ERROR","message":"Function failed to start (please check logs)"}',
        now() - interval '5 minutes');
select t1_private.catalog_dispatch();
select pg_temp.eq('the dispatcher notes the refused request as retried',
  (select count(*)::text from t1_private.net_retried where request_id = :req1), '1');

-- A meta-sync build refused once, then sent again.
delete from t1_private.meta_build_queue;
insert into t1_private.meta_build_queue (format) values ('modern');
select t1_private.meta_build_next();
select request_id as req2 from t1_private.meta_build_queue where format = 'modern' \gset
insert into net._http_response (id, status_code, timed_out, content, created)
values (:req2, 503, false, '{"code":"BOOT_ERROR","message":"Function failed to start (please check logs)"}',
        now() - interval '5 minutes');
select t1_private.meta_build_next();
select pg_temp.eq('meta_build_next notes it too',
  (select count(*)::text from t1_private.net_retried where request_id = :req2), '1');

select pg_temp.eq('retried failures are not filed', t1_private.bugs_sweep_server()::text, '0');
select pg_temp.eq('so #18 does not reopen',
  (select count(*)::text from t1_private.bugs where source = 'server'), '0');

-- A failure nobody retries is still filed, but only once it is three minutes old.
insert into net._http_response (id, status_code, timed_out, content, created)
values (900001, 500, false, '{"error":"boom"}', now() - interval '30 seconds');
select pg_temp.eq('a fresh failure waits for the callers', t1_private.bugs_sweep_server()::text, '0');
update net._http_response set created = now() - interval '4 minutes' where id = 900001;
select pg_temp.eq('and is filed once old enough', t1_private.bugs_sweep_server()::text, '1');

-- The last try failing is filed: the dispatcher gives up, so nothing retries it.
update t1_private.catalog_chunks set attempts = 3, status = 'running', request_id = 900002 where run_id = :run;
insert into net._http_response (id, status_code, timed_out, content, created)
values (900002, 503, false, '{"code":"BOOT_ERROR","message":"Function failed to start (please check logs)"}',
        now() - interval '5 minutes');
select t1_private.catalog_dispatch();
select pg_temp.eq('a failed last try is not marked retried',
  (select count(*)::text from t1_private.net_retried where request_id = 900002), '0');
select pg_temp.eq('and reaches the register', t1_private.bugs_sweep_server()::text, '1');

select pg_temp.eq('clients cannot read the retried list',
  has_table_privilege('authenticated', 't1_private.net_retried', 'select')::text, 'false');
