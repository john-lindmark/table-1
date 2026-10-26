-- Insights: Canadian Highlander (contract/insights-2026-10-24.md § Sources and tiers). Its events come from TopDeck.gg
-- only (MTGO has no Canadian Highlander), and they're small: TopDeck is read from 16 players up for it, against 32
-- for the other formats. Scryfall has no Canadian Highlander legality, so a set counts as reaching it when its cards
-- are legal in Vintage (the format's base). meta-sync now reads the formats from here instead of its own copy.

alter table t1_private.meta_formats
  add column if not exists legality text,                         -- Scryfall legality key when it isn't the format
  add column if not exists topdeck_min integer not null default 32; -- smallest TopDeck event read

update t1_private.meta_formats set ord = ord + 1 where format in ('legacy', 'vintage', 'premodern') and ord < 8;
insert into t1_private.meta_formats (format, name, ord, enabled, topdeck, legality, topdeck_min)
values ('canlander', 'Canadian Highlander', 5, true, 'Canadian Highlander', 'vintage', 16)
on conflict (format) do nothing;

-- The enabled formats, for meta-sync: names, order, TopDeck's name and minimum size.
create or replace function public.meta_formats_enabled()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('format', format, 'name', name, 'ord', ord, 'topdeck', topdeck,
                                               'topdeck_min', topdeck_min) order by ord), '[]'::jsonb)
    from t1_private.meta_formats where enabled;
$$;
revoke execute on function public.meta_formats_enabled() from public, anon, authenticated;
grant execute on function public.meta_formats_enabled() to service_role;

-- As in 20261025120000_insights.sql, with the legality key from meta_formats.legality.
create or replace function public.meta_pack_new_set(p_format text, p_tier text, p_through date default current_date)
returns jsonb language sql stable security definer set search_path = '' as $$
  with lf as (select coalesce(legality, format) k from t1_private.meta_formats where format = p_format),
  s as (
    select ms.code, ms.name, ms.released_at from public.mtg_sets ms
     where ms.set_type in ('expansion', 'core', 'draft_innovation') and not ms.digital and ms.released_at <= p_through
       and ms.released_at > p_through - 400
       and (select count(distinct c.oracle_id) from public.cards c join public.card_oracles o on o.oracle_id = c.oracle_id
             where c.set_code = ms.code and o.legalities->>(select k from lf) in ('legal', 'restricted')
               and not exists (select 1 from public.cards c2 where c2.oracle_id = c.oracle_id and c2.released_at < ms.released_at)) >= 10
     order by ms.released_at desc limit 1),
  fresh as (
    select c.oracle_id from public.cards c, s where c.set_code = s.code
     group by c.oracle_id
    having not exists (select 1 from public.cards c2 where c2.oracle_id = c.oracle_id and c2.released_at < (select released_at from s))),
  dk as (
    select d.* from t1_private.meta_decks d, s
     where d.format = p_format and d.on_date >= s.released_at and d.on_date > p_through - 90 and d.on_date <= p_through
       and t1_private.meta_tier_in(d.tier, p_tier)),
  tot as (select sum(weight) w from dk),
  play as (
    select u.id, sum(d.weight) w, sum(d.weight * u.q) wq,
           (select array_agg(a order by aw desc) from (
               select d2.archetype_id a, sum(d2.weight) aw from dk d2
                where u.id = any(d2.main) or u.id = any(d2.side) group by 1 order by 2 desc limit 3) t) arch
      from dk d cross join lateral unnest(d.main || d.side, d.main_qty || d.side_qty) u(id, q)
     where u.id in (select oracle_id from fresh)
     group by u.id)
  select case when (select code from s) is null then null else jsonb_build_object(
    'set_code', (select code from s), 'name', (select name from s), 'released', (select released_at::text from s),
    'cards', coalesce((select jsonb_agg(jsonb_build_object('c', p.id, 'n', o.name, 'rate', round(p.w / nullif((select w from tot), 0), 4),
                                                       'copies', round(p.wq / p.w, 2), 'in', to_jsonb(p.arch))
                                      order by p.w desc, o.name)
                         from (select * from play order by w desc limit 12) p join public.card_oracles o on o.oracle_id = p.id), '[]'::jsonb))
  end;
$$;

-- As in 20261025120000_insights.sql, with set releases checked against meta_formats.legality.
create or replace function t1_private.meta_legality_propose()
returns void language plpgsql security definer set search_path = '' as $$
begin
  with x as (
    select l.format, l.seen,
           case when l.after = 'banned' then 'ban'
                when l.before = 'banned' then 'unban'
                when l.after = 'restricted' then 'restrict'
                when l.before = 'restricted' and l.after = 'legal' then 'unrestrict'
                when l.before = 'legal' and l.after is null then 'rotation' end kind,
           o.name
      from t1_private.meta_legality_log l join public.card_oracles o on o.oracle_id = l.oracle_id
     where not l.proposed),
  g as (select format, seen, kind, array_agg(name order by name) cards from x where kind is not null group by 1, 2, 3)
  insert into t1_private.meta_format_changes (format, on_date, kind, cards, status, note)
  select format, seen, kind, cards, 'proposed', 'From the catalog''s daily legality check'
    from g where kind <> 'rotation' or cardinality(cards) >= 50
  on conflict (format, on_date, kind, set_code) do nothing;
  update t1_private.meta_legality_log set proposed = true where not proposed;

  insert into t1_private.meta_format_changes (format, on_date, kind, set_code, cards, status, note)
  select f.format, s.released_at, 'set_release', s.code, '{}', 'confirmed', s.name
    from public.mtg_sets s cross join t1_private.meta_formats f
   where s.set_type in ('expansion', 'core', 'draft_innovation') and not s.digital
     and s.released_at between current_date - 400 and current_date
     and exists (select 1 from public.cards c join public.card_oracles o on o.oracle_id = c.oracle_id
                  where c.set_code = s.code and o.legalities->>coalesce(f.legality, f.format) in ('legal', 'restricted') limit 1)
  on conflict (format, on_date, kind, set_code) do nothing;
end $$;
