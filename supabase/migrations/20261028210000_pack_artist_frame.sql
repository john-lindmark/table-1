-- Scanner printings: the illustrator and frame of every printing, on the catalog pack's P lines
-- (contract/catalog-2026-10-14.md, fields 14 and 15; contract/trades-2026-10-16.md § Scanning). A card in the retro
-- frame reads its "Illus. <artist>" line clearly and the tiny set code and collector number rarely, and nothing in
-- the pack said which printings are old or retro frames or who drew them, so MH2's retro fetchlands went in as
-- Zendikar's (2026-10-28 scan reports). Filled by cards-sync v11+ through catalog_art_ingest, called right after
-- catalog_ingest for the same rows; read only by the pack builders.
-- Replaces public.catalog_pack_part (20261016210000) and public.catalog_pack_body (20261018120000): both gain a
-- left join on t1_private.card_art and the two trailing fields, written only for printings that have a row, so the
-- pack is byte-identical until the first art ingest.

create table if not exists t1_private.card_art (
  card_id uuid primary key references public.cards (id) on delete cascade,
  artist text not null default '',
  -- Scryfall's frame: 1993, 1997, 2003, 2015 or future.
  frame text not null default ''
);
alter table t1_private.card_art enable row level security;

-- ==================================================================== ingest
-- Rows: [{id, artist, frame}]. Cards the catalog doesn't hold (yet) are skipped; unchanged rows aren't rewritten.
-- Returns how many rows were written.
create or replace function public.catalog_art_ingest(p_run bigint, p_rows jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare v integer;
begin
  if not exists (select 1 from t1_private.catalog_runs where id = p_run) then
    raise exception 'unknown catalog run %', p_run using errcode = 'P0002';
  end if;
  insert into t1_private.card_art as a (card_id, artist, frame)
  select r.id, left(translate(coalesce(r.artist, ''), E'\t\n\r', '   '), 200), left(coalesce(r.frame, ''), 10)
    from jsonb_to_recordset(p_rows) as r(id uuid, artist text, frame text)
    join public.cards c on c.id = r.id
  on conflict (card_id) do update set artist = excluded.artist, frame = excluded.frame
   where a.artist is distinct from excluded.artist or a.frame is distinct from excluded.frame;
  get diagnostics v = row_count;
  return v;
end $$;
revoke all on function public.catalog_art_ingest(bigint, jsonb) from public, anon, authenticated;
grant execute on function public.catalog_art_ingest(bigint, jsonb) to service_role;

-- ==================================================================== pack
create or replace function public.catalog_pack_part(p_kind integer, p_from bigint, p_to bigint)
returns text language plpgsql stable security definer set search_path = '' as $$
declare v text;
begin
  if p_kind = 0 then
    v := t1_private.catalog_pack_o_lines(p_from, p_to);
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
                       case when orig.id is not null then '1' else '' end,
                       -- Both or neither: concat_ws skips nulls, so a printing without art ends at original.
                       case when a.card_id is null then null else a.artist end,
                       case when a.card_id is null then null else a.frame end),
             E'\n' order by w.idx, c.released_at desc nulls last, c.set_code, c.collector_number)
      into v
      from public.cards c join w on w.oracle_id = c.oracle_id left join orig on orig.id = c.id
           left join t1_private.card_art a on a.card_id = c.id;
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

create or replace function public.catalog_pack_body()
returns text language sql stable security definer set search_path = '' as $$
  with o as (
    select oracle_id, name_norm, face_names, (row_number() over (order by name_norm, oracle_id)) - 1 idx
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
  select concat_ws(E'\n', t1_private.catalog_pack_o_lines(0, 9223372036854775807), string_agg(line, E'\n' order by k, idx, d desc nulls last, s, cn)) from (
    select 1 k, o.idx, c.released_at d, c.set_code s, c.collector_number cn,
           concat_ws(E'\t', 'P', c.id, o.idx, c.set_code, c.collector_number, c.lang, left(c.rarity, 1),
                     (select string_agg(left(f, 1), '' order by f) from unnest(c.finishes) f),
                     coalesce(c.released_at::text, ''), coalesce(c.image_ts::text, ''), c.image_faces,
                     translate(coalesce(c.printed_name, ''), E'\t\n\r', '   '),
                     case when orig.id is not null then '1' else '' end,
                     case when a.card_id is null then null else a.artist end,
                     case when a.card_id is null then null else a.frame end) line
      from public.cards c join o on o.oracle_id = c.oracle_id left join orig on orig.id = c.id
           left join t1_private.card_art a on a.card_id = c.id
    union all
    select 2, o.idx, null, n.lang, n.printed_name,
           concat_ws(E'\t', 'N', o.idx, n.lang, translate(n.printed_name, E'\t\n\r', '   '))
      from t1_private.card_printed_names n join o on o.oracle_id = n.oracle_id
     where n.name_norm <> o.name_norm
       and not n.name_norm = any (select public.card_name_norm(f) from unnest(o.face_names) f)
  ) t;
$$;
