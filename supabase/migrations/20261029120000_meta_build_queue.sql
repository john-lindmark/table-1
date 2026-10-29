-- Bug #18: t1-meta-build posted one meta-sync build per enabled format in the same instant, and the edge runtime
-- refused to boot most of a cold burst (HTTP 503 BOOT_ERROR after 10 s): at 00:17 on 2026-10-29 three of five
-- formats never built, and a build by hand did the same. meta_build() now only queues the enabled formats; the
-- every-minute t1-meta-build-next sends one build at a time, waits for its answer, and puts a failed one back
-- (three tries, then it waits for the next 6-hourly queue; the failure still reaches the bug register).

create table if not exists t1_private.meta_build_queue (
  format text primary key,
  queued_at timestamptz not null default now(),
  asked_at timestamptz,
  request_id bigint,
  tries integer not null default 0
);
alter table t1_private.meta_build_queue enable row level security;

-- insights_post, returning pg_net's request id so a caller can read the answer from net._http_response.
create or replace function t1_private.insights_post_id(p_fn text, p_body jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  select value into v_secret from t1_private.settings where name = 'live_push_secret';
  return net.http_post(
    url := 'https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/' || p_fn,
    body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-t1-secret', v_secret),
    timeout_milliseconds := 150000);
end $$;

create or replace function t1_private.insights_post(p_fn text, p_body jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform t1_private.insights_post_id(p_fn, p_body);
end $$;

-- Queues every enabled format (a format already queued keeps its place and tries).
create or replace function t1_private.meta_build()
returns void language sql security definer set search_path = '' as $$
  insert into t1_private.meta_build_queue (format)
  select format from t1_private.meta_formats where enabled
  on conflict (format) do nothing;
$$;

-- One build in flight at a time. A 2xx answer takes the format off the queue; a failed one (5xx, timed out) or
-- one with no answer after 5 minutes goes back for another try.
create or replace function t1_private.meta_build_next()
returns void language plpgsql security definer set search_path = '' as $$
declare v_format text; v_id bigint;
begin
  delete from t1_private.meta_build_queue q
   using net._http_response r
   where r.id = q.request_id and r.status_code between 200 and 299 and not coalesce(r.timed_out, false);
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

revoke all on function t1_private.insights_post_id(text, jsonb) from public, anon, authenticated;
revoke all on function t1_private.meta_build_next() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-meta-build-next') then
      perform cron.schedule('t1-meta-build-next', '* * * * *',
        'select t1_private.meta_build_next() where exists (select 1 from t1_private.meta_build_queue)');
    end if;
  end if;
end $$;
