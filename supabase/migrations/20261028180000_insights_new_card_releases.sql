-- Set releases on the Insights charts only for sets that bring a format new cards (John, 2026-10-28): Modern showed
-- Mystery Booster Commander, whose cards legal in Modern are all reprints. As in 20261026010000_insights_points.sql
-- apart from the set release rule.

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

  -- A day's points changes (Canadian Highlander's list, read with the catalog) are one change per format: confirmed
  -- when 15 cards or fewer moved (an official update), proposed for review when more did (a list read half-wrong).
  with p as (
    select l.format, l.seen, count(*) n,
           array_agg(l.name order by coalesce(l.after, 0) desc, l.name) cards,
           jsonb_agg(jsonb_build_object('n', l.name, 'before', coalesce(l.before, 0), 'after', coalesce(l.after, 0))
                     order by coalesce(l.after, 0) desc, l.name) detail,
           string_agg(l.name || ' ' || coalesce(l.before, 0) || ' → ' || coalesce(l.after, 0), ', '
                      order by coalesce(l.after, 0) desc, l.name) note
      from t1_private.meta_points_log l where not l.proposed group by 1, 2)
  insert into t1_private.meta_format_changes (format, on_date, kind, cards, detail, note, status)
  select format, seen, 'points', cards, detail, note, case when n <= 15 then 'confirmed' else 'proposed' end from p
  on conflict (format, on_date, kind, set_code) do nothing;
  update t1_private.meta_points_log set proposed = true where not proposed;

  -- A set is a release for a format only when it brings the format a new card: one legal there with no earlier
  -- printing. Reprints don't count, so Mystery Booster Commander is not a Modern release.
  insert into t1_private.meta_format_changes (format, on_date, kind, set_code, cards, status, note)
  select f.format, s.released_at, 'set_release', s.code, '{}', 'confirmed', s.name
    from public.mtg_sets s cross join t1_private.meta_formats f
   where s.set_type in ('expansion', 'core', 'draft_innovation') and not s.digital
     and s.released_at between current_date - 400 and current_date
     and exists (select 1 from public.cards c join public.card_oracles o on o.oracle_id = c.oracle_id
                  where c.set_code = s.code and o.legalities->>coalesce(f.legality, f.format) in ('legal', 'restricted')
                    and not exists (select 1 from public.cards e where e.oracle_id = c.oracle_id and e.released_at < s.released_at)
                  limit 1)
  on conflict (format, on_date, kind, set_code) do nothing;
end $$;

-- Drop the releases the old rule let in (Mystery Booster Commander everywhere, every set in Premodern).
delete from t1_private.meta_format_changes ch
 using public.mtg_sets s, t1_private.meta_formats f
 where ch.kind = 'set_release' and s.code = ch.set_code and f.format = ch.format
   and not exists (select 1 from public.cards c join public.card_oracles o on o.oracle_id = c.oracle_id
                    where c.set_code = s.code and o.legalities->>coalesce(f.legality, f.format) in ('legal', 'restricted')
                      and not exists (select 1 from public.cards e where e.oracle_id = c.oracle_id and e.released_at < s.released_at));
