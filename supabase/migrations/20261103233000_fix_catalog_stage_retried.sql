-- Bug #4 kept reopening as an S1 regression although nothing was lost: the daily stage step is sometimes killed by
-- the edge CPU limit (HTTP 546 WORKER_RESOURCE_LIMIT; 2026-10-19, 2026-10-25, 2026-11-03 23:23 run 36). Since
-- 20261020001000 the tick posts the stage again, but only after the run has been quiet for 10 minutes, and it never
-- knew which request was the stage's, so the bug sweep (answers three minutes old, 20261102230000) filed the 546
-- first and the register reopened #4. Now sync_catalog and the retry keep the stage post's pg_net request id in
-- t1_private.catalog_stage_posts; the tick fails the run and posts again as soon as that answer is a failure (a
-- silent stage still waits 10 minutes) and notes the failure in t1_private.net_retried. Three tries per bulk file,
-- as before; a third failure is still filed. Needs 20261102230000_fix_net_retried.sql first.
-- catalog_dispatch is otherwise as in 20261102230000_fix_net_retried.sql; sync_catalog as in 20261014150000.

create table if not exists t1_private.catalog_stage_posts (
  request_id bigint primary key,
  posted_at timestamptz not null default now()
);
alter table t1_private.catalog_stage_posts enable row level security;
revoke all on t1_private.catalog_stage_posts from public, anon, authenticated;

create or replace function t1_private.catalog_stage_post()
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into t1_private.catalog_stage_posts (request_id)
  values (t1_private.catalog_post_id('{"step":"stage"}'::jsonb));
  delete from t1_private.catalog_stage_posts where posted_at < now() - interval '7 days';
end $$;
revoke all on function t1_private.catalog_stage_post() from public, anon, authenticated;

create or replace function t1_private.sync_catalog()
returns void language sql security definer set search_path = '' as $$
  select t1_private.catalog_stage_post();
$$;

create or replace function t1_private.catalog_dispatch()
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_run t1_private.catalog_runs;
  v_free integer;
  v_n integer;
  v_stage bigint;
  v_stage_failed boolean;
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
    -- The stage post this run came from (posted just before the function opened the run) and its answer, if any.
    select p.request_id into v_stage
      from t1_private.catalog_stage_posts p
     where p.posted_at <= v_run.started_at + interval '5 seconds'
     order by p.posted_at desc, p.request_id desc limit 1;
    select (coalesce(r.status_code, 0) >= 500 or coalesce(r.timed_out, false) or r.error_msg is not null
            or coalesce(r.status_code, 0) = 0)
      into v_stage_failed
      from net._http_response r where r.id = v_stage;
    if coalesce(v_stage_failed, false) or now() - v_run.started_at > interval '10 minutes' then
      update t1_private.catalog_runs set status = 'failed', error = 'no answer from worker (stage)', finished_at = now()
       where id = v_run.id;
      if (select count(*) from t1_private.catalog_runs
           where bulk_updated_at = v_run.bulk_updated_at and error = 'no answer from worker (stage)') < 3 then
        -- Posted again, so the bug sweep leaves the failed answer out (a last try that fails is still filed).
        if coalesce(v_stage_failed, false) then
          insert into t1_private.net_retried (request_id) values (v_stage) on conflict do nothing;
        end if;
        perform t1_private.catalog_stage_post();
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
