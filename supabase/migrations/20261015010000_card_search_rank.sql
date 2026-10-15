-- search_cards: a match on a card's full name outranks a match on another card's face name
-- ("lightning bolt" → Lightning Bolt before Emeritus of Conflict // Lightning Bolt).
create or replace function public.search_cards(p_query text, p_limit integer default 20)
returns table (oracle_id uuid, name text, type_line text, mana_cost text,
               default_card_id uuid, image_ts bigint, image_faces smallint)
language sql stable security definer set search_path = '' as $$
  with q as (select public.card_name_norm(p_query) q),
  hits as (
    select n.oracle_id, min(case when n.name_norm like (select q from q) || '%' then 0 else 1 end) rank,
           max(extensions.similarity(n.name_norm, (select q from q))) sim,
           max(case when n.is_face then 0 else extensions.similarity(n.name_norm, (select q from q)) end) full_sim
      from public.card_names n
     where char_length((select q from q)) >= 2
       and (n.name_norm like (select q from q) || '%'
            or n.name_norm operator(extensions.%) (select q from q))
     group by n.oracle_id
  ), top as (
    select h.*, o.name, o.type_line, o.mana_cost,
           o.layout in ('token', 'double_faced_token', 'emblem', 'art_series') extra
      from hits h join public.card_oracles o on o.oracle_id = h.oracle_id
     order by h.rank, extra, h.sim desc, h.full_sim desc, o.name
     limit least(greatest(coalesce(p_limit, 20), 1), 50)
  )
  select t.oracle_id, t.name, t.type_line, t.mana_cost, c.id, c.image_ts, c.image_faces
    from top t
    left join lateral (
      select c.id, c.image_ts, c.image_faces from public.cards c
       where c.oracle_id = t.oracle_id
       order by (c.lang = 'en') desc, (c.image_ts is not null) desc, c.released_at desc nulls last
       limit 1) c on true
   order by t.rank, t.extra, t.sim desc, t.full_sim desc, t.name;
$$;
grant execute on function public.search_cards(text, integer) to anon, authenticated;
