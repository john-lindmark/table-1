-- A new set's cards right away (John, 2026-10-30: "get the cardlist from scryfall for new sets immediately";
-- contract/catalog-2026-10-14.md § New sets). The catalog follows Scryfall's daily bulk file, so a set announced or
-- spoiled during the day waited up to a day (and the cards a phone has until its next pack) before it could be ranked,
-- searched or scanned. Now:
--  - sets-sync reads Scryfall's set list every hour (was daily at 09:41).
--  - Every hour cards-sync {step:"sets"} asks catalog_set_gaps() for paper sets released in the last 30 days or the
--    next 60 whose Scryfall card count changed since we last fetched them and is above what we hold, reads each from
--    Scryfall's search API (e:<code>, every print, about 175 cards a page) into catalog_ingest like a bulk chunk,
--    records the fetch, and rebuilds the catalog pack when cards changed and the newest pack is 2 hours old or more
--    (else `pack_due` asks a later tick to).
--  - Those runs are catalog_runs with status 'sets' (then 'done' / 'failed', or packing through cards-sync's pack step,
--    which finishes them), a status the bulk run's dispatcher and catalog_run_begin never look at, so a set fetch never
--    holds or skips the daily run.
--  - At most 4 sets a tick; none while a bulk run is ingesting (it brings the same cards).

alter table t1_private.catalog_runs drop constraint if exists catalog_runs_status_check;
alter table t1_private.catalog_runs add constraint catalog_runs_status_check
  check (status in ('staging', 'ingesting', 'naming', 'packing', 'done', 'failed', 'sets'));

create table if not exists t1_private.catalog_set_fetches (
  code text primary key,
  card_count integer not null,        -- Scryfall's card_count when we last read the set
  cards integer not null default 0,   -- printings ingested from it
  run_id bigint references t1_private.catalog_runs (id) on delete set null,
  fetched_at timestamptz not null default now()
);

-- Sets to read now, and whether a pack is owed from an earlier set run.
create or replace function public.catalog_set_gaps()
returns jsonb language sql stable security definer set search_path = '' as $$
  with busy as (select exists (select 1 from t1_private.catalog_runs where status in ('staging', 'ingesting', 'naming', 'packing')
                                  or (status = 'sets' and started_at > now() - interval '1 hour')) b),
  latest as (select max(created_at) at from t1_private.catalog_packs)
  select jsonb_build_object(
    'busy', (select b from busy),
    'sets', case when (select b from busy) then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object('code', s.code, 'card_count', s.card_count) order by s.released_at desc, s.code)
        from (select s.code, s.card_count, s.released_at
                from public.mtg_sets s left join t1_private.catalog_set_fetches f on f.code = s.code
               where not s.digital and s.card_count > 0
                 and s.set_type in ('expansion', 'core', 'draft_innovation', 'masters', 'remastered', 'commander', 'funny')
                 and s.released_at between current_date - 30 and current_date + 60
                 and (f.code is null or f.card_count <> s.card_count)
                 and s.card_count > (select count(*) from public.cards c where c.set_code = s.code and c.lang = 'en')
               order by s.released_at desc, s.code limit 4) s), '[]'::jsonb) end,
    'pack_due', not (select b from busy)
      and coalesce((select at from latest) < now() - interval '2 hours', true)
      and exists (select 1 from t1_private.catalog_runs r
                   where r.source_uri = 'scryfall:search' and r.status = 'done' and r.cards_changed + r.oracles_changed > 0
                     and r.started_at > coalesce((select at from latest), '-infinity')));
$$;

-- Opens a set run (null while another is fetching), closing set runs that never finished.
create or replace function public.catalog_sets_begin()
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_id bigint;
begin
  update t1_private.catalog_runs set status = 'failed', error = coalesce(error, 'abandoned'), finished_at = now()
   where status = 'sets' and started_at < now() - interval '1 hour';
  if exists (select 1 from t1_private.catalog_runs where status = 'sets') then return null; end if;
  insert into t1_private.catalog_runs (bulk_updated_at, source_uri, status) values (now(), 'scryfall:search', 'sets')
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.catalog_set_fetched(p_run bigint, p_code text, p_card_count integer, p_cards integer)
returns void language sql security definer set search_path = '' as $$
  insert into t1_private.catalog_set_fetches (code, card_count, cards, run_id, fetched_at)
  values (lower(p_code), p_card_count, p_cards, p_run, now())
  on conflict (code) do update set card_count = excluded.card_count, cards = excluded.cards, run_id = excluded.run_id,
                                   fetched_at = now();
$$;

-- Ends a set run: packs it (cards-sync's pack step then finishes it) or marks it done.
create or replace function public.catalog_sets_finish(p_run bigint, p_pack boolean)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if p_pack then
    perform t1_private.catalog_post(jsonb_build_object('step', 'pack', 'run', p_run));
    return 'packing';
  end if;
  update t1_private.catalog_runs set status = 'done', finished_at = now() where id = p_run and status = 'sets';
  return 'done';
end $$;

create or replace function t1_private.catalog_sets_tick()
returns void language sql security definer set search_path = '' as $$
  select t1_private.catalog_post('{"step":"sets"}'::jsonb);
$$;

do $$
declare f text;
begin
  foreach f in array array['catalog_set_gaps()', 'catalog_sets_begin()', 'catalog_set_fetched(bigint, text, integer, integer)',
                           'catalog_sets_finish(bigint, boolean)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
revoke all on function t1_private.catalog_sets_tick() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 't1-sets-sync') then perform cron.unschedule('t1-sets-sync'); end if;
    perform cron.schedule('t1-sets-sync', '41 * * * *', 'select t1_private.sync_sets()');
    if not exists (select 1 from cron.job where jobname = 't1-catalog-sets') then
      perform cron.schedule('t1-catalog-sets', '47 * * * *', 'select t1_private.catalog_sets_tick()');
    end if;
  end if;
end $$;
