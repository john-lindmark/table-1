-- Insights: "Other" breaks down into example decks (contract/insights-2026-10-24.md § RPCs). meta_archetype for
-- archetype 0 adds `groups`: Other's decks by colours (up to 8, by share), each with its four most-played nonland
-- cards and `example`, the index of its best list in `finishes` (the group's best list is added there when it isn't
-- among the ten best). Lists now read spells first, lands last. Otherwise as in 20261025120000_insights.sql.
create or replace function public.meta_archetype(p_format text, p_archetype integer, p_tier text default 'all', p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_arch jsonb;
  v_days integer := case when p_days in (7, 14, 30, 90) then p_days else 30 end;
  v_out jsonb;
begin
  perform t1_private.meta_require(p_format, p_tier);
  if p_archetype = 0 then
    v_arch := jsonb_build_object('id', 0, 'name', 'Other', 'family', 'midrange', 'colors', '');
  else
    select jsonb_build_object('id', id, 'name', name, 'family', family, 'colors', colors) into v_arch
      from t1_private.meta_archetypes where id = p_archetype and format = p_format and status = 'approved';
  end if;
  if v_arch is null then raise exception 'Unknown archetype' using errcode = '22023'; end if;

  with win as (
    select d.* from t1_private.meta_decks d
     where d.format = p_format and d.on_date > current_date - v_days and t1_private.meta_tier_in(d.tier, p_tier)),
  mine as (select * from win where archetype_id = p_archetype),
  mt as (select coalesce(sum(weight), 0) w, count(*) n from mine),
  wins as (select count(*) n, count(*) filter (where top8) t8 from win d join t1_private.meta_events e on e.id = d.event_id and e.complete),
  mwins as (select count(*) n, count(*) filter (where top8) t8 from mine d join t1_private.meta_events e on e.id = d.event_id and e.complete),
  -- paper events' records cover the whole field, so when there are any they're the record; else MTGO's top 32
  recs as (
    select e.source, d.wins, d.losses, d.draws from mine d join t1_private.meta_events e on e.id = d.event_id
     where d.wins is not null and e.kind <> 'league'),
  rec as (
    select sum(wins) w, sum(losses) l, sum(coalesce(draws, 0)) dr, bool_or(source = 'topdeck') td
      from recs where source = 'topdeck' or not exists (select 1 from recs where source = 'topdeck')),
  lines as (
    select s.side, u.id, sum(m.weight) w, sum(m.weight * u.q) wq
      from mine m cross join lateral (values (false, m.main, m.main_qty), (true, m.side, m.side_qty)) s(side, ids, qty)
      cross join lateral unnest(s.ids, s.qty) u(id, q) group by 1, 2),
  rated as (
    select l.side, l.id, o.name, l.w / nullif((select w from mt), 0) rate, l.wq / l.w copies
      from lines l join public.card_oracles o on o.oracle_id = l.id where coalesce(o.type_line, '') !~ '^Basic'),
  weeks as (select g from generate_series(0, 25) g),
  series as (
    select w.g, (select sum(weight) filter (where d.archetype_id = p_archetype) / nullif(sum(weight), 0)
                   from t1_private.meta_decks d
                  where d.format = p_format and t1_private.meta_tier_in(d.tier, p_tier)
                    and d.on_date > current_date - 7 * (26 - w.g) and d.on_date <= current_date - 7 * (25 - w.g)) v
      from weeks w),
  mu as (
    select case when da.archetype_id = p_archetype then db.archetype_id else da.archetype_id end vs,
           count(*) filter (where (mm.result = 'a') = (da.archetype_id = p_archetype) and mm.result <> 'draw') wn,
           count(*) filter (where (mm.result = 'b') = (da.archetype_id = p_archetype) and mm.result <> 'draw') ls,
           count(*) filter (where mm.result = 'draw') dr
      from t1_private.meta_matches mm
      join t1_private.meta_decks da on da.id = mm.a join t1_private.meta_decks db on db.id = mm.b
     where da.format = p_format and da.on_date > current_date - 90
       and (da.archetype_id = p_archetype) <> (db.archetype_id = p_archetype)
     group by 1),
  -- Other (0): its decks by colours, each with its most-played cards and its best list as an example
  grp as (
    select m.colors, count(*) n, sum(m.weight) w from mine m where p_archetype = 0
     group by m.colors order by sum(m.weight) desc, m.colors limit 8),
  gex as (
    select distinct on (m.colors) m.colors, m.id from mine m join grp using (colors)
     order by m.colors, m.weight desc, m.rank nulls last, m.on_date desc),
  gcards as (
    select g.colors, o.name, count(*)::numeric / max(g.n) rate
      from grp g join mine m using (colors) cross join lateral unnest(m.main) u(id)
      join public.card_oracles o on o.oracle_id = u.id
     where coalesce(o.type_line, '') !~ 'Land'
     group by g.colors, o.name),
  fin as (
    select x.*, row_number() over (order by x.weight desc, x.rank nulls last, x.on_date desc, x.id) - 1 pos from (
      select m.*, e.name ev, e.players, e.url from mine m join t1_private.meta_events e on e.id = m.event_id
       where m.id in (select id from (select id from mine order by weight desc, rank nulls last, on_date desc limit 10) t)
          or m.id in (select id from gex)) x)
  select jsonb_build_object(
    'archetype', v_arch,
    'decks', (select n from mt),
    'series', jsonb_build_object('from', (current_date - 7 * 26 + 1)::text, 'weeks', 26,
                                 'v', (select jsonb_agg(round(v, 4) order by g) from series)),
    'record', (select case when w is null then null else jsonb_build_object('wins', w, 'losses', l, 'draws', dr,
                 'basis', case when td then 'topdeck' else 'mtgo_top32' end) end from rec),
    'conv', (select case when wins.t8 > 0 and mwins.n >= 20 then round((mwins.t8::numeric / wins.t8) / (mwins.n::numeric / wins.n), 2) end from wins, mwins),
    'core', coalesce((select jsonb_agg(jsonb_build_object('c', id, 'n', name, 'rate', round(rate, 4), 'copies', round(copies, 2)) order by rate desc, name)
                        from rated where not side and rate >= 0.8), '[]'::jsonb),
    'flex', coalesce((select jsonb_agg(jsonb_build_object('c', id, 'n', name, 'rate', round(rate, 4), 'copies', round(copies, 2)) order by rate desc, name)
                        from (select * from rated where not side and rate >= 0.2 and rate < 0.8 order by rate desc limit 30) f), '[]'::jsonb),
    'side', coalesce((select jsonb_agg(jsonb_build_object('c', id, 'n', name, 'rate', round(rate, 4), 'copies', round(copies, 2)) order by rate desc, name)
                        from (select * from rated where side and rate >= 0.2 order by rate desc limit 30) s), '[]'::jsonb),
    'matchups', coalesce((select jsonb_agg(jsonb_build_object('vs', vs, 'wins', wn, 'losses', ls, 'draws', dr) order by wn + ls + dr desc) from mu), '[]'::jsonb),
    'finishes', coalesce((select jsonb_agg(jsonb_build_object(
        'event', f.ev, 'on', f.on_date::text, 'players', f.players, 'tier', f.tier, 'rank', f.rank, 'url', f.url,
        'main', (select jsonb_agg(jsonb_build_array(o.name, u.q) order by coalesce(o.type_line, '') ~ 'Land', o.cmc, o.name) from unnest(f.main, f.main_qty) u(id, q)
                   join public.card_oracles o on o.oracle_id = u.id),
        'side', coalesce((select jsonb_agg(jsonb_build_array(o.name, u.q) order by coalesce(o.type_line, '') ~ 'Land', o.cmc, o.name) from unnest(f.side, f.side_qty) u(id, q)
                   join public.card_oracles o on o.oracle_id = u.id), '[]'::jsonb))
        order by f.pos) from fin f), '[]'::jsonb),
    'groups', coalesce((select jsonb_agg(jsonb_build_object(
        'colors', g.colors, 'decks', g.n, 'share', round(g.w / nullif((select w from mt), 0), 4),
        'cards', (select coalesce(jsonb_agg(c.name order by c.rate desc, c.name), '[]'::jsonb) from (
                    select name, rate from gcards where gcards.colors = g.colors order by rate desc, name limit 4) c),
        'example', (select f.pos from fin f join gex on gex.id = f.id where gex.colors = g.colors))
        order by g.w desc, g.colors) from grp g), '[]'::jsonb),
    'brief', (select brief from t1_private.insight_briefs where view = 'arch:' || p_format || ':' || p_archetype))
  into v_out;
  return v_out;
end $$;
