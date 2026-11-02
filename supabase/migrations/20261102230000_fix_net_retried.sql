-- Bug #18 kept reopening as an S1 regression although nothing was lost: a cold boot the edge refuses (503
-- BOOT_ERROR) is sent again by the caller that reads its answer (catalog_dispatch for cards-sync chunks since
-- 20261030010000, meta_build_next for meta-sync builds since 20261029120000), and the work finishes a minute later
-- (2026-11-02 23:23: run 35 chunk 2 refused, re-sent at 23:24:07, the run done at 23:25). The server sweep still
-- filed every refused boot. Now those callers note a failed request they put back for another try in
-- t1_private.net_retried, and the sweep leaves those out; the sweep also only reads answers three minutes old, so
-- the callers' ticks (every 1-2 minutes) get there first. A last try that fails is still filed.
-- The three functions are otherwise as in 20261018200000_bug_pipeline.sql, 20261030010000_fix_catalog_chunk_answer.sql
-- and 20261029120000_meta_build_queue.sql.

create table if not exists t1_private.net_retried (
  request_id bigint primary key,
  retried_at timestamptz not null default now()
);
alter table t1_private.net_retried enable row level security;
revoke all on t1_private.net_retried from public, anon, authenticated;

create or replace function t1_private.catalog_dispatch()
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_run t1_private.catalog_runs;
  v_free integer;
  v_n integer;
begin
  select * into v_run from t1_private.catalog_runs
   where status in ('staging', 'ingesting', 'naming', 'packing') order by id desc limit 1;
  if v_run.id is null then return; end if;

  if now() - v_run.started_at > interval '3 hours' then
    update t1_private.catalog_runs set status = 'failed', error = coalesce(error, 'timed out'), finished_at = now()
     where id = v_run.id;
    return;
  end if;
  if v_run.status = 'staging' then
    if now() - v_run.started_at > interval '10 minutes' then
      update t1_private.catalog_runs set status = 'failed', error = 'no answer from worker (stage)', finished_at = now()
       where id = v_run.id;
      if (select count(*) from t1_private.catalog_runs
           where bulk_updated_at = v_run.bulk_updated_at and error = 'no answer from worker (stage)') < 3 then
        perform t1_private.catalog_post('{"step":"stage"}'::jsonb);
      end if;
    end if;
    return;
  end if;
  if v_run.status = 'naming' then
    if exists (select 1 from t1_private.catalog_names_cursor
                where run_id = v_run.id and updated_at < now() - interval '5 minutes') then
      perform t1_private.catalog_names_retry(v_run.id, 'no answer from worker');
    end if;
    return;
  end if;
  if v_run.status <> 'ingesting' then return; end if;

  -- A post the edge answered with a failure (a refused boot, a timeout, no connection) is back at once.
  -- Noted as retried, so the bug sweep leaves it out (a last try that fails is still filed).
  insert into t1_private.net_retried (request_id)
  select c.request_id
    from t1_private.catalog_chunks c join net._http_response r on r.id = c.request_id
   where c.run_id = v_run.id and c.status = 'running' and c.attempts < 3
     and (coalesce(r.status_code, 0) >= 500 or coalesce(r.timed_out, false) or r.error_msg is not null
          or coalesce(r.status_code, 0) = 0)
  on conflict do nothing;
  update t1_private.catalog_chunks c
     set status = case when c.attempts >= 3 then 'failed' else 'pending' end,
         error = 'no answer from worker (' || coalesce(
           case when r.timed_out then 'timed out' end, r.error_msg,
           case when r.status_code is not null then 'HTTP ' || r.status_code end, 'failed') || ')',
         request_id = null
    from net._http_response r
   where c.run_id = v_run.id and c.status = 'running' and r.id = c.request_id
     and (coalesce(r.status_code, 0) >= 500 or coalesce(r.timed_out, false) or r.error_msg is not null
          or coalesce(r.status_code, 0) = 0);
  -- One with no answer at all (the worker killed mid-way) waits five minutes.
  update t1_private.catalog_chunks
     set status = case when attempts >= 3 then 'failed' else 'pending' end,
         error = coalesce(error, 'no answer from worker'), request_id = null
   where run_id = v_run.id and status = 'running' and started_at < now() - interval '5 minutes';
  if exists (select 1 from t1_private.catalog_chunks where run_id = v_run.id and status = 'failed') then
    update t1_private.catalog_runs set status = 'failed', error = 'chunk failed', finished_at = now()
     where id = v_run.id;
    return;
  end if;

  select 3 - count(*) into v_free from t1_private.catalog_chunks where run_id = v_run.id and status = 'running';
  for v_n in
    select n from t1_private.catalog_chunks
     where run_id = v_run.id and status = 'pending' order by n limit greatest(v_free, 0)
       for update skip locked
  loop
    update t1_private.catalog_chunks
       set status = 'running', attempts = attempts + 1, started_at = now(), error = null,
           request_id = t1_private.catalog_post_id(jsonb_build_object('step', 'chunk', 'run', v_run.id, 'n', v_n))
     where run_id = v_run.id and n = v_n;
  end loop;
