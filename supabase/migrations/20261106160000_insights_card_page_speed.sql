-- Card page speed (contract/insights-2026-10-24.md § RPCs): on live, Lightning Bolt's Modern page took 0.56 s for 30
-- days and 0.83 s for 90, mostly looking up its copies in every list of the window. Copies are now looked up only in
-- lists holding the card, the window keeps only the columns it needs (the ten best lists fetch their cards after),
-- and first and last seen come from one read. Same answer.

create or replace function public.meta_card(p_format text, p_oracle_id uuid, p_tier text default 'all', p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_days integer := case when p_days in (7, 14, 30, 90, 365) then p_days else 30 end;
  v jsonb;
begin
  perform t1_private.meta_require(p_format, p_tier);
  with yr as (
    select d.on_date, d.weight, d.main @> array[p_oracle_id] m, d.side @> array[p_oracle_id] s
      from t1_private.meta_decks d
     where d.format = p_format and t1_private.meta_tier_in(d.tier, p_tier) and d.on_date > current_date - 364),
  wk as (
    select (current_date - on_date) / 7 back,
           sum(weight) filter (where m) / nullif(sum(weight), 0) main,
           sum(weight) filter (where s) / nullif(sum(weight), 0) side
      from yr group by 1),
  -- the copies are looked up only in lists holding the card (the unnest for every list was most of the time)
  win as materialized (
    select d.id, d.event_id, d.on_date, d.tier, d.weight, d.rank, d.archetype_id,
           case when d.main @> array[p_oracle_id] then (select q from unnest(d.main, d.main_qty) u(id, q) where u.id = p_oracle_id limit 1) else 0 end mq,
           case when d.side @> array[p_oracle_id] then (select q from unnest(d.side, d.side_qty) u(id, q) where u.id = p_oracle_id limit 1) else 0 end sq
      from t1_private.meta_decks d
     where d.format = p_format and d.on_date > current_date - v_days and t1_private.meta_tier_in(d.tier, p_tier)),
  by_a as (
    select archetype_id a, count(*) filter (where mq > 0 or sq > 0) decks, count(*) total,
           sum(weight) filter (where mq > 0) / sum(weight) rate,
           sum(weight * mq) filter (where mq > 0) / nullif(sum(weight) filter (where mq > 0), 0) copies,
           sum(weight * sq) filter (where sq > 0) / nullif(sum(weight) filter (where sq > 0), 0) side_copies
      from win group by archetype_id having count(*) filter (where mq > 0 or sq > 0) > 0),
  fin as (
    select w.*, d.main, d.main_qty, d.side, d.side_qty, e.name ev, e.players, e.url
      from (select * from win where mq > 0 or sq > 0 order by weight desc, rank nulls last, on_date desc, id limit 10) w
      join t1_private.meta_decks d on d.id = w.id
      join t1_private.meta_events e on e.id = w.event_id),
  seen as (
    select min(d.on_date) first_on, max(d.on_date) last_on from t1_private.meta_decks d
     where d.format = p_format and (d.main @> array[p_oracle_id] or d.side @> array[p_oracle_id]))
  select jsonb_build_object(
    'c', p_oracle_id, 'n', (select name from public.card_oracles where oracle_id = p_oracle_id),
    'series', jsonb_build_object('from', (current_date - 7 * 52 + 1)::text, 'weeks', 52,
                                 'main', (select jsonb_agg(round(k.main, 4) order by g.g) from generate_series(0, 51) g(g) left join wk k on k.back = 51 - g.g),
                                 'side', (select jsonb_agg(round(k.side, 4) order by g.g) from generate_series(0, 51) g(g) left join wk k on k.back = 51 - g.g)),
    'window', (select jsonb_build_object('days', v_days,
                 'decks', count(*) filter (where mq > 0 or sq > 0), 'of', count(*),
                 'main', round(sum(weight) filter (where mq > 0) / nullif(sum(weight), 0), 4),
                 'side', round(sum(weight) filter (where sq > 0) / nullif(sum(weight), 0), 4),
                 'copies', round(sum(weight * mq) filter (where mq > 0) / nullif(sum(weight) filter (where mq > 0), 0), 2),
                 'side_copies', round(sum(weight * sq) filter (where sq > 0) / nullif(sum(weight) filter (where sq > 0), 0), 2))
                 from win),
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
    'first_seen', (select first_on::text from seen),
    'last_seen', (select last_on::text from seen))
  into v;
  return v;
end $$;
