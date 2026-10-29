-- Bug #18 (cards-sync): the dispatcher sends three chunks at once, and on 2026-10-29 the edge runtime refused one
-- of the three cold boots (HTTP 503 BOOT_ERROR after 10 s, run 29 chunk 2). The chunk kept its 'running' status
-- until the tick called it quiet five minutes later, which held the daily run for those five minutes. Now every
-- chunk remembers the pg_net request id of its post and the tick reads the answer: a failed one (5xx, timed out,
-- never connected) puts the chunk back at once (three tries, as before); a silent one still waits five minutes.
-- Otherwise the same as 20261020001000_fix_catalog_stage_retry.sql.

alter table t1_private.catalog_chunks add column if not exists request_id bigint;

-- catalog_post, returning pg_net's request id so a caller can read the answer from net._http_response.
create or replace function t1_private.catalog_post_id(p_body jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  select value into v_secret from t1_private.settings where name = 'live_push_secret';
  return net.http_post(
    url := 'https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/cards-sync',
    body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-t1-secret', v_secret),
    timeout_milliseconds := 150000);
end $$;

create or replace function t1_private.catalog_post(p_body jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform t1_private.catalog_post_id(p_body);
end $$;

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

revoke all on function t1_private.catalog_post_id(jsonb) from public, anon, authenticated;
