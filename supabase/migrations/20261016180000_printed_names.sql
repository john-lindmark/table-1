-- Printed names in other languages, for the scanner (contract/catalog-2026-10-14.md, N lines).
-- cards-sync reads them from Scryfall's all_cards file (~400MB gzipped, ~3GB of JSON) in a chain of "names"
-- steps: each range-fetches ~12MB of the gzip from the previous step's checkpoint (cards-sync/inflate.ts),
-- inflates it, keeps de/es/fr/it/pt/ru printings and upserts their names. The pass runs at most weekly, after a
-- daily run's card chunks and before its pack; a failed pass never holds back the pack.

-- ==================================================================== a_tables
create table if not exists t1_private.card_printed_names (
  oracle_id uuid not null references public.card_oracles(oracle_id) on delete cascade,
  lang text not null,
  printed_name text not null,
  seen_run bigint not null,                    -- last names pass that saw it; older rows are pruned
  primary key (oracle_id, lang, printed_name)
);

alter table t1_private.catalog_runs add column if not exists names_changed integer not null default 0;
alter table t1_private.catalog_runs add column if not exists names_at timestamptz;   -- names pass completed
alter table t1_private.catalog_runs drop constraint if exists catalog_runs_status_check;
alter table t1_private.catalog_runs add constraint catalog_runs_status_check
  check (status in ('staging', 'ingesting', 'naming', 'packing', 'done', 'failed'));

-- Where the names pass stands: the next deflate block's absolute bit offset, the 32KB window before it and the
-- partial JSON line it cut, so the next step resumes exactly there.
create table if not exists t1_private.catalog_names_cursor (
  run_id bigint primary key references t1_private.catalog_runs(id) on delete cascade,
  uri text,
  bit bigint,
  win bytea not null default '',
  carry bytea not null default '',
  step integer not null default 0,
  attempts integer not null default 0,
  rows_in integer not null default 0,
  error text,
  updated_at timestamptz not null default now()
);

-- ==================================================================== b_flow
-- Due when no pass completed in the last six and a half days.
create or replace function t1_private.catalog_names_due()
returns boolean language sql stable security definer set search_path = '' as $$
  select not exists (select 1 from t1_private.catalog_runs where names_at > now() - interval '6 days 12 hours');
$$;

