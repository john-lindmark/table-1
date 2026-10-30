-- Meta now rows carry their match record (John, 2026-10-30): `rec` = [wins, losses, draws] in matches against other
-- archetypes, the counts behind `wr` (null with none), so the Discord bot's win-rate chart can draw each archetype's
-- record and its likely range (contract/insights-2026-10-24.md § Constructed pack, contract/discord-2026-10-29.md).
-- As in 20261028190000_insights_meta_rates.sql apart from `mt.d` and `rec`.

create or replace function public.meta_pack_window(p_format text, p_tier text, p_days integer, p_through date default current_date)
returns jsonb language sql stable security definer set search_path = '' as $$
  with cur as (
    select d.* from t1_private.meta_decks d
     where d.format = p_format and d.on_date > p_through - p_days and d.on_date <= p_through
       and t1_private.meta_tier_in(d.tier, p_tier)),
  prv as (
    select d.* from t1_private.meta_decks d
     where d.format = p_format and d.on_date > p_through - 2 * p_days and d.on_date <= p_through - p_days
       and t1_private.meta_tier_in(d.tier, p_tier)),
  tot as (select coalesce(sum(weight), 0) w, count(*) n, count(distinct event_id) e from cur),
  ptot as (select coalesce(sum(weight), 0) w from prv),
  sh as (select archetype_id a, sum(weight) w, count(*) n, count(*) filter (where top8) t8 from cur group by 1),
  psh as (select archetype_id a, sum(weight) w from prv group by 1),
  -- conversion only from events whose whole field is known
  cv as (select d.archetype_id a, count(*) n, count(*) filter (where d.top8) t8
           from cur d join t1_private.meta_events e on e.id = d.event_id and e.complete group by 1),
  cvt as (select sum(n) n, sum(t8) t8 from cv),
  -- win rate: matches against other archetypes (TopDeck rounds, MTGO top 8 brackets); mirrors say nothing
  mt as (
    select x.a, count(*) n, count(*) filter (where x.won) w, count(*) filter (where mm.result = 'draw') d
      from cur da
      join t1_private.meta_matches mm on mm.event_id = da.event_id and mm.a = da.id
      join t1_private.meta_decks db on db.id = mm.b
      cross join lateral (values (da.archetype_id, mm.result = 'a'), (db.archetype_id, mm.result = 'b')) x(a, won)
     where da.archetype_id <> db.archetype_id
     group by 1),
  -- conversion rate: the share of an archetype's lists that made top 8, in events with a top 8 (not leagues)
  t8 as (
    select d.archetype_id a, count(*) n, count(*) filter (where d.top8) t8
      from cur d join t1_private.meta_events e on e.id = d.event_id and e.kind <> 'league'
     where exists (select 1 from cur x where x.event_id = d.event_id and x.top8)
     group by 1),
  -- event wins: first place, out of the events in the window with a known winner
  won as (select archetype_id a, count(*) n from cur where rank = 1 group by 1),
  cards as (
    select 'cur' w, s.side, u.id, sum(d.weight) wt, sum(d.weight * u.q) wq
      from cur d cross join lateral (values (false, d.main, d.main_qty), (true, d.side, d.side_qty)) s(side, ids, qty)
      cross join lateral unnest(s.ids, s.qty) u(id, q) group by 1, 2, 3
    union all
    select 'prv', s.side, u.id, sum(d.weight), sum(d.weight * u.q)
      from prv d cross join lateral (values (false, d.main, d.main_qty), (true, d.side, d.side_qty)) s(side, ids, qty)
      cross join lateral unnest(s.ids, s.qty) u(id, q) group by 1, 2, 3),
  rates as (
    select c.side, c.id,
           coalesce(max(c.wt) filter (where c.w = 'cur'), 0) / nullif((select w from tot), 0) rate,
           coalesce(max(c.wt) filter (where c.w = 'prv'), 0) / nullif((select w from ptot), 0) prev,
           max(c.wq / c.wt) filter (where c.w = 'cur') copies
      from cards c group by 1, 2),
  ranked as (
    select r.*, o.name, r.rate - coalesce(r.prev, 0) delta from rates r
      join public.card_oracles o on o.oracle_id = r.id
     where coalesce(o.type_line, '') !~ 'Land' and greatest(r.rate, coalesce(r.prev, 0)) >= 0.03),
  card_json as (
    select side, dir, jsonb_agg(jsonb_build_object('c', id, 'n', name, 'rate', round(rate, 4), 'prev', round(prev, 4),
                                                   'copies', round(copies, 2)) order by ord) j
      from (select r.*, 'up' dir, row_number() over (partition by side order by delta desc, name) ord from ranked r where delta > 0
            union all
            select r.*, 'down', row_number() over (partition by side order by delta, name) from ranked r where delta < 0) x
     where ord <= 12 group by 1, 2)
  select jsonb_build_object(
    'decks', (select n from tot), 'weighted', round((select w from tot), 1), 'events', (select e from tot),
    'thin', (select w from tot) < (select thin_below from t1_private.meta_settings),
    'won_of', (select count(distinct event_id) from cur where rank = 1),
    'share', coalesce((select jsonb_agg(jsonb_build_object(
                 'a', sh.a, 'share', round(sh.w / nullif((select w from tot), 0), 4),
                 'prev', round(coalesce(psh.w, 0) / nullif((select w from ptot), 0), 4),
                 'decks', sh.n, 'top8', sh.t8,
                 'conv', case when cv.n >= 20 and cvt.t8 > 0   -- a handful of decks says nothing about converting
                              then round((cv.t8::numeric / cvt.t8) / (cv.n::numeric / cvt.n), 2) end,
                 'wr', case when mt.n >= 20 then round(mt.w::numeric / mt.n, 4) end,
                 'rec', case when mt.n > 0 then jsonb_build_array(mt.w, mt.n - mt.w - mt.d, mt.d) end,
                 't8r', case when t8.n >= 20 then round(t8.t8::numeric / t8.n, 4) end,
                 'won', coalesce(won.n, 0))
               order by sh.w desc, sh.a)
             from sh left join psh on psh.a = sh.a left join cv on cv.a = sh.a cross join cvt
                     left join mt on mt.a = sh.a left join t8 on t8.a = sh.a left join won on won.a = sh.a), '[]'::jsonb),
    'cards', jsonb_build_object(
      'main', jsonb_build_object('up', coalesce((select j from card_json where not side and dir = 'up'), '[]'),
                                 'down', coalesce((select j from card_json where not side and dir = 'down'), '[]')),
      'side', jsonb_build_object('up', coalesce((select j from card_json where side and dir = 'up'), '[]'),
                                 'down', coalesce((select j from card_json where side and dir = 'down'), '[]'))));
$$;
