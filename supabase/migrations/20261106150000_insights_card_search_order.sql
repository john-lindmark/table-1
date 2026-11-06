-- Card search order (contract/insights-2026-10-24.md § RPCs), after the first live searches on 2026-11-06: "bolt"
-- put Boltwave (0.9% of Modern lists) above Lightning Bolt (23%), since a name starting with the words outranked a
-- word inside it starting with them; both now rank together, by how much each was played. Basic lands are left out
-- before the limit, so they no longer use up a result.

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
                    when n.name_norm like v_q || '%' or n.name_norm like '% ' || v_q || '%' then 1
                    when strpos(n.name_norm, v_q) > 0 then 2
                    else 3 end) rank
      from seen s join public.card_names n on n.oracle_id = s.card
      join public.card_oracles o on o.oracle_id = s.card and coalesce(o.type_line, '') !~ '^Basic'
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
    join public.card_oracles o on o.oracle_id = h.card;
  return v;
end $$;