-- After the card chunks (and the names pass, if any): pack when anything but prices changed or there's no pack.
create or replace function t1_private.catalog_run_finish(p_run bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare v_run t1_private.catalog_runs;
begin
  select * into v_run from t1_private.catalog_runs where id = p_run for update;
  if v_run.status not in ('ingesting', 'naming') then return; end if;
  if v_run.oracles_changed + v_run.cards_changed + v_run.names_changed > 0
     or not exists (select 1 from t1_private.catalog_packs) then
    update t1_private.catalog_runs set status = 'packing' where id = p_run;
    perform t1_private.catalog_post(jsonb_build_object('step', 'pack', 'run', p_run));
  else
    update t1_private.catalog_runs set status = 'done', finished_at = now() where id = p_run;
    perform t1_private.catalog_post(jsonb_build_object('step', 'cleanup', 'run', p_run));
  end if;
end $$;

create or replace function public.catalog_chunk_finish(p_run bigint, p_n integer, p_error text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_run t1_private.catalog_runs;
begin
  update t1_private.catalog_chunks
     set status = case when p_error is null then 'done' when attempts >= 3 then 'failed' else 'pending' end,
         finished_at = now(), error = left(p_error, 500)
   where run_id = p_run and n = p_n and status = 'running';

  select * into v_run from t1_private.catalog_runs where id = p_run for update;
  if v_run.status = 'ingesting'
     and not exists (select 1 from t1_private.catalog_chunks where run_id = p_run and status <> 'done') then
    if t1_private.catalog_names_due() then
      update t1_private.catalog_runs set status = 'naming' where id = p_run;
      insert into t1_private.catalog_names_cursor (run_id) values (p_run) on conflict do nothing;
      perform t1_private.catalog_post(jsonb_build_object('step', 'names', 'run', p_run));
    else
      perform t1_private.catalog_run_finish(p_run);
    end if;
    return;
  end if;
  perform t1_private.catalog_dispatch();
end $$;

-- Claims pending chunks up to three in flight and re-queues ones that went quiet (edge worker killed); during
-- the names pass, re-posts a step that went quiet. Cheap when idle: one lookup on the partial index.
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

-- A names step failed or went quiet: try it again, up to three times, then give up on names for this run (the
-- next daily run tries again) and go on to the pack.
create or replace function t1_private.catalog_names_retry(p_run bigint, p_error text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_attempts integer;
begin
  update t1_private.catalog_names_cursor
     set attempts = attempts + 1, error = left(p_error, 500), updated_at = now()
   where run_id = p_run
  returning attempts into v_attempts;
  if v_attempts is null then return; end if;
  if v_attempts >= 3 then
    perform t1_private.catalog_run_finish(p_run);
  else
    perform t1_private.catalog_post(jsonb_build_object('step', 'names', 'run', p_run));
  end if;
end $$;

create or replace function public.catalog_run_begin(p_bulk_updated_at timestamptz, p_source_uri text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_id bigint;
begin
  update t1_private.catalog_runs set status = 'failed', error = coalesce(error, 'abandoned'), finished_at = now()
   where status in ('staging', 'ingesting', 'naming', 'packing') and started_at < now() - interval '3 hours';
  if exists (select 1 from t1_private.catalog_runs where status in ('staging', 'ingesting', 'naming', 'packing')) then
    return null;
  end if;
  if exists (select 1 from t1_private.catalog_runs where status = 'done' and bulk_updated_at = p_bulk_updated_at) then
    return null;
  end if;
  insert into t1_private.catalog_runs (bulk_updated_at, source_uri) values (p_bulk_updated_at, p_source_uri)
  returning id into v_id;
  return v_id;
end $$;

-- ==================================================================== c_worker_rpcs
-- Called only by cards-sync with the service role.

-- The names cursor (window and carry as base64), or null when the run isn't in its names pass.
create or replace function public.catalog_names_state(p_run bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('uri', c.uri, 'bit', c.bit, 'step', c.step,
                            'window', encode(c.win, 'base64'), 'carry', encode(c.carry, 'base64'))
    from t1_private.catalog_names_cursor c join t1_private.catalog_runs r on r.id = c.run_id
   where c.run_id = p_run and r.status = 'naming';
$$;

-- Upserts one batch of {oracle_id, lang, printed_name}; returns how many are new. Unknown cards are skipped.
create or replace function public.catalog_names_ingest(p_run bigint, p_rows jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_new integer;
begin
  with r as (
    select distinct x.oracle_id, x.lang, x.printed_name
      from jsonb_to_recordset(p_rows) x (oracle_id uuid, lang text, printed_name text)
      join public.card_oracles o on o.oracle_id = x.oracle_id
     where x.printed_name <> ''
  ), up as (
    insert into t1_private.card_printed_names as n (oracle_id, lang, printed_name, seen_run)
    select r.oracle_id, r.lang, r.printed_name, p_run from r
    on conflict (oracle_id, lang, printed_name) do update set seen_run = excluded.seen_run
     where n.seen_run <> excluded.seen_run
    returning (xmax = 0) inserted
  )
  select count(*) filter (where inserted) into v_new from up;
  update t1_private.catalog_names_cursor set rows_in = rows_in + jsonb_array_length(p_rows) where run_id = p_run;
  update t1_private.catalog_runs set names_changed = names_changed + v_new where id = p_run;
  return v_new;
end $$;

-- Moves the cursor past step p_step (a duplicate or stale step changes nothing). After the last block, prunes
-- names this pass didn't see and finishes the run; otherwise asks for the next step.
create or replace function public.catalog_names_advance(
  p_run bigint, p_step integer, p_uri text, p_bit bigint, p_window text, p_carry text, p_final boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare v_gone integer;
begin
  update t1_private.catalog_names_cursor
     set uri = p_uri, bit = p_bit, win = decode(p_window, 'base64'), carry = decode(p_carry, 'base64'),
         step = step + 1, attempts = 0, error = null, updated_at = now()
   where run_id = p_run and step = p_step;
  if not found then return; end if;
  if p_final then
    with gone as (delete from t1_private.card_printed_names where seen_run < p_run returning 1)
    select count(*) into v_gone from gone;
    update t1_private.catalog_runs set names_changed = names_changed + v_gone, names_at = now() where id = p_run;
    perform t1_private.catalog_run_finish(p_run);
  else
    perform t1_private.catalog_post(jsonb_build_object('step', 'names', 'run', p_run));
  end if;
end $$;

create or replace function public.catalog_names_fail(p_run bigint, p_step integer, p_error text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from t1_private.catalog_names_cursor where run_id = p_run and step = p_step) then
    perform t1_private.catalog_names_retry(p_run, p_error);
  end if;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'catalog_names_state(bigint)', 'catalog_names_ingest(bigint, jsonb)',
    'catalog_names_advance(bigint, integer, text, bigint, text, text, boolean)',
    'catalog_names_fail(bigint, integer, text)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- ==================================================================== d_pack
-- Adds N lines (printed names) after the P lines: names that normalize like the card's English name or one of
-- its faces are left out.
create or replace function public.catalog_pack_body()
returns text language sql stable security definer set search_path = '' as $$
  with o as (
    select oracle_id, name, name_norm, face_names, type_line, mana_cost, cmc, colors, legalities,
           (row_number() over (order by name_norm, oracle_id)) - 1 idx
      from public.card_oracles
  ),
  orig as (
    select distinct on (c.oracle_id) c.id
      from public.cards c left join public.mtg_sets s on s.code = c.set_code
     order by c.oracle_id,
              (c.lang = 'en' and c.image_faces > 0
                 and coalesce(s.set_type, '') not in ('promo', 'token', 'memorabilia', 'alchemy', 'minigame')) desc,
              (c.lang = 'en' and c.image_faces > 0) desc,
              c.released_at nulls last,
              (c.collector_number ~ '^[0-9]+$') desc,
              length(c.collector_number), c.collector_number, c.set_code
  )
  select string_agg(line, E'\n' order by k, idx, d desc nulls last, s, cn) from (
    select 0 k, o.idx, null::date d, null::text s, null::text cn,
           concat_ws(E'\t', 'O', o.idx, o.oracle_id, translate(o.name, E'\t\n\r', '   '), o.name_norm,
                     translate(coalesce(o.type_line, ''), E'\t\n\r', '   '), coalesce(o.mana_cost, ''),
                     coalesce(o.cmc::text, ''), array_to_string(o.colors, ''),
                     array_to_string(o.face_names, ' // '),
                     (select string_agg(case o.legalities->>f when 'legal' then 'L' when 'restricted' then 'R'
                                                               when 'banned' then 'B' else '-' end, '' order by ord)
                        from unnest(array['standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'commander',
                                          'premodern']) with ordinality as fm(f, ord)),
                     coalesce((select fp.points::text from public.format_points fp
                                where fp.format = 'canlander' and fp.oracle_id = o.oracle_id), '')) line
      from o
    union all
    select 1, o.idx, c.released_at, c.set_code, c.collector_number,
           concat_ws(E'\t', 'P', c.id, o.idx, c.set_code, c.collector_number, c.lang, left(c.rarity, 1),
                     (select string_agg(left(f, 1), '' order by f) from unnest(c.finishes) f),
                     coalesce(c.released_at::text, ''), coalesce(c.image_ts::text, ''), c.image_faces,
                     translate(coalesce(c.printed_name, ''), E'\t\n\r', '   '),
                     case when orig.id is not null then '1' else '' end)
      from public.cards c join o on o.oracle_id = c.oracle_id left join orig on orig.id = c.id
    union all
    select 2, o.idx, null, n.lang, n.printed_name,
           concat_ws(E'\t', 'N', o.idx, n.lang, translate(n.printed_name, E'\t\n\r', '   '))
      from t1_private.card_printed_names n join o on o.oracle_id = n.oracle_id
     where public.card_name_norm(n.printed_name) <> o.name_norm
       and not public.card_name_norm(n.printed_name) = any (
             select public.card_name_norm(f) from unnest(o.face_names) f)
  ) t;
$$;
