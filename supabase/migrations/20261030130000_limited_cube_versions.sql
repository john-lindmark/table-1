-- Arena cube versions in Limited Insights (John, 2026-10-30: "consider different versions of the arena cube, right
-- now the data is all collapsed into the same format"; contract/insights-2026-10-24.md § Arena cubes). Arena runs
-- several cubes (Arena Cube, Powered, Planar, …), each now and then with a new card list, and 17Lands publishes each as
-- an expansion ("Cube - Powered" → files named Cube_-_Powered). Every run used to land in one CUBE pack.
--  - t1_private.limited_cubes is now the cube *families* (code, 17Lands file name, name). limited-sync adds the ones
--    17Lands lists that we don't know (limited_cube_family_add) from its expansions list.
--  - t1_private.limited_cube_versions: one row per run of a family: key <family>-<YYMM of the run's first draft>
--    (PWR-2510), name ("Arena Powered Cube · Oct 2025"), the run's first draft day (weeks count from it) and its cards
--    (17Lands' column names → Oracle ids, names nothing matches kept in `missing`). limited-sync reads the first rows of
--    a family file whose Last-Modified is new; a first draft day within 14 days of a version's is that version (17Lands
--    refreshed it), anything else is a new version, so an earlier run's pack stays as it was.
--  - Runs and packs are keyed by version. The CUBE run becomes PWR-2510 (its cards from the sums already read); its
--    pack is rebuilt under the new key (limited-sync {"step":"pack","set":"PWR-2510"}, by hand after the apply).
-- Replaces public.limited_candidates, public.limited_run_state and public.limited_pack_facts (20261026030000).

update t1_private.limited_cubes set code = 'PWR' where code = 'CUBE';
insert into t1_private.limited_cubes (code, file, name, released) values
  ('PWR', 'Cube_-_Powered', 'Arena Powered Cube', '2025-10-30'),
  ('ACUBE', 'Cube', 'Arena Cube', '2000-01-01'),
  ('PLNR', 'Cube_-_Planar', 'Arena Planar Cube', '2000-01-01')
on conflict (code) do nothing;
comment on column t1_private.limited_cubes.released is 'Unused since 20261030130000: each version has its own first day.';

create table if not exists t1_private.limited_cube_versions (
  key text primary key check (key ~ '^[A-Z0-9]{2,8}-[0-9]{4}$'),
  family text not null references t1_private.limited_cubes (code) on update cascade,
  started date not null,
  name text not null,
  cards uuid[] not null default '{}',
  missing text[] not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists limited_cube_versions_family_idx on t1_private.limited_cube_versions (family, started desc);

-- The cards of a version from 17Lands' names (front faces for two-faced cards, as meta_card_id reads them).
create or replace function t1_private.limited_cube_cards(p_names text[])
returns table (cards uuid[], missing text[]) language sql stable security definer set search_path = '' as $$
  with n as (select distinct x name, t1_private.meta_card_id(x) o from unnest(p_names) x where btrim(x) <> '')
  select coalesce(array_agg(distinct o) filter (where o is not null), '{}'),
         coalesce(array_agg(name order by name) filter (where o is null), '{}')
    from n;
$$;

-- The version a family file's run belongs to (made on first sight). p_names: the card names in a game file's
-- header (null for a draft file, which then joins the nearest version, or makes one with no cards yet).
create or replace function public.limited_cube_version(p_family text, p_started date, p_names text[] default null)
returns text language plpgsql security definer set search_path = '' as $$
declare
  f t1_private.limited_cubes;
  v t1_private.limited_cube_versions;
  c record;
begin
  select * into f from t1_private.limited_cubes where code = upper(p_family);
  if f.code is null or p_started is null then raise exception 'Unknown cube %', p_family using errcode = '22023'; end if;
  select * into v from t1_private.limited_cube_versions
   where family = f.code and abs(started - p_started) <= 14 order by abs(started - p_started), started limit 1;
  if v.key is null then
    insert into t1_private.limited_cube_versions (key, family, started, name)
    values (f.code || '-' || to_char(p_started, 'YYMM'), f.code, p_started,
            f.name || ' · ' || to_char(p_started, 'FMMon YYYY'))
    on conflict (key) do update set started = least(t1_private.limited_cube_versions.started, excluded.started)
    returning * into v;
  end if;
  if p_names is not null and cardinality(p_names) > 0 then
    select * into c from t1_private.limited_cube_cards(p_names);
    update t1_private.limited_cube_versions set cards = c.cards, missing = c.missing,
           started = least(started, p_started)
     where key = v.key;
  end if;
  return v.key;
end $$;

-- A family 17Lands lists that isn't known yet ("Cube - Chromatic" → CHROM, file Cube_-_Chromatic). Returns its code.
create or replace function public.limited_cube_family_add(p_label text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_file text := replace(btrim(p_label), ' ', '_');
  v_rest text := regexp_replace(btrim(p_label), '^Cube\s*-?\s*', '', 'i');
  v_code text;
begin
  if p_label is null or btrim(p_label) !~* '^cube' or char_length(p_label) > 60 then return null; end if;
  select code into v_code from t1_private.limited_cubes where file = v_file;
  if v_code is not null then return v_code; end if;
  v_code := coalesce(nullif(upper(left(regexp_replace(v_rest, '[^A-Za-z0-9]', '', 'g'), 6)), ''), 'ACUBE');
  if exists (select 1 from t1_private.limited_cubes where code = v_code) then v_code := left(v_code, 5) || 'X'; end if;
  insert into t1_private.limited_cubes (code, file, name, released)
  values (v_code, v_file, 'Arena ' || initcap(v_rest) || ' Cube', '2000-01-01')
  on conflict do nothing;
  return v_code;
end $$;

-- Has this file (this Last-Modified) been read or queued already? Saves the peek at a family file's first rows.
create or replace function public.limited_file_seen(p_uri text, p_last_modified timestamptz)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from t1_private.limited_runs where uri = p_uri and last_modified >= p_last_modified
                   and status in ('pending', 'running', 'done'));
$$;

-- Sets as before, then each cube family with its latest version (family files are peeked whatever their age).
create or replace function public.limited_candidates()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x.j order by x.released desc), '[]'::jsonb)
    from (select jsonb_build_object('set_code', upper(code), 'name', name, 'released', released_at::text) j, released_at released
            from public.mtg_sets
           where set_type in ('expansion', 'core', 'draft_innovation', 'masters', 'alchemy', 'remastered')
             and released_at between current_date - 300 and current_date + 7
             and upper(code) not in (select code from t1_private.limited_cubes)
          union all
          select jsonb_build_object('family', c.code, 'file', c.file, 'name', c.name, 'set_code', v.key,
                                    'released', coalesce(v.started, date '2000-01-01')::text), coalesce(v.started, date '2000-01-01')
            from t1_private.limited_cubes c
            left join lateral (select key, started from t1_private.limited_cube_versions where family = c.code
                                order by started desc limit 1) v on true) x;
