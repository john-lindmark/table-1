-- Insights card search and a fuller card page (contract/insights-2026-10-24.md § Card search, § RPCs).
-- John, 2026-11-06: "search for cards in insights for any format and it should show the prevalence of the card over
-- time and which decks it's shown up in".
--
-- meta_card_search: cards played in the format over the last year whose name matches, from the daily
-- t1_private.spice_counts (archetype -1 = the whole format), so a search reads a few thousand rows and only offers
-- cards that have a page.
-- meta_card gains p_days (the format page's window) and keeps its old keys for the builds that read them: the series
-- is now a year of weeks, `window` sums the picked window, by_archetype lists every archetype playing it in that
-- window (with decks and the archetype's own count), `finishes` the ten best lists that played it in the window
-- (meta_archetype's finish shape plus `a` and `qty`), and last_seen.

create or replace function public.meta_card_search(p_format text, p_query text, p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_q text := public.card_name_norm(p_query);
  v_n90 numeric;
  v jsonb;
begin
  perform t1_private.meta_require(p_format, 'all');
  if char_length(v_q) < 2 then return '[]'::jsonb; end if;
  select nullif(n, 0) into v_n90 from t1_private.spice_lists where format = p_format and archetype_id = -1 and days = 90;
  with seen as (
    select y.card, greatest(y.main, y.side) in_year, coalesce(q.main, 0) main90, coalesce(q.side, 0) side90
      from t1_private.spice_counts y
      left join t1_private.spice_counts q on q.format = y.format and q.archetype_id = -1 and q.days = 90 and q.card = y.card
     where y.format = p_format and y.archetype_id = -1 and y.days = 365),
  hits as (
    select s.card, s.in_year, s.main90, s.side90,
           min(case when n.name_norm = v_q then 0
                    when n.name_norm like v_q || '%' then 1
                    when n.name_norm like '% ' || v_q || '%' then 2
                    when strpos(n.name_norm, v_q) > 0 then 3
                    else 4 end) rank
      from seen s join public.card_names n on n.oracle_id = s.card
     where strpos(n.name_norm, v_q) > 0
        or (char_length(v_q) >= 4 and extensions.similarity(n.name_norm, v_q) >= 0.45)
     group by s.card, s.in_year, s.main90, s.side90)
  select coalesce(jsonb_agg(jsonb_build_object(
           'c', h.card, 'n', o.name, 'type', o.type_line,
           'main', coalesce(round(h.main90 / v_n90, 4), 0),
           'side', coalesce(round(h.side90 / v_n90, 4), 0),
           'year', h.in_year)
         order by h.rank, h.main90 + h.side90 desc, h.in_year desc, o.name), '[]'::jsonb)
    into v
    from (select * from hits order by rank, main90 + side90 desc, in_year desc limit least(greatest(coalesce(p_limit, 20), 1), 50)) h
    join public.card_oracles o on o.oracle_id = h.card
   where coalesce(o.type_line, '') !~ '^Basic';
  return v;
end $$;

drop function if exists public.meta_card(text, uuid, text);
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
  win as (
    select d.*, coalesce((select q from unnest(d.main, d.main_qty) u(id, q) where u.id = p_oracle_id limit 1), 0) mq,
                coalesce((select q from unnest(d.side, d.side_qty) u(id, q) where u.id = p_oracle_id limit 1), 0) sq
      from t1_private.meta_decks d
     where d.format = p_format and d.on_date > current_date - v_days and t1_private.meta_tier_in(d.tier, p_tier)),
  by_a as (
    select archetype_id a, count(*) filter (where mq > 0 or sq > 0) decks, count(*) total,
           sum(weight) filter (where mq > 0) / sum(weight) rate,
           sum(weight * mq) filter (where mq > 0) / nullif(sum(weight) filter (where mq > 0), 0) copies,
           sum(weight * sq) filter (where sq > 0) / nullif(sum(weight) filter (where sq > 0), 0) side_copies
      from win group by archetype_id having count(*) filter (where mq > 0 or sq > 0) > 0),
  fin as (
    select w.*, e.name ev, e.players, e.url from win w join t1_private.meta_events e on e.id = w.event_id
     where w.mq > 0 or w.sq > 0
     order by w.weight desc, w.rank nulls last, w.on_date desc, w.id limit 10)
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
    -- @> so the GIN indexes on main and side find the card's decks
    'first_seen', (select min(on_date)::text from t1_private.meta_decks d
                    where d.format = p_format and (d.main @> array[p_oracle_id] or d.side @> array[p_oracle_id])),
    'last_seen', (select max(on_date)::text from t1_private.meta_decks d
                   where d.format = p_format and (d.main @> array[p_oracle_id] or d.side @> array[p_oracle_id])))
  into v;
  return v;
end $$;

revoke execute on function public.meta_card_search(text, text, integer) from public, anon;
grant execute on function public.meta_card_search(text, text, integer) to authenticated, service_role;
revoke execute on function public.meta_card(text, uuid, text, integer) from public, anon;
grant execute on function public.meta_card(text, uuid, text, integer) to authenticated, service_role;