end $$;

create or replace function t1_private.meta_build_next()
returns void language plpgsql security definer set search_path = '' as $$
declare v_format text; v_id bigint;
begin
  delete from t1_private.meta_build_queue q
   using net._http_response r
   where r.id = q.request_id and r.status_code between 200 and 299 and not coalesce(r.timed_out, false);
  -- A failed answer that gets another try is noted as retried, so the bug sweep leaves it out.
  insert into t1_private.net_retried (request_id)
  select q.request_id
    from t1_private.meta_build_queue q join net._http_response r on r.id = q.request_id
   where q.tries < 3
     and not (r.status_code between 200 and 299 and not coalesce(r.timed_out, false))
  on conflict do nothing;
  update t1_private.meta_build_queue q set request_id = null, asked_at = null
   where q.request_id is not null
     and (exists (select 1 from net._http_response r where r.id = q.request_id)
          or q.asked_at < now() - interval '5 minutes');
  delete from t1_private.meta_build_queue where request_id is null and tries >= 3;
  if exists (select 1 from t1_private.meta_build_queue where request_id is not null) then return; end if;

  select q.format into v_format
    from t1_private.meta_build_queue q left join t1_private.meta_formats f using (format)
   order by q.tries, f.ord nulls last, q.format
   limit 1;
  if v_format is null then return; end if;
  v_id := t1_private.insights_post_id('meta-sync', jsonb_build_object('step', 'build', 'format', v_format));
  update t1_private.meta_build_queue set request_id = v_id, asked_at = now(), tries = tries + 1 where format = v_format;
end $$;

create or replace function t1_private.bugs_sweep_server()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  st t1_private.bug_state;
  r record;
  v_n integer := 0;
  v_cron_to timestamptz;
  v_net_to bigint;
  v_settled timestamptz := now() - interval '3 minutes';
begin
  select * into st from t1_private.bug_state where id = 1 for update;
  v_cron_to := st.cron_swept_to; v_net_to := st.net_swept_to;
  for r in
    select j.jobname, t1_private.bug_normalize(d.return_message) norm, max(d.return_message) msg,
           count(*) n, max(d.start_time) at
      from cron.job_run_details d join cron.job j on j.jobid = d.jobid
     where d.status = 'failed' and d.start_time > st.cron_swept_to
     group by 1, 2 loop
    perform public.bug_report(jsonb_build_object(
      'fingerprint', 'cron:' || r.jobname || ':' || left(md5(r.norm), 12), 'source', 'server', 'platform', 'server',
      'title', 'Cron job ' || r.jobname || ' failed: ' || left(coalesce(r.msg, 'no message'), 200),
      'culprit', r.jobname, 'level', 'error', 'environment', 'production', 'events', r.n, 'seen_at', r.at,
      'detail', jsonb_build_object('kind', 'cron', 'job', r.jobname, 'message', left(r.msg, 2000))));
    v_n := v_n + r.n;
    v_cron_to := greatest(v_cron_to, r.at);
  end loop;
  for r in
    select coalesce(h.status_code, 0) code, h.timed_out, t1_private.bug_normalize(coalesce(h.error_msg, h.content)) norm,
           max(left(coalesce(h.error_msg, h.content), 2000)) msg, count(*) n, max(h.created) at, max(h.id) last_id
      from net._http_response h
     where h.id > st.net_swept_to and h.created < v_settled
       and (h.status_code >= 500 or h.timed_out or h.error_msg is not null)
       and not exists (select 1 from t1_private.net_retried x where x.request_id = h.id)
     group by 1, 2, 3 loop
    perform public.bug_report(jsonb_build_object(
      'fingerprint', 'net:' || r.code || ':' || left(md5(coalesce(r.timed_out::text, '') || r.norm), 12),
      'source', 'server', 'platform', 'server',
      'title', 'Background call failed (' || case when r.timed_out then 'timed out' when r.code = 0 then 'no response'
               else 'HTTP ' || r.code end || '): ' || left(coalesce(r.msg, ''), 200),
      'level', 'error', 'environment', 'production', 'events', r.n, 'seen_at', r.at,
      'detail', jsonb_build_object('kind', 'pg_net', 'status', r.code, 'timed_out', r.timed_out, 'message', r.msg)));
    v_n := v_n + r.n;
  end loop;
  select greatest(st.net_swept_to, coalesce(max(id), 0)) into v_net_to from net._http_response where created < v_settled;
  delete from t1_private.net_retried where retried_at < now() - interval '2 days';
  update t1_private.bug_state set cron_swept_to = v_cron_to, net_swept_to = v_net_to where id = 1;
  return v_n;
end $$;
