-- Canadian Highlander ("canlander"): a 100-card singleton format with a points list (each deck may hold at most 10
-- points). The official list (canadianhighlander.ca/points-list) is copied into format_points by cards-sync before
-- each pack build, and the pack carries each card's points as O line field 12 (empty = 0), so clients total a deck's
-- points offline. Legality follows Vintage's banned list (restricted cards are fine: everything is a singleton).
create table if not exists public.format_points (
  format text not null,
  oracle_id uuid not null references public.card_oracles (oracle_id) on delete cascade,
  points smallint not null check (points between 1 and 99),
  updated_at timestamptz not null default now(),
  primary key (format, oracle_id)
);
alter table public.format_points enable row level security; -- read through the catalog pack only
create index if not exists card_oracles_name_norm_idx on public.card_oracles (name_norm);

-- Replaces a format's points from [{name, points}], matching names (or a double-faced card's front face).
-- Returns the names that matched no card. An empty list changes nothing (a failed fetch never wipes points).
create or replace function public.format_points_replace(p_format text, p_rows jsonb)
returns text[] language plpgsql security definer set search_path = '' as $$
declare v_missing text[];
begin
  if p_rows is null or jsonb_array_length(p_rows) = 0 then return array[]::text[]; end if;
  -- Each name is normalized once, then matched through the name_norm index (or a front face).
  create temp table fp_in on commit drop as
    with r as (
      select x->>'name' name, (x->>'points')::smallint points, public.card_name_norm(x->>'name') norm
        from jsonb_array_elements(p_rows) x
    )
    select r.name, r.points,
           coalesce((select o.oracle_id from public.card_oracles o where o.name_norm = r.norm limit 1),
                    (select o.oracle_id from public.card_oracles o where o.face_names[1] = r.name limit 1)) oracle_id
      from r;
  select coalesce(array_agg(name order by name), array[]::text[]) into v_missing from fp_in where oracle_id is null;
  delete from public.format_points where format = p_format;
  insert into public.format_points (format, oracle_id, points)
  select p_format, oracle_id, max(points) from fp_in where oracle_id is not null and points > 0 group by oracle_id;
  return v_missing;
end $$;
revoke execute on function public.format_points_replace(text, jsonb) from public, anon, authenticated;
grant execute on function public.format_points_replace(text, jsonb) to service_role;

create or replace function public.catalog_pack_body()
returns text language sql stable security definer set search_path = '' as $$
  with o as (
    select oracle_id, name, name_norm, face_names, type_line, mana_cost, cmc, colors, legalities,
           (row_number() over (order by name_norm, oracle_id)) - 1 idx
      from public.card_oracles
  ),
  orig as (
    select distinct on (c.oracle_id) c.id
      from public.cards c left join public.mtg_sets s on s.code = c.set_code
     order by c.oracle_id,
              (c.lang = 'en' and c.image_faces > 0
                 and coalesce(s.set_type, '') not in ('promo', 'token', 'memorabilia', 'alchemy', 'minigame')) desc,
              (c.lang = 'en' and c.image_faces > 0) desc,
              c.released_at nulls last,
              (c.collector_number ~ '^[0-9]+$') desc,
              length(c.collector_number), c.collector_number, c.set_code
  )
  select string_agg(line, E'\n' order by k, idx, d desc nulls last, s, cn) from (
    select 0 k, o.idx, null::date d, null::text s, null::text cn,
           concat_ws(E'\t', 'O', o.idx, o.oracle_id, translate(o.name, E'\t\n\r', '   '), o.name_norm,
                     translate(coalesce(o.type_line, ''), E'\t\n\r', '   '), coalesce(o.mana_cost, ''),
                     coalesce(o.cmc::text, ''), array_to_string(o.colors, ''),
                     array_to_string(o.face_names, ' // '),
                     (select string_agg(case o.legalities->>f when 'legal' then 'L' when 'restricted' then 'R'
                                                               when 'banned' then 'B' else '-' end, '' order by ord)
                        from unnest(array['standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'commander',
                                          'premodern']) with ordinality as fm(f, ord)),
                     coalesce((select fp.points::text from public.format_points fp
                                where fp.format = 'canlander' and fp.oracle_id = o.oracle_id), '')) line
      from o
    union all
    select 1, o.idx, c.released_at, c.set_code, c.collector_number,
           concat_ws(E'\t', 'P', c.id, o.idx, c.set_code, c.collector_number, c.lang, left(c.rarity, 1),
                     (select string_agg(left(f, 1), '' order by f) from unnest(c.finishes) f),
                     coalesce(c.released_at::text, ''), coalesce(c.image_ts::text, ''), c.image_faces,
                     translate(coalesce(c.printed_name, ''), E'\t\n\r', '   '),
                     case when orig.id is not null then '1' else '' end)
      from public.cards c join o on o.oracle_id = c.oracle_id left join orig on orig.id = c.id
  ) t;
$$;