$$;

create or replace function public.limited_run_state(p_run bigint)
returns jsonb language sql security definer set search_path = '' as $$
  update t1_private.limited_runs set status = 'running', in_flight_at = now(), attempts = attempts + 1
   where id = p_run and status in ('pending', 'running')
  returning jsonb_build_object('id', id, 'set_code', set_code, 'event_type', event_type, 'kind', kind, 'uri', uri,
    'total_bytes', total_bytes, 'step', step, 'bit', bit, 'win', coalesce(win, ''), 'carry', coalesce(carry, ''), 'header', header,
    'released', coalesce((select v.started::text from t1_private.limited_cube_versions v where v.key = set_code),
                         (select s.released_at::text from public.mtg_sets s where s.code = lower(set_code))));
$$;

-- As 20261026030000, with a cube version's name and first day, and `cube` {family, name} on a version's pack.
create or replace function public.limited_pack_facts(p_set text)
returns jsonb language sql stable security definer set search_path = '' as $$
  with latest as (
    select distinct on (event_type, kind) id, event_type, kind, last_modified
      from t1_private.limited_runs where set_code = upper(p_set) and status = 'done'
     order by event_type, kind, last_modified desc),
  ev as (
    select g.event_type, g.id game, d.id draft, g.last_modified
      from latest g left join latest d on d.event_type = g.event_type and d.kind = 'draft' where g.kind = 'game'),
  cube as (select v.name, v.started released, v.family, f.name family_name
             from t1_private.limited_cube_versions v join t1_private.limited_cubes f on f.code = v.family
            where v.key = upper(p_set))
  select case when not exists (select 1 from ev) then null else jsonb_build_object(
    'v', 1, 'kind', 'limited', 'set_code', upper(p_set),
    'name', coalesce((select name from cube), (select name from public.mtg_sets where code = lower(p_set))),
    'released', coalesce((select released::text from cube), (select released_at::text from public.mtg_sets where code = lower(p_set))),
    'cube', (select jsonb_build_object('family', family, 'name', family_name) from cube),
    'credit', jsonb_build_object('name', '17Lands', 'url', 'https://www.17lands.com/public_datasets'),
    'events', (select jsonb_object_agg(event_type, jsonb_build_object(
                  'updated', last_modified::date::text,
                  'groups', (select coalesce(jsonb_object_agg(g.k, g.v) filter (where g.v is not null), '{}'::jsonb)
                               from (values ('all', t1_private.limited_view(game, draft, 'a', p_set)),
                                            ('top', t1_private.limited_view(game, draft, 't', p_set))) g(k, v))))
                 from ev))
  end;
$$;

-- The Powered Cube run read so far (first drafts 2025-10-30) is version PWR-2510; its cards come from its sums.
do $$
declare v_names text[];
begin
  if exists (select 1 from t1_private.limited_runs where set_code = 'CUBE') then
    select array_agg(distinct split_part(a.k, '|', 2)) into v_names
      from t1_private.limited_acc a join t1_private.limited_runs r on r.id = a.run_id
     where r.set_code = 'CUBE' and r.kind = 'game' and a.k like 'cd|%|a';
    perform public.limited_cube_version('PWR', date '2025-10-30', coalesce(v_names, '{}'));
    update t1_private.limited_runs set set_code = 'PWR-2510' where set_code = 'CUBE';
    delete from t1_private.insight_packs where kind = 'limited' and key = 'CUBE';
    delete from t1_private.insight_briefs where view like '%CUBE%';
  end if;
  -- Picks that named the cube name its version now.
  update public.user_settings
     set insights = jsonb_set(insights, '{set}', '"PWR-2510"')
   where insights->>'set' = 'CUBE';
  update public.user_settings
     set insights = jsonb_set(insights, '{hidden_sets}',
                              (select jsonb_agg(case when x = 'CUBE' then 'PWR-2510' else x end) from jsonb_array_elements_text(insights->'hidden_sets') x))
   where jsonb_typeof(insights->'hidden_sets') = 'array' and insights->'hidden_sets' ? 'CUBE';
end $$;

revoke execute on function t1_private.limited_cube_cards(text[]) from public;
do $$
declare f text;
begin
  foreach f in array array['limited_cube_version(text, date, text[])', 'limited_cube_family_add(text)',
                           'limited_file_seen(text, timestamptz)', 'limited_candidates()', 'limited_run_state(bigint)',
                           'limited_pack_facts(text)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
