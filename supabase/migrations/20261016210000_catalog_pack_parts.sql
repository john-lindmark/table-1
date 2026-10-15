-- The catalog pack body in parts: one line type (0 = O, 1 = P, 2 = N) for a window of cards by pack index, so no
-- single statement nears the 8s statement timeout as sets (and printed names in ten languages) keep coming. The
-- whole body took 3.7s on 2026-10-16. cards-sync joins the parts with "\n" in order (kind, then window), which is
-- exactly catalog_pack_body(): same text, same version hash. Null when the window has no lines of that kind.
create or replace function public.catalog_pack_part(p_kind integer, p_from bigint, p_to bigint)
returns text language plpgsql stable security definer set search_path = '' as $$
declare v text;
begin
  if p_kind = 0 then
    with o as (
      select oracle_id, name, name_norm, face_names, type_line, mana_cost, cmc, colors, legalities,
             (row_number() over (order by name_norm, oracle_id)) - 1 idx
        from public.card_oracles
    )
    select string_agg(
             concat_ws(E'\t', 'O', o.idx, o.oracle_id, translate(o.name, E'\t\n\r', '   '), o.name_norm,
                       translate(coalesce(o.type_line, ''), E'\t\n\r', '   '), coalesce(o.mana_cost, ''),
                       coalesce(o.cmc::text, ''), array_to_string(o.colors, ''),
                       array_to_string(o.face_names, ' // '),
                       (select string_agg(case o.legalities->>f when 'legal' then 'L' when 'restricted' then 'R'
                                                                 when 'banned' then 'B' else '-' end, '' order by ord)
                          from unnest(array['standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper', 'commander',
                                            'premodern']) with ordinality as fm(f, ord)),
                       coalesce((select fp.points::text from public.format_points fp
                                  where fp.format = 'canlander' and fp.oracle_id = o.oracle_id), '')),
             E'\n' order by o.idx)
      into v
      from o where o.idx >= p_from and o.idx < p_to;
  elsif p_kind = 1 then
    with o as (
      select oracle_id, (row_number() over (order by name_norm, oracle_id)) - 1 idx from public.card_oracles
    ),
    w as (select * from o where o.idx >= p_from and o.idx < p_to),
    orig as (
      select distinct on (c.oracle_id) c.id
        from public.cards c join w on w.oracle_id = c.oracle_id left join public.mtg_sets s on s.code = c.set_code
       order by c.oracle_id,
                (c.lang = 'en' and c.image_faces > 0
                   and coalesce(s.set_type, '') not in ('promo', 'token', 'memorabilia', 'alchemy', 'minigame')) desc,
                (c.lang = 'en' and c.image_faces > 0) desc,
                c.released_at nulls last,
                (c.collector_number ~ '^[0-9]+$') desc,
                length(c.collector_number), c.collector_number, c.set_code
    )
    select string_agg(
             concat_ws(E'\t', 'P', c.id, w.idx, c.set_code, c.collector_number, c.lang, left(c.rarity, 1),
                       (select string_agg(left(f, 1), '' order by f) from unnest(c.finishes) f),
                       coalesce(c.released_at::text, ''), coalesce(c.image_ts::text, ''), c.image_faces,
                       translate(coalesce(c.printed_name, ''), E'\t\n\r', '   '),
                       case when orig.id is not null then '1' else '' end),
             E'\n' order by w.idx, c.released_at desc nulls last, c.set_code, c.collector_number)
      into v
      from public.cards c join w on w.oracle_id = c.oracle_id left join orig on orig.id = c.id;
  elsif p_kind = 2 then
    with o as (
      select oracle_id, name_norm, face_names, (row_number() over (order by name_norm, oracle_id)) - 1 idx
        from public.card_oracles
    ),
    w as (select * from o where o.idx >= p_from and o.idx < p_to)
    select string_agg(concat_ws(E'\t', 'N', w.idx, n.lang, translate(n.printed_name, E'\t\n\r', '   ')),
                      E'\n' order by w.idx, n.lang, n.printed_name)
      into v
      from t1_private.card_printed_names n join w on w.oracle_id = n.oracle_id
     where n.name_norm <> w.name_norm
       and not n.name_norm = any (select public.card_name_norm(f) from unnest(w.face_names) f);
  end if;
  return v;
end $$;

revoke all on function public.catalog_pack_part(integer, bigint, bigint) from public, anon, authenticated;
grant execute on function public.catalog_pack_part(integer, bigint, bigint) to service_role;
