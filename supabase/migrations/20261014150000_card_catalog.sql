-- L0 card catalog (plan-collection-2026-10-14.md §3).
-- Scryfall default_cards (paper printings only) → card_oracles / cards / card_prices, refreshed daily by the
-- cards-sync edge function in steps that each fit the edge CPU budget:
--   stage  : stream the gzipped JSONL, split it into ~32MB line-aligned pieces in the catalog-staging bucket
--   chunk  : parse one piece, upsert in batches through catalog_ingest (diffed by content hash)
--   pack   : build the gzipped TSV catalog pack clients download (public catalog bucket)
-- t1_private.catalog_dispatch() fans chunks out through pg_net, three at a time.

create extension if not exists pg_trgm with schema extensions;

-- ==================================================================== a_norm
-- Card-name normalization. Clients must implement the same steps (contract/catalog-2026-10-14.md):
-- NFKD, drop combining marks, lowercase, æ→ae œ→oe, drop apostrophes, any other non [a-z0-9] run → one space, trim.
create or replace function public.card_name_norm(p text)
returns text language sql immutable parallel safe set search_path = '' as $$
  select trim(regexp_replace(
           regexp_replace(
             replace(replace(regexp_replace(lower(normalize(coalesce(p, ''), NFKD)), '[\u0300-\u036f]', '', 'g'),
                     'æ', 'ae'), 'œ', 'oe'),
             '[''’]', '', 'g'),
           '[^a-z0-9]+', ' ', 'g'));
$$;
grant execute on function public.card_name_norm(text) to anon, authenticated;

-- ==================================================================== b_tables
-- One row per Oracle card (rules object). Search and deck stats work at this level.
create table if not exists public.card_oracles (
  oracle_id uuid primary key,
  name text not null,
  name_norm text not null,
  face_names text[] not null default '{}',
  layout text not null,
  type_line text,
  mana_cost text,
  cmc numeric,                                 -- unbounded: Gleemax is 1,000,000
  colors text[] not null default '{}',
  color_identity text[] not null default '{}',
  legalities jsonb not null default '{}'::jsonb,  -- only formats where the card is legal/restricted/banned
  -- Printings disagree on Oracle-level fields for ~600 cards (reversible "X // X" printings, 30th Anniversary
  -- and other non-legal printings). The row always comes from the best-ranked printing seen, so the result is
  -- the same whatever order chunks land in (t1_private.catalog_source_rank); the source printing itself may
  -- always update the row, so a rank that drops (rotation) never freezes stale data.
  source_card_id uuid not null,
  source_rank text not null,
  content_hash text not null,
  updated_at timestamptz not null default now()
);

-- Search index: the full name plus each face name ("Fire // Ice" → "fire ice", "fire", "ice").
create table if not exists public.card_names (
  name_norm text not null,
  oracle_id uuid not null references public.card_oracles(oracle_id) on delete cascade,
  is_face boolean not null default false,
  primary key (name_norm, oracle_id)
);
create index if not exists card_names_trgm_idx on public.card_names using gin (name_norm extensions.gin_trgm_ops);
create index if not exists card_names_prefix_idx on public.card_names (name_norm text_pattern_ops);
create index if not exists card_names_oracle_idx on public.card_names (oracle_id);

-- One row per paper printing. Never deleted: collection rows will reference these ids.
create table if not exists public.cards (
  id uuid primary key,                         -- Scryfall card id
  oracle_id uuid not null references public.card_oracles(oracle_id),
  set_code text not null,
  collector_number text not null,
  lang text not null,
  rarity text not null,
  finishes text[] not null,
  layout text not null,
  printed_name text,                           -- non-English printings only
  released_at date,
  image_ts bigint,                             -- cards.scryfall.io cache-buster; null = no image
  image_faces smallint not null default 1,     -- 0 none, 1 front, 2 front + back
  content_hash text not null,
  updated_at timestamptz not null default now(),
  unique (set_code, collector_number, lang)
);
create index if not exists cards_oracle_idx on public.cards (oracle_id, released_at desc);

