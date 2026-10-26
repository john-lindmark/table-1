-- Insights: Arena's cube in Limited (contract/insights-2026-10-24.md § Limited pack). 17Lands publishes Arena's
-- Powered Cube as `Cube_-_Powered` (Premier and Traditional Draft), which isn't a Scryfall set, so
-- limited_candidates never offered it. Cube datasets are listed in t1_private.limited_cubes under a short key
-- (CUBE) with their 17Lands file code, name and the first day of the run on Arena; limited_candidates returns them
-- (with `file`) beside the sets, whatever their age, and limited_run_state / limited_pack_facts take their name and
-- release date from there. Cube cards have no rarity in the pack (clients hide the rarity filter when no card has
-- one). Otherwise as in 20261025120000_insights.sql.
create table if not exists t1_private.limited_cubes (
  code text primary key check (code = upper(code)),
  file text not null unique,                     -- 17Lands' expansion in the file name
  name text not null,
  released date not null                         -- first day of the current run on Arena (weeks count from here)
);
insert into t1_private.limited_cubes (code, file, name, released)
values ('CUBE', 'Cube_-_Powered', 'Arena Powered Cube', '2025-10-30')
on conflict (code) do nothing;

create or replace function public.limited_candidates()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x.j order by x.released desc), '[]'::jsonb)
    from (select jsonb_build_object('set_code', upper(code), 'name', name, 'released', released_at::text) j, released_at released
            from public.mtg_sets
           where set_type in ('expansion', 'core', 'draft_innovation', 'masters', 'alchemy', 'remastered')
             and released_at between current_date - 300 and current_date + 7
             and upper(code) not in (select code from t1_private.limited_cubes)
          union all
          select jsonb_build_object('set_code', code, 'file', file, 'name', name, 'released', released::text), released
            from t1_private.limited_cubes) x;
$$;

create or replace function public.limited_run_state(p_run bigint)
returns jsonb language sql security definer set search_path = '' as $$
  update t1_private.limited_runs set status = 'running', in_flight_at = now(), attempts = attempts + 1
   where id = p_run and status in ('pending', 'running')
  returning jsonb_build_object('id', id, 'set_code', set_code, 'event_type', event_type, 'kind', kind, 'uri', uri,
    'total_bytes', total_bytes, 'step', step, 'bit', bit, 'win', coalesce(win, ''), 'carry', coalesce(carry, ''), 'header', header,
    'released', coalesce((select c.released::text from t1_private.limited_cubes c where c.code = set_code),
                         (select s.released_at::text from public.mtg_sets s where s.code = lower(set_code))));
$$;

create or replace function public.limited_pack_facts(p_set text)
returns jsonb language sql stable security definer set search_path = '' as $$
  with latest as (
    select distinct on (event_type, kind) id, event_type, kind, last_modified
      from t1_private.limited_runs where set_code = upper(p_set) and status = 'done'
     order by event_type, kind, last_modified desc),
  ev as (
    select g.event_type, g.id game, d.id draft, g.last_modified
      from latest g left join latest d on d.event_type = g.event_type and d.kind = 'draft' where g.kind = 'game'),
  cube as (select name, released from t1_private.limited_cubes where code = upper(p_set))
  select case when not exists (select 1 from ev) then null else jsonb_build_object(
    'v', 1, 'kind', 'limited', 'set_code', upper(p_set),
    'name', coalesce((select name from cube), (select name from public.mtg_sets where code = lower(p_set))),
    'released', coalesce((select released::text from cube), (select released_at::text from public.mtg_sets where code = lower(p_set))),
    'credit', jsonb_build_object('name', '17Lands', 'url', 'https://www.17lands.com/public_datasets'),
    'events', (select jsonb_object_agg(event_type, jsonb_build_object(
                  'updated', last_modified::date::text,
                  'groups', (select coalesce(jsonb_object_agg(g.k, g.v) filter (where g.v is not null), '{}'::jsonb)
                               from (values ('all', t1_private.limited_view(game, draft, 'a', p_set)),
                                            ('top', t1_private.limited_view(game, draft, 't', p_set))) g(k, v))))
                 from ev))
  end;
$$;
