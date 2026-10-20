-- Bug #4: the daily stage step can be killed by the edge CPU limit (HTTP 546 WORKER_RESOURCE_LIMIT), which never
-- reaches catalog_run_fail, so its run sat in 'staging' for 3 hours and the day's prices were skipped. The tick now
-- fails a stage that has been quiet for 10 minutes (a stage takes about a minute) and posts it again, up to three
-- tries per bulk file. Otherwise the same as 20261016180000_printed_names.sql.
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

  update t1_private.catalog_chunks
     set status = case when attempts >= 3 then 'failed' else 'pending' end,
         error = coalesce(error, 'no answer from worker')
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
    update t1_private.catalog_chunks set status = 'running', attempts = attempts + 1, started_at = now(), error = null
     where run_id = v_run.id and n = v_n;
    perform t1_private.catalog_post(jsonb_build_object('step', 'chunk', 'run', v_run.id, 'n', v_n));
  end loop;
end $$;