-- Prices change daily; kept apart so price churn never rewrites card rows.
create table if not exists public.card_prices (
  card_id uuid primary key references public.cards(id),
  usd numeric(10,2), usd_foil numeric(10,2), usd_etched numeric(10,2),
  eur numeric(10,2), eur_foil numeric(10,2),
  updated_at timestamptz not null default now()
);

alter table public.card_oracles enable row level security;
alter table public.card_names enable row level security;
alter table public.cards enable row level security;
alter table public.card_prices enable row level security;
do $$
declare t text;
begin
  foreach t in array array['card_oracles', 'card_names', 'cards', 'card_prices'] loop
    if not exists (select 1 from pg_policies where tablename = t and policyname = t || '_read') then
      execute format('create policy %I on public.%I for select to anon, authenticated using (true)', t || '_read', t);
    end if;
  end loop;
end $$;

-- ==================================================================== c_runs
create table if not exists t1_private.catalog_runs (
  id bigserial primary key,
  bulk_updated_at timestamptz not null,
  source_uri text not null,
  status text not null default 'staging'
    check (status in ('staging', 'ingesting', 'packing', 'done', 'failed')),
  chunks integer,
  rows_in integer not null default 0,
  oracles_changed integer not null default 0,
  cards_changed integer not null default 0,
  prices_changed integer not null default 0,
  error text,
  started_at timestamptz not null default now(),
  finished_at timestamptz
);
create table if not exists t1_private.catalog_chunks (
  run_id bigint not null references t1_private.catalog_runs(id) on delete cascade,
  n integer not null,
  status text not null default 'pending' check (status in ('pending', 'running', 'done', 'failed')),
  attempts integer not null default 0,
  started_at timestamptz,
  finished_at timestamptz,
  error text,
  primary key (run_id, n)
);
create index if not exists catalog_chunks_open_idx on t1_private.catalog_chunks (run_id, n)
  where status in ('pending', 'running');

create table if not exists t1_private.catalog_packs (
  version text primary key,                    -- 'v1-' || first 12 hex of sha256
  format integer not null,
  path text not null,                          -- object path in the public catalog bucket
  bytes integer not null,
  sha256 text not null,
  oracles integer not null,
  printings integer not null,
  run_id bigint references t1_private.catalog_runs(id) on delete set null,
  created_at timestamptz not null default now()
);

insert into storage.buckets (id, name, public, file_size_limit)
values ('catalog', 'catalog', true, 52428800), ('catalog-staging', 'catalog-staging', false, 52428800)
on conflict (id) do nothing;

