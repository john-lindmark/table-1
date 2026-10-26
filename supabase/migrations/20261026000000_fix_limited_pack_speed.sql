-- Bug #15: limited_pack_facts ran past the 8 s statement timeout (FRA took 10 s on live). limited_view looked up each
-- card's weekly GIH and pair GIH, and each pair's weekly win rate and share, with a subquery per card × week over
-- the whole run's sums (~6,500 rows a run), so the cost grew with cards × weeks × rows. Same output, but those values
-- now come from one grouped pass each, joined by name.
create or replace function t1_private.limited_view(p_game bigint, p_draft bigint, p_grp text, p_set text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_tot record;
  v_weeks integer;
  v jsonb;
begin
  select g, w into v_tot from t1_private.limited_acc where run_id = p_game and k = 'T|' || p_grp;
  if v_tot.g is null or v_tot.g = 0 then return null; end if;
  select coalesce(max(split_part(k, '|', 3)::integer), 0) into v_weeks
    from t1_private.limited_acc where run_id = p_game and k like 'pw|%' and split_part(k, '|', 4) = p_grp;
  with acc as (select k, g, w, split_part(k, '|', 1) t, split_part(k, '|', 2) a, split_part(k, '|', 3) b, split_part(k, '|', 4) c
                 from t1_private.limited_acc where run_id = p_game),
  weeks as (select wk, wk::text b from generate_series(1, greatest(v_weeks, 1)) wk),
  pairs as (
    select a p, g, w from acc where t = 'p' and b = p_grp),
  pair_more as (
    select a p, max(g) filter (where t = 'ps') ps_g, max(g) filter (where t = 'pp') pp_g, max(w) filter (where t = 'pp') pp_w
      from acc where t in ('ps', 'pp') and b = p_grp group by a),
  pw as (select a p, b, g, w from acc where t = 'pw' and c = p_grp),
  pw_week as (select b, sum(g) g from pw group by b),
  pair_weeks as (
    select p.p,
           jsonb_agg(round(x.w::numeric / nullif(x.g, 0), 4) order by s.wk) week_wr,
           jsonb_agg(round(coalesce(x.g, 0)::numeric / nullif(t.g, 0), 4) order by s.wk) week_share
      from pairs p cross join weeks s
      left join pw x on x.p = p.p and x.b = s.b
      left join pw_week t on t.b = s.b
     group by p.p),
  cards as (
    select a n,
           max(g) filter (where t = 'cd' and b = p_grp) deck_g,
           max(g) filter (where t = 'ch' and b = p_grp) ch_g, max(w) filter (where t = 'ch' and b = p_grp) ch_w,
           max(g) filter (where t = 'co' and b = p_grp) co_g, max(w) filter (where t = 'co' and b = p_grp) co_w,
           max(g) filter (where t = 'cg' and b = p_grp) cg_g, max(w) filter (where t = 'cg' and b = p_grp) cg_w,
           max(g) filter (where t = 'cn' and b = p_grp) cn_g, max(w) filter (where t = 'cn' and b = p_grp) cn_w
      from acc where t in ('cd', 'ch', 'co', 'cg', 'cn') group by a),
  cw as (select a n, b, g, w from acc where t = 'cw' and g >= 200),
  card_weeks as (
    select c.n, jsonb_agg(round(x.w::numeric / nullif(x.g, 0), 4) order by s.wk) vals
      from cards c cross join weeks s
      left join cw x on x.n = c.n and x.b = s.b
     where p_grp = 'a'
     group by c.n),
  card_pairs as (
    select a n, jsonb_object_agg(b, round(w::numeric / g, 4)) vals from acc where t = 'cp' and g >= 200 and p_grp = 'a' group by a)
  select jsonb_build_object(
    'games', v_tot.g, 'wr', round(v_tot.w::numeric / v_tot.g, 4), 'weeks', v_weeks,
    'pairs', coalesce((select jsonb_agg(jsonb_build_object(
        'p', p.p, 'games', p.g, 'wr', round(p.w::numeric / nullif(p.g, 0), 4), 'share', round(p.g::numeric / v_tot.g, 4),
        'splash', round(coalesce(m.ps_g, 0)::numeric / nullif(p.g, 0), 4),
        'play_wr', round(m.pp_w::numeric / nullif(m.pp_g, 0), 4),
        'draw_wr', round((p.w - m.pp_w)::numeric / nullif(p.g - m.pp_g, 0), 4),
        'week_wr', pk.week_wr,
        'week_share', pk.week_share)
        order by p.g desc)
        from pairs p left join pair_more m on m.p = p.p left join pair_weeks pk on pk.p = p.p), '[]'::jsonb),
    'cards', coalesce((select jsonb_agg(jsonb_build_object(
        'c', lc.oracle_id, 'n', c.n, 'r', lc.rarity, 'col', lc.col,
        'gih', case when c.ch_g >= 500 then round(c.ch_w::numeric / c.ch_g, 4) end, 'gih_n', coalesce(c.ch_g, 0),
        'oh', case when c.ch_g >= 500 and c.co_g > 0 then round(c.co_w::numeric / c.co_g, 4) end,
        'gd', case when c.ch_g >= 500 and c.cg_g > 0 then round(c.cg_w::numeric / c.cg_g, 4) end,
        'gns', case when c.ch_g >= 500 and c.cn_g > 0 then round(c.cn_w::numeric / c.cn_g, 4) end,
        'iwd', case when c.ch_g >= 500 and c.cn_g > 0 then round(c.ch_w::numeric / c.ch_g - c.cn_w::numeric / c.cn_g, 4) end,
        'ata', (select round(w::numeric / nullif(g, 0), 2) from t1_private.limited_acc where run_id = p_draft and k = 'a|' || c.n || '|' || p_grp),
        'deck', round(coalesce(c.deck_g, 0)::numeric / v_tot.g, 4),
        'week_gih', case when p_grp = 'a' then cwk.vals end,
        'pair_gih', case when p_grp = 'a' then coalesce(cpr.vals, '{}'::jsonb) end)
        order by c.ch_g desc nulls last, c.n)
        from cards c left join lateral t1_private.limited_card(p_set, c.n) lc on true
        left join card_weeks cwk on cwk.n = c.n
        left join card_pairs cpr on cpr.n = c.n
       where coalesce(c.deck_g, 0) > 0), '[]'::jsonb),
    -- every exact colour combination (main + splash) on 0.5% of games or more, most played first
    'colors', coalesce((select jsonb_agg(jsonb_build_object('m', a, 's', b, 'games', g, 'wr', round(w::numeric / g, 4),
                                                          'share', round(g::numeric / v_tot.g, 4)) order by g desc, a, b)
                          from acc where t = 'dc' and c = p_grp and g::numeric / v_tot.g >= 0.005), '[]'::jsonb),
    'facts', jsonb_build_object(
      'play_wr', (select round(w::numeric / nullif(g, 0), 4) from acc where t = 'P' and a = p_grp),
      'draw_wr', (select round(w::numeric / nullif(g, 0), 4) from acc where t = 'D' and a = p_grp),
      'mull_rate', (select round(g::numeric / v_tot.g, 4) from acc where t = 'M' and a = p_grp),
      'mull_wr', (select round(w::numeric / nullif(g, 0), 4) from acc where t = 'M' and a = p_grp),
      'keep7_wr', (select round(w::numeric / nullif(g, 0), 4) from acc where t = 'K' and a = p_grp),
      'mull_play', (select round(g::numeric / nullif((select g from acc where t = 'P' and a = p_grp), 0), 4) from acc where t = 'MP' and a = p_grp),
      'turns', (select round(w::numeric / nullif(g, 0), 1) from acc where t = 'N' and a = p_grp)))
  into v;
  return v;
end $$;
