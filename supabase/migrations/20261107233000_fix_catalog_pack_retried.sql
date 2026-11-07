-- Bug #4 reopened again (2026-11-07 23:24, run 43): this time the pack step hit the edge CPU limit (HTTP 546,
-- "CPU Time exceeded") on its way out, after it had published pack v1-be299218e55e and cleaned up the staging
-- files. Nothing was lost, but nobody knew which request was the pack's, so the sweep filed the 546. Worse, a pack
-- step killed *before* publishing was never posted again: the tick ignores runs in 'packing', which sat until the
-- 3-hour timeout failed them. Now catalog_post keeps every pack post's request id (with its run) in
-- t1_private.catalog_pack_posts and the tick reads its answer: a failure after the run is done is noted as retried
-- (nothing lost), a failure while still packing is posted again (three tries per run) and noted as retried, and a
-- third failure is filed and fails the run. catalog_dispatch is otherwise as in
-- 20261103233000_fix_catalog_stage_retried.sql; catalog_post as in 20261030010000_fix_catalog_chunk_answer.sql.

create table if not exists t1_private.catalog_pack_posts (
  request_id bigint primary key,
  run_id bigint not null,
  posted_at timestamptz not null default now(),
  handled boolean not null default false
);
create index if not exists catalog_pack_posts_open on t1_private.catalog_pack_posts (request_id) where not handled;
alter table t1_private.catalog_pack_posts enable row level security;
revoke all on t1_private.catalog_pack_posts from public, anon, authenticated;

create or replace function t1_private.catalog_post(p_body jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_id bigint;
begin
  v_id := t1_private.catalog_post_id(p_body);
  if p_body->>'step' = 'pack' and p_body ? 'run' then
    insert into t1_private.catalog_pack_posts (request_id, run_id) values (v_id, (p_body->>'run')::bigint);
    delete from t1_private.catalog_pack_posts where posted_at < now() - interval '7 days';
  end if;
end $$;
revoke all on function t1_private.catalog_post(jsonb) from public, anon, authenticated;

create or replace function t1_private.catalog_dispatch()
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_run t1_private.catalog_runs;
  v_free integer;
  v_n integer;
  v_stage bigint;
  v_stage_failed boolean;
  v_pack record;
begin
  -- A pack post the edge answered with a failure. Killed after publishing (run done): nothing was lost, so it is
  -- noted as retried. Killed while still packing: posted again (three tries per run), the failure noted as
  -- retried; the third is left for the sweep and fails the run. A pack that threw (run failed) is filed as before.
  for v_pack in
    select p.request_id, p.run_id, cr.status
      from t1_private.catalog_pack_posts p
      join net._http_response r on r.id = p.request_id
      join t1_private.catalog_runs cr on cr.id = p.run_id
     where not p.handled
       and (coalesce(r.status_code, 0) >= 500 or coalesce(r.timed_out, false) or r.error_msg is not null
            or coalesce(r.status_code, 0) = 0)
       for update of p skip locked
  loop
    update t1_private.catalog_pack_posts set handled = true where request_id = v_pack.request_id;
    if v_pack.status = 'done' then
      insert into t1_private.net_retried (request_id) values (v_pack.request_id) on conflict do nothing;
    elsif v_pack.status in ('packing', 'sets') then
      if (select count(*) from t1_private.catalog_pack_posts where run_id = v_pack.run_id) < 3 then
        insert into t1_private.net_retried (request_id) values (v_pack.request_id) on conflict do nothing;
        perform t1_private.catalog_post(jsonb_build_object('step', 'pack', 'run', v_pack.run_id));
      else
        update t1_private.catalog_runs set status = 'failed', error = 'no answer from worker (pack)',
               finished_at = now()
         where id = v_pack.run_id and status in ('packing', 'sets');
      end if;
    end if;
  end loop;

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
