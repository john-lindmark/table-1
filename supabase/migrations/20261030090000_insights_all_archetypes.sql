-- Insights: every archetype that's discernible gets a line and a matchup row (John, 2026-10-30, after Frank Karsten's
-- chart of the SEA/ANZ/SA Regional Championships showed 19 named Modern archetypes; our charts stopped at 8 lines and
-- a 10×10 grid, so Boros Land Destruction, Living End, Neoform and others never showed).
--
-- Discernible = a named archetype with at least 1% of the window's weighted decks (and, for the matchup grid, 20
-- matches against other archetypes). Contract: contract/insights-2026-10-24.md § Constructed pack.
--
-- * meta_pack_series: lines = the 8 largest of the last 30 days (as before, Other included) plus every named
--   archetype at 1%+ of them. Rewritten to sum each day once (the old per-line, per-day subqueries took ~4 s for 8
--   lines); values are unchanged.
-- * meta_pack_matchups: `archetypes` stays the top 10 (the columns; builds on phones draw it as a square), and a new
--   `rows` lists them first in the same order, then every other discernible archetype by share, then Other (id 0)
--   when it has 20+ matches. Cells cover every pair of rows, oriented by position in `rows`, so the top 10's cells
--   are the same as before. It takes a tier and a window (defaults: All events, 90 days, the old grid), so each
--   window of the pack carries its own grid and the format page's pickers change it (John, 2026-10-30).
-- * Modern archetypes renamed to the names players use (Karsten's): ids, rules and decks unchanged.

create or replace function public.meta_pack_series(p_format text, p_tier text, p_days integer default 180, p_through date default current_date)
returns jsonb language sql stable security definer set search_path = '' as $$
  with days as (select (p_through - p_days + 1 + g)::date d, g from generate_series(0, p_days - 1) g),
  per_day as (
    select d.on_date, d.archetype_id a, sum(d.weight) w from t1_private.meta_decks d
     where d.format = p_format and d.on_date > p_through - p_days - 6 and d.on_date <= p_through
       and t1_private.meta_tier_in(d.tier, p_tier)
     group by 1, 2),
  recent as (select a, sum(w) w from per_day where on_date > p_through - 30 group by a),
  top as (
    select a, w from recent
     where a in (select a from recent order by w desc, a limit 8)
        or (a <> 0 and w >= 0.01 * (select sum(w) from recent))),
  totals as (  -- 7-day weight of every deck, and of the decks with a line
    select days.d, days.g, sum(p.w) tot, sum(p.w) filter (where p.a in (select a from top)) shown
      from days left join per_day p on p.on_date > days.d - 7 and p.on_date <= days.d
     group by days.d, days.g),
  lines as (
    select t.a, t.w first_share, tl.g, case when tl.tot > 0 then round(coalesce(sum(p.w), 0) / tl.tot, 4) end v
      from top t cross join totals tl
      left join per_day p on p.a = t.a and p.on_date > tl.d - 7 and p.on_date <= tl.d
     group by t.a, t.w, tl.g, tl.tot)
  select jsonb_build_object(
    'from', (p_through - p_days + 1)::text, 'days', p_days,
    'lines', coalesce((select jsonb_agg(jsonb_build_object('a', a, 'v', v) order by first_share desc, a)
                         from (select a, first_share, jsonb_agg(v order by g) v from lines group by a, first_share) x), '[]'::jsonb),
    'other', (select jsonb_agg(case when tot > 0 then round(1 - coalesce(shown, 0) / tot, 4) end order by g) from totals));
$$;

drop function if exists public.meta_pack_matchups(text, date);
create or replace function public.meta_pack_matchups(p_format text, p_through date default current_date, p_tier text default 'all',
                                                     p_days integer default 90)
returns jsonb language sql stable security definer set search_path = '' as $$
  with d as (
    select id, archetype_id a, weight from t1_private.meta_decks
     where format = p_format and on_date > p_through - p_days and on_date <= p_through and t1_private.meta_tier_in(tier, p_tier)),
  share as (select a, sum(weight) w from d group by a),
  cols as (
    select a, row_number() over (order by w desc, a) pos from share where a <> 0 order by w desc, a limit 10),
  games as (  -- a match's two decks are from the same event, so both are in the window
    select da.a aa, db.a ab, mm.result
      from t1_private.meta_matches mm join d da on da.id = mm.a join d db on db.id = mm.b
     where da.a <> db.a),
  played as (select a, count(*) n from (select aa a from games union all select ab from games) x group by a),
  rows as (
    select a, pos from cols
    union all
    select s.a, 10 + row_number() over (order by s.w desc, s.a) from share s join played p on p.a = s.a
     where s.a <> 0 and s.a not in (select a from cols) and p.n >= 20 and s.w >= 0.01 * (select sum(w) from share)
    union all
    select 0, 1000 from played where a = 0 and n >= 20),
  m as (
    select ra.pos pa, rb.pos pb, g.aa, g.ab, g.result
      from games g join rows ra on ra.a = g.aa join rows rb on rb.a = g.ab),
  o as (  -- orient each match so the first archetype is the one listed first
    select least(pa, pb) p1, greatest(pa, pb) p2,
           case when pa < pb then aa else ab end x, case when pa < pb then ab else aa end y,
           case when result = 'draw' then 'draw' when (result = 'a') = (pa < pb) then 'x' else 'y' end r
      from m)
  select jsonb_build_object(
    'archetypes', coalesce((select jsonb_agg(a order by pos) from cols), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(a order by pos) from rows), '[]'::jsonb),
    'cells', coalesce((select jsonb_agg(jsonb_build_array(x, y, xw, yw, dr) order by p1, p2) from (
        select p1, p2, x, y, count(*) filter (where r = 'x') xw, count(*) filter (where r = 'y') yw,
               count(*) filter (where r = 'draw') dr
          from o group by p1, p2, x, y) c), '[]'::jsonb));
$$;

revoke execute on function public.meta_pack_matchups(text, date, text, integer) from public, anon, authenticated;
grant execute on function public.meta_pack_matchups(text, date, text, integer) to service_role;

-- The names Modern players use (Frank Karsten's charts). Persist decks splash red for Faithless Looting.
with renamed as (
  update t1_private.meta_archetypes a
     set name = v.new, colors = coalesce(v.colors, a.colors), source = 'john', updated_at = now()
    from (values ('Eldrazi Bloodchief Combo', 'Broodscale Combo', null),
                 ('Rakdos Moonshadow', 'Rakdos Delirium', null),
                 ('Azorius Control', 'Azorius Chant', null),
                 ('Goryo''s Vengeance', 'Esper Goryo''s', null),
                 ('Neoform', 'Simic Neoform', null),
                 ('Persist', 'Grixis Reanimator', 'UBR')) v(old, new, colors)
   where a.format = 'modern' and a.name = v.old
     and not exists (select 1 from t1_private.meta_archetypes t where t.format = 'modern' and t.name = v.new)
  returning a.id, a.format, a.name, a.family, v.old)
insert into t1_private.insights_audit (actor, action, target, detail)
select null, 'archetype_rename', format || ':' || id, jsonb_build_object('name', name, 'family', family, 'from', old) from renamed;
