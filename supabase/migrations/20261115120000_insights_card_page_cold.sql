-- Card page on a cold cache (contract/insights-2026-10-24.md § RPCs): on 2026-11-15 Genesis Device's Modern page
-- (16 lists, 90 days, all events) passed the 8 s statement timeout on a phone; the same call took 0.6 s warm. The
-- weekly line read every Modern list of the year (53,000 rows, card arrays included) to find the few holding the card,
-- and the tier test was a function call per row (meta_tier_in has a search_path, so it can't be inlined).
--
-- Now the lists holding the card come from the card indexes (meta_decks_main_idx / _side_idx), and the totals they
-- are divided by (per week, per archetype in the window) come from a covering index that never reads the card arrays.
-- Same answer: checked against the previous function on live for every format, tier and window before applying.

create index if not exists meta_decks_totals_idx on t1_private.meta_decks (format, on_date) include (tier, weight, archetype_id);

create or replace function public.meta_card(p_format text, p_oracle_id uuid, p_tier text default 'all', p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_days integer := case when p_days in (7, 14, 30, 90, 365) then p_days else 30 end;
  v_all boolean := p_tier = 'all';
  v jsonb;
begin
  perform t1_private.meta_require(p_format, p_tier);
  with
  -- every list of the format holding the card, any date or tier (first and last seen read all of them)
  hit as materialized (
    select d.id, d.event_id, d.on_date, d.tier, d.weight, d.rank, d.archetype_id,
           d.main @> array[p_oracle_id] m, d.side @> array[p_oracle_id] s,
           case when d.main @> array[p_oracle_id] then (select q from unnest(d.main, d.main_qty) u(id, q) where u.id = p_oracle_id limit 1) else 0 end mq,
           case when d.side @> array[p_oracle_id] then (select q from unnest(d.side, d.side_qty) u(id, q) where u.id = p_oracle_id limit 1) else 0 end sq
      from t1_private.meta_decks d
     where d.format = p_format and (d.main @> array[p_oracle_id] or d.side @> array[p_oracle_id])),
  hit_t as materialized (
    select * from hit h where h.on_date > current_date - 364 and (v_all or h.tier in ('major', 'large'))),
  -- totals from the covering index (no card arrays read)
  wk_tot as (
    select (current_date - d.on_date) / 7 back, sum(d.weight) w
      from t1_private.meta_decks d
     where d.format = p_format and d.on_date > current_date - 364 and (v_all or d.tier in ('major', 'large'))
     group by 1),
  wk_hit as (
    select (current_date - on_date) / 7 back, sum(weight) filter (where m) m, sum(weight) filter (where s) s
      from hit_t group by 1),
  wk as (
    select t.back, k.m / nullif(t.w, 0) main, k.s / nullif(t.w, 0) side
      from wk_tot t left join wk_hit k on k.back = t.back),
  win_tot as materialized (
    select d.archetype_id a, count(*) total, sum(d.weight) w
      from t1_private.meta_decks d
     where d.format = p_format and d.on_date > current_date - v_days and (v_all or d.tier in ('major', 'large'))
     group by d.archetype_id),
  win as materialized (
    select * from hit h where h.on_date > current_date - v_days and (v_all or h.tier in ('major', 'large')) and (h.mq > 0 or h.sq > 0)),
  by_a as (
    select h.archetype_id a, count(*) decks, t.total,
           sum(h.weight) filter (where h.mq > 0) / nullif(t.w, 0) rate,
           sum(h.weight * h.mq) filter (where h.mq > 0) / nullif(sum(h.weight) filter (where h.mq > 0), 0) copies,
           sum(h.weight * h.sq) filter (where h.sq > 0) / nullif(sum(h.weight) filter (where h.sq > 0), 0) side_copies
      from win h join win_tot t on t.a is not distinct from h.archetype_id
     group by h.archetype_id, t.total, t.w),
  fin as (
    select w.*, d.main, d.main_qty, d.side, d.side_qty, e.name ev, e.players, e.url
      from (select * from win order by weight desc, rank nulls last, on_date desc, id limit 10) w
      join t1_private.meta_decks d on d.id = w.id
      join t1_private.meta_events e on e.id = w.event_id)
  select jsonb_build_object(
    'c', p_oracle_id, 'n', (select name from public.card_oracles where oracle_id = p_oracle_id),
    'series', jsonb_build_object('from', (current_date - 7 * 52 + 1)::text, 'weeks', 52,
                                 'main', (select jsonb_agg(round(k.main, 4) order by g.g) from generate_series(0, 51) g(g) left join wk k on k.back = 51 - g.g),
                                 'side', (select jsonb_agg(round(k.side, 4) order by g.g) from generate_series(0, 51) g(g) left join wk k on k.back = 51 - g.g)),
    'window', (select jsonb_build_object('days', v_days,
                 'decks', (select count(*) from win), 'of', coalesce((select sum(total) from win_tot), 0),
                 'main', round((select sum(weight) filter (where mq > 0) from win) / nullif((select sum(w) from win_tot), 0), 4),
                 'side', round((select sum(weight) filter (where sq > 0) from win) / nullif((select sum(w) from win_tot), 0), 4),
                 'copies', (select round(sum(weight * mq) filter (where mq > 0) / nullif(sum(weight) filter (where mq > 0), 0), 2) from win),
                 'side_copies', (select round(sum(weight * sq) filter (where sq > 0) / nullif(sum(weight) filter (where sq > 0), 0), 2) from win))),
    'copies', (select round(sum(weight * mq) filter (where mq > 0) / nullif(sum(weight) filter (where mq > 0), 0), 2) from win),
    'by_archetype', coalesce((select jsonb_agg(jsonb_build_object('a', a, 'rate', round(coalesce(rate, 0), 4), 'copies', round(copies, 2),
                                                                  'side_copies', round(side_copies, 2), 'decks', decks, 'of', total)
                                               order by decks desc, rate desc nulls last, a)
                                from (select * from by_a order by decks desc, rate desc nulls last, a limit 40) b), '[]'::jsonb),
    'finishes', coalesce((select jsonb_agg(jsonb_build_object(
        'event', f.ev, 'on', f.on_date::text, 'players', f.players, 'tier', f.tier, 'rank', f.rank, 'url', f.url,
        'a', f.archetype_id, 'qty', jsonb_build_array(f.mq, f.sq),
        'main', (select jsonb_agg(jsonb_build_array(o.name, u.q) order by (coalesce(o.type_line, '') ~ 'Land'), o.cmc, o.name)
                   from unnest(f.main, f.main_qty) u(id, q) join public.card_oracles o on o.oracle_id = u.id),
        'side', coalesce((select jsonb_agg(jsonb_build_array(o.name, u.q) order by (coalesce(o.type_line, '') ~ 'Land'), o.cmc, o.name)
                   from unnest(f.side, f.side_qty) u(id, q) join public.card_oracles o on o.oracle_id = u.id), '[]'::jsonb))
        order by f.weight desc, f.rank nulls last, f.on_date desc, f.id) from fin f), '[]'::jsonb),
    'first_seen', (select min(on_date)::text from hit),
    'last_seen', (select max(on_date)::text from hit))
  into v;
  return v;
end $$;