-- ==================================================================== d_dispatch
create or replace function t1_private.catalog_post(p_body jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  select value into v_secret from t1_private.settings where name = 'live_push_secret';
  perform net.http_post(
    url := 'https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/cards-sync',
    body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-t1-secret', v_secret),
    timeout_milliseconds := 150000);
end $$;

-- Claims pending chunks up to three in flight and re-queues ones that went quiet (edge worker killed).
-- Cheap when idle: one lookup on the partial index.
create or replace function t1_private.catalog_dispatch()
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_run t1_private.catalog_runs;
  v_free integer;
  v_n integer;
begin
  select * into v_run from t1_private.catalog_runs
   where status in ('staging', 'ingesting', 'packing') order by id desc limit 1;
  if v_run.id is null then return; end if;

  if now() - v_run.started_at > interval '3 hours' then
    update t1_private.catalog_runs set status = 'failed', error = coalesce(error, 'timed out'), finished_at = now()
     where id = v_run.id;
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

create or replace function t1_private.sync_catalog()
returns void language sql security definer set search_path = '' as $$
  select t1_private.catalog_post('{"step":"stage"}'::jsonb);
$$;

-- ==================================================================== e_worker_rpcs
-- Called only by cards-sync with the service role.

-- Opens a run for a new bulk file. Null when this file is already done or another run is in flight.
create or replace function public.catalog_run_begin(p_bulk_updated_at timestamptz, p_source_uri text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_id bigint;
begin
  update t1_private.catalog_runs set status = 'failed', error = coalesce(error, 'abandoned'), finished_at = now()
   where status in ('staging', 'ingesting', 'packing') and started_at < now() - interval '3 hours';
  if exists (select 1 from t1_private.catalog_runs where status in ('staging', 'ingesting', 'packing')) then
    return null;
  end if;
  if exists (select 1 from t1_private.catalog_runs where status = 'done' and bulk_updated_at = p_bulk_updated_at) then
    return null;
  end if;
  insert into t1_private.catalog_runs (bulk_updated_at, source_uri) values (p_bulk_updated_at, p_source_uri)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.catalog_run_staged(p_run bigint, p_chunks integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update t1_private.catalog_runs set status = 'ingesting', chunks = p_chunks where id = p_run and status = 'staging';
  insert into t1_private.catalog_chunks (run_id, n) select p_run, g from generate_series(0, p_chunks - 1) g
  on conflict do nothing;
  perform t1_private.catalog_dispatch();
end $$;

create or replace function public.catalog_run_fail(p_run bigint, p_error text)
returns void language sql security definer set search_path = '' as $$
  update t1_private.catalog_runs set status = 'failed', error = left(p_error, 500), finished_at = now()
   where id = p_run and status <> 'done';
$$;

-- Slim rows sent by cards-sync (see cards-sync/catalog.ts SlimCard), as a relation.
create or replace function t1_private.catalog_rows(p_rows jsonb)
returns table (
  id uuid, oracle_id uuid, name text, face_names text[], layout text, type_line text, mana_cost text,
  cmc numeric, colors text[], color_identity text[], legalities jsonb,
  set_code text, collector_number text, lang text, rarity text, finishes text[], printed_name text,
  released_at date, image_ts bigint, image_faces smallint,
  usd numeric, usd_foil numeric, usd_etched numeric, eur numeric, eur_foil numeric)
language sql immutable set search_path = '' as $$
  select * from jsonb_to_recordset(p_rows) as r (
    id uuid, oracle_id uuid, name text, face_names text[], layout text, type_line text, mana_cost text,
    cmc numeric, colors text[], color_identity text[], legalities jsonb,
    set_code text, collector_number text, lang text, rarity text, finishes text[], printed_name text,
    released_at date, image_ts bigint, image_faces smallint,
    usd numeric, usd_foil numeric, usd_etched numeric, eur numeric, eur_foil numeric);
$$;

-- Higher is better: not a reversible printing, legal in more formats, English, newest; card id breaks ties,
-- so an equal rank always means the same source printing.
create or replace function t1_private.catalog_source_rank(
  p_layout text, p_legalities jsonb, p_lang text, p_released date, p_id uuid)
returns text language sql immutable set search_path = '' as $$
  select (case when p_layout = 'reversible_card' then '0' else '1' end)
      || lpad((select count(*) from jsonb_object_keys(coalesce(p_legalities, '{}'::jsonb)))::text, 2, '0')
      || (case when p_lang = 'en' then '1' else '0' end)
      || coalesce(p_released::text, '0000-00-00')
      || p_id::text;
$$;

-- Upserts one batch. Only rows whose content changed are written, so a daily run mostly touches prices.
create or replace function public.catalog_ingest(p_run bigint, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_changed uuid[];
  v_cards integer;
  v_prices integer;
begin
  with ranked as (
    select r.*, t1_private.catalog_source_rank(r.layout, r.legalities, r.lang, r.released_at, r.id) rnk
      from t1_private.catalog_rows(p_rows) r
  ), src as (
    select distinct on (r.oracle_id) r.oracle_id, r.name, coalesce(r.face_names, '{}') face_names, r.layout,
           r.type_line, r.mana_cost, r.cmc, coalesce(r.colors, '{}') colors,
           coalesce(r.color_identity, '{}') color_identity, coalesce(r.legalities, '{}'::jsonb) legalities, r.rnk, r.id
      from ranked r
     order by r.oracle_id, r.rnk desc
  ), up as (
    insert into public.card_oracles as o (oracle_id, name, name_norm, face_names, layout, type_line, mana_cost, cmc,
                                          colors, color_identity, legalities, source_card_id, source_rank,
                                          content_hash)
    select s.oracle_id, s.name, public.card_name_norm(s.name), s.face_names, s.layout, s.type_line, s.mana_cost,
           s.cmc, s.colors, s.color_identity, s.legalities, s.id, s.rnk,
           md5(jsonb_build_array(s.name, s.face_names, s.layout, s.type_line, s.mana_cost, s.cmc, s.colors,
                                 s.color_identity, s.legalities)::text)
      from src s
    on conflict (oracle_id) do update
       set name = excluded.name, name_norm = excluded.name_norm, face_names = excluded.face_names,
           layout = excluded.layout, type_line = excluded.type_line, mana_cost = excluded.mana_cost,
           cmc = excluded.cmc, colors = excluded.colors, color_identity = excluded.color_identity,
           legalities = excluded.legalities, source_card_id = excluded.source_card_id, source_rank = excluded.source_rank,
           content_hash = excluded.content_hash, updated_at = now()
     where excluded.source_rank > o.source_rank
        or (excluded.source_card_id = o.source_card_id and o.content_hash is distinct from excluded.content_hash)
    returning o.oracle_id
  )
  select coalesce(array_agg(up.oracle_id), '{}') into v_changed from up;

  if cardinality(v_changed) > 0 then
    delete from public.card_names n where n.oracle_id = any(v_changed);
    insert into public.card_names (name_norm, oracle_id, is_face)
    select distinct on (v.nm, o.oracle_id) v.nm, o.oracle_id, v.f
      from public.card_oracles o,
           lateral (select o.name_norm nm, false f
                    union all
                    select public.card_name_norm(x), true from unnest(o.face_names) x) v
     where o.oracle_id = any(v_changed) and v.nm <> ''
     order by v.nm, o.oracle_id, v.f
    on conflict do nothing;
  end if;

  with up as (
    insert into public.cards as c (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout,
                                   printed_name, released_at, image_ts, image_faces, content_hash)
    select r.id, r.oracle_id, r.set_code, r.collector_number, r.lang, r.rarity, r.finishes, r.layout,
           r.printed_name, r.released_at, r.image_ts, coalesce(r.image_faces, 1),
           md5(jsonb_build_array(r.oracle_id, r.set_code, r.collector_number, r.lang, r.rarity, r.finishes,
                                 r.layout, r.printed_name, r.released_at, r.image_ts, r.image_faces)::text)
      from t1_private.catalog_rows(p_rows) r
    on conflict (id) do update
       set oracle_id = excluded.oracle_id, set_code = excluded.set_code, collector_number = excluded.collector_number,
           lang = excluded.lang, rarity = excluded.rarity, finishes = excluded.finishes, layout = excluded.layout,
           printed_name = excluded.printed_name, released_at = excluded.released_at, image_ts = excluded.image_ts,
           image_faces = excluded.image_faces, content_hash = excluded.content_hash, updated_at = now()
     where c.content_hash is distinct from excluded.content_hash
    returning 1
  )
  select count(*) into v_cards from up;

  with up as (
    insert into public.card_prices as p (card_id, usd, usd_foil, usd_etched, eur, eur_foil)
    select r.id, r.usd, r.usd_foil, r.usd_etched, r.eur, r.eur_foil from t1_private.catalog_rows(p_rows) r
    on conflict (card_id) do update
       set usd = excluded.usd, usd_foil = excluded.usd_foil, usd_etched = excluded.usd_etched,
           eur = excluded.eur, eur_foil = excluded.eur_foil, updated_at = now()
     where (p.usd, p.usd_foil, p.usd_etched, p.eur, p.eur_foil)
           is distinct from (excluded.usd, excluded.usd_foil, excluded.usd_etched, excluded.eur, excluded.eur_foil)
    returning 1
  )
  select count(*) into v_prices from up;

  update t1_private.catalog_runs
     set rows_in = rows_in + jsonb_array_length(p_rows), oracles_changed = oracles_changed + cardinality(v_changed),
         cards_changed = cards_changed + v_cards, prices_changed = prices_changed + v_prices
   where id = p_run;
  return jsonb_build_object('oracles', cardinality(v_changed), 'cards', v_cards, 'prices', v_prices);
end $$;

-- Marks a chunk finished. When the last one lands, asks for a pack if anything but prices changed
-- (or no pack exists yet); otherwise closes the run. Then hands the free slot to the next chunk.
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
    if v_run.oracles_changed + v_run.cards_changed > 0 or not exists (select 1 from t1_private.catalog_packs) then
      update t1_private.catalog_runs set status = 'packing' where id = p_run;
      perform t1_private.catalog_post(jsonb_build_object('step', 'pack', 'run', p_run));
    else
      update t1_private.catalog_runs set status = 'done', finished_at = now() where id = p_run;
      perform t1_private.catalog_post(jsonb_build_object('step', 'cleanup', 'run', p_run));
    end if;
    return;
  end if;
  perform t1_private.catalog_dispatch();
end $$;

-- Catalog pack v1 body, one line per row, in pack order: O (oracle) lines, then P (printing) lines that
-- point at their oracle by O-line index. Format spec: contract/catalog-2026-10-14.md.
-- One text value (the API caps set results at 1000 rows); about 13MB today.
create or replace function public.catalog_pack_body()
returns text language sql stable security definer set search_path = '' as $$
  with o as (
    select oracle_id, name, name_norm, face_names, type_line, mana_cost, cmc, colors,
           (row_number() over (order by name_norm, oracle_id)) - 1 idx
      from public.card_oracles
  )
  select string_agg(line, E'\n' order by k, idx, d desc nulls last, s, cn) from (
    select 0 k, o.idx, null::date d, null::text s, null::text cn,
           concat_ws(E'\t', 'O', o.idx, o.oracle_id, translate(o.name, E'\t\n\r', '   '), o.name_norm,
                     translate(coalesce(o.type_line, ''), E'\t\n\r', '   '), coalesce(o.mana_cost, ''),
                     coalesce(o.cmc::text, ''), array_to_string(o.colors, ''),
                     array_to_string(o.face_names, ' // ')) line
      from o
    union all
    select 1, o.idx, c.released_at, c.set_code, c.collector_number,
           concat_ws(E'\t', 'P', c.id, o.idx, c.set_code, c.collector_number, c.lang, left(c.rarity, 1),
                     (select string_agg(left(f, 1), '' order by f) from unnest(c.finishes) f),
                     coalesce(c.released_at::text, ''), coalesce(c.image_ts::text, ''), c.image_faces,
                     translate(coalesce(c.printed_name, ''), E'\t\n\r', '   '))
      from public.cards c join o on o.oracle_id = c.oracle_id
  ) t;
$$;

-- Records a pack (an empty path means the content was unchanged: only the run closes) and returns object
-- paths of packs beyond the newest three, which the caller deletes from storage.
create or replace function public.catalog_pack_publish(
  p_run bigint, p_version text, p_path text, p_bytes integer, p_sha256 text, p_oracles integer, p_printings integer)
returns text[] language plpgsql security definer set search_path = '' as $$
declare v_stale text[];
begin
  if coalesce(p_path, '') <> '' then
    insert into t1_private.catalog_packs (version, format, path, bytes, sha256, oracles, printings, run_id)
    values (p_version, 1, p_path, p_bytes, p_sha256, p_oracles, p_printings, p_run)
    on conflict (version) do nothing;
  end if;
  update t1_private.catalog_runs set status = 'done', finished_at = now() where id = p_run;
  with old as (
    delete from t1_private.catalog_packs
     where version in (select version from t1_private.catalog_packs order by created_at desc offset 3)
    returning path
  )
  select coalesce(array_agg(path), '{}') into v_stale from old;
  return v_stale;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'catalog_run_begin(timestamptz, text)', 'catalog_run_staged(bigint, integer)', 'catalog_run_fail(bigint, text)',
    'catalog_ingest(bigint, jsonb)', 'catalog_chunk_finish(bigint, integer, text)', 'catalog_pack_body()',
    'catalog_pack_publish(bigint, text, text, integer, text, integer, integer)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- ==================================================================== f_client_rpcs
-- Latest catalog pack. Clients compare version with what they hold and download only on change.
create or replace function public.catalog_info()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
           'version', p.version, 'format', p.format,
           'url', 'https://aaozhfcbvqrgkkrihkrd.supabase.co/storage/v1/object/public/catalog/' || p.path,
           'bytes', p.bytes, 'sha256', p.sha256, 'oracles', p.oracles, 'printings', p.printings,
           'created_at', p.created_at)
    from t1_private.catalog_packs p order by p.created_at desc limit 1;
$$;
grant execute on function public.catalog_info() to anon, authenticated;

-- Name typeahead over Oracle cards: prefix matches first, then trigram matches by similarity; tokens, emblems
-- and art-series cards sort after real cards. default_card_id is the newest English printing, for a thumbnail.
create or replace function public.search_cards(p_query text, p_limit integer default 20)
returns table (oracle_id uuid, name text, type_line text, mana_cost text,
               default_card_id uuid, image_ts bigint, image_faces smallint)
language sql stable security definer set search_path = '' as $$
  with q as (select public.card_name_norm(p_query) q),
  hits as (
    select n.oracle_id, min(case when n.name_norm like (select q from q) || '%' then 0 else 1 end) rank,
           max(extensions.similarity(n.name_norm, (select q from q))) sim
      from public.card_names n
     where char_length((select q from q)) >= 2
       and (n.name_norm like (select q from q) || '%'
            or n.name_norm operator(extensions.%) (select q from q))
     group by n.oracle_id
  ), top as (
    select h.*, o.name, o.type_line, o.mana_cost,
           o.layout in ('token', 'double_faced_token', 'emblem', 'art_series') extra
      from hits h join public.card_oracles o on o.oracle_id = h.oracle_id
     order by h.rank, extra, h.sim desc, o.name
     limit least(greatest(coalesce(p_limit, 20), 1), 50)
  )
  select t.oracle_id, t.name, t.type_line, t.mana_cost, c.id, c.image_ts, c.image_faces
    from top t
    left join lateral (
      select c.id, c.image_ts, c.image_faces from public.cards c
       where c.oracle_id = t.oracle_id
       order by (c.lang = 'en') desc, (c.image_ts is not null) desc, c.released_at desc nulls last
       limit 1) c on true
   order by t.rank, t.extra, t.sim desc, t.name;
$$;
grant execute on function public.search_cards(text, integer) to anon, authenticated;

-- All paper printings of one card, newest first, with prices.
create or replace function public.card_printings(p_oracle_id uuid)
returns table (id uuid, set_code text, set_name text, collector_number text, lang text, rarity text,
               finishes text[], released_at date, image_ts bigint, image_faces smallint,
               usd numeric, usd_foil numeric, eur numeric, eur_foil numeric)
language sql stable security definer set search_path = '' as $$
  select c.id, c.set_code, s.name, c.collector_number, c.lang, c.rarity, c.finishes, c.released_at,
         c.image_ts, c.image_faces, p.usd, p.usd_foil, p.eur, p.eur_foil
    from public.cards c
    left join public.mtg_sets s on s.code = c.set_code
    left join public.card_prices p on p.card_id = c.id
   where c.oracle_id = p_oracle_id
   order by c.released_at desc nulls last, c.set_code, c.collector_number;
$$;
grant execute on function public.card_printings(uuid) to anon, authenticated;

-- ==================================================================== g_cron
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-catalog-sync') then
      -- Scryfall regenerates bulk files daily around 21:00 UTC.
      perform cron.schedule('t1-catalog-sync', '23 23 * * *', 'select t1_private.sync_catalog()');
    end if;
    if not exists (select 1 from cron.job where jobname = 't1-catalog-tick') then
      perform cron.schedule('t1-catalog-tick', '*/2 * * * *', 'select t1_private.catalog_dispatch()');
    end if;
  end if;
end $$;
