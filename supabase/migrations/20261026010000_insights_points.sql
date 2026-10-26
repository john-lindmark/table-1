-- Insights: Canadian Highlander's points changes take the place bans have in other formats (contract/insights-2026-10-24.md
-- § Format changes). The points list is replaced from canadianhighlander.ca with every catalog build; each card whose
-- points moved is logged (meta_points_log), the daily proposer turns a day's moves into one `points` change with
-- each card's before and after in `detail` and in words in `note` ("Mana Crypt 3 → 4"), and ban studies run on it:
-- cards that gained points are treated like a ban (who held them, who lost share), cards that lost points like an
-- unban (who picked them up). The site keeps no history, so changes start from the list read on 2026-10-25.

alter table t1_private.meta_format_changes drop constraint if exists meta_format_changes_kind_check;
alter table t1_private.meta_format_changes add constraint meta_format_changes_kind_check
  check (kind in ('ban', 'unban', 'restrict', 'unrestrict', 'set_release', 'rotation', 'points'));
alter table t1_private.meta_format_changes add column if not exists detail jsonb;   -- points: [{n, before, after}]

create table if not exists t1_private.meta_points_log (
  format text not null,
  oracle_id uuid not null,
  name text,
  before smallint,                               -- null: not on the list
  after smallint,                                -- null: taken off the list
  seen date not null default current_date,
  proposed boolean not null default false,
  primary key (format, oracle_id, seen)
);

-- As in 20261015200000_canlander_points.sql, logging what moved.
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
  -- What changed against the stored list, for Insights (a format's first list is a baseline, not a change).
  if exists (select 1 from public.format_points where format = p_format)
     and exists (select 1 from t1_private.meta_formats where format = p_format) then
    insert into t1_private.meta_points_log as l (format, oracle_id, name, before, after)
    select p_format, coalesce(o.oracle_id, n.oracle_id),
           (select c.name from public.card_oracles c where c.oracle_id = coalesce(o.oracle_id, n.oracle_id)), o.points, n.points
      from (select oracle_id, points from public.format_points where format = p_format) o
      full join (select oracle_id, max(points) points from fp_in where oracle_id is not null and points > 0 group by oracle_id) n
        on n.oracle_id = o.oracle_id
     where o.points is distinct from n.points
    on conflict (format, oracle_id, seen) do update set after = excluded.after;
  end if;
  delete from public.format_points where format = p_format;
  insert into public.format_points (format, oracle_id, points)
  select p_format, oracle_id, max(points) from fp_in where oracle_id is not null and points > 0 group by oracle_id;
  return v_missing;
end $$;

-- As in 20261025170000_insights_canlander.sql, adding the day's points changes.
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

  insert into t1_private.meta_format_changes (format, on_date, kind, set_code, cards, status, note)
  select f.format, s.released_at, 'set_release', s.code, '{}', 'confirmed', s.name
    from public.mtg_sets s cross join t1_private.meta_formats f
   where s.set_type in ('expansion', 'core', 'draft_innovation') and not s.digital
     and s.released_at between current_date - 400 and current_date
     and exists (select 1 from public.cards c join public.card_oracles o on o.oracle_id = c.oracle_id
                  where c.set_code = s.code and o.legalities->>coalesce(f.legality, f.format) in ('legal', 'restricted') limit 1)
  on conflict (format, on_date, kind, set_code) do nothing;
end $$;

-- As in 20261025120000_insights.sql, with points changes studied like bans (v_up) and unbans (v_down).
create or replace function public.meta_pack_bans(p_format text, p_through date default current_date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  ch t1_private.meta_format_changes;
  v_out jsonb := '[]'::jsonb;
  v_ids uuid[];
  v_after_days integer;
  v_study jsonb;
  v_up uuid[];      -- cards made harder to play (banned, restricted, more points): decks that held them lose
  v_down uuid[];    -- cards made easier to play (unbanned, unrestricted, fewer points): who picks them up
begin
  for ch in select * from t1_private.meta_format_changes
             where format = p_format and status = 'confirmed' and kind in ('ban', 'unban', 'restrict', 'unrestrict', 'points')
               and on_date > p_through - 365 and on_date <= p_through
             order by on_date desc, id desc loop
    select coalesce(array_agg(t1_private.meta_card_id(x)) filter (where t1_private.meta_card_id(x) is not null), '{}')
      into v_ids from unnest(ch.cards) x;
    if ch.kind = 'points' then
      select coalesce(array_agg(t1_private.meta_card_id(x->>'n')) filter (where coalesce((x->>'after')::int, 0) > coalesce((x->>'before')::int, 0)
                                                                          and t1_private.meta_card_id(x->>'n') is not null), '{}'),
             coalesce(array_agg(t1_private.meta_card_id(x->>'n')) filter (where coalesce((x->>'after')::int, 0) < coalesce((x->>'before')::int, 0)
                                                                          and t1_private.meta_card_id(x->>'n') is not null), '{}')
        into v_up, v_down from jsonb_array_elements(coalesce(ch.detail, '[]'::jsonb)) x;
    else
      v_up := case when ch.kind in ('ban', 'restrict') then v_ids else '{}' end;
      v_down := case when ch.kind in ('unban', 'unrestrict') then v_ids else '{}' end;
    end if;
    v_after_days := least(60, p_through - ch.on_date + 1);
    with dk as (
      select d.*, case when d.on_date < ch.on_date then 'before' else 'after' end w,
             (d.main || d.side) && v_up has_card
        from t1_private.meta_decks d
       where d.format = p_format and d.on_date >= ch.on_date - 30 and d.on_date < ch.on_date + v_after_days),
    tot as (select w, sum(weight) t from dk group by w),
    sh as (select dk.w, dk.archetype_id a, sum(dk.weight) / max(tot.t) s from dk join tot using (w) group by 1, 2),
    held as (select archetype_id a, sum(weight) filter (where has_card) / sum(weight) frac from dk where w = 'before' and archetype_id <> 0 group by 1),
    losers as (
      select h.a, coalesce(b.s, 0) bs, coalesce(af.s, 0) afs from held h
        left join sh b on b.a = h.a and b.w = 'before' left join sh af on af.a = h.a and af.w = 'after'
       where cardinality(v_up) > 0 and h.frac >= 0.5 and coalesce(b.s, 0) >= 0.01),
    gainers as (
      select coalesce(af.a, b.a) a, coalesce(b.s, 0) bs, coalesce(af.s, 0) afs
        from (select * from sh where w = 'after') af full join (select * from sh where w = 'before') b on b.a = af.a
       where coalesce(af.a, b.a) not in (select a from losers) and coalesce(af.a, b.a) <> 0 and coalesce(af.s, 0) > coalesce(b.s, 0)
       order by coalesce(af.s, 0) - coalesce(b.s, 0) desc limit 3),
    -- Losers: cards whose play rate in the loser's decks rose most. Unbans: the unbanned cards by archetype.
    lt as (
      select archetype_id a, sum(weight) filter (where w = 'before') bt, sum(weight) filter (where w = 'after') at
        from dk where archetype_id in (select a from losers) group by 1),
    repl as (
      select x.* from (
        select l.a, u.id,
               coalesce(sum(dk.weight) filter (where dk.w = 'before'), 0) / nullif(max(lt.bt), 0) bf,
               coalesce(sum(dk.weight) filter (where dk.w = 'after'), 0) / nullif(max(lt.at), 0) af
          from losers l
          join lt on lt.a = l.a
          join dk on dk.archetype_id = l.a
          cross join lateral unnest(dk.main) u(id)
         where not (u.id = any(v_ids))
         group by l.a, u.id) x
       where x.af is not null and not t1_private.meta_is_basic(x.id)),
    repl_top as (select * from (select r.*, row_number() over (partition by a order by af - coalesce(bf, 0) desc) rn from repl r) y where rn <= 3),
    adopt as (
      select dk.archetype_id a, u.id, sum(dk.weight) / nullif((select sum(weight) from dk d2 where d2.w = 'after' and d2.archetype_id = dk.archetype_id), 0) af
        from dk cross join lateral unnest(dk.main || dk.side) u(id)
       where cardinality(v_down) > 0 and dk.w = 'after' and dk.archetype_id <> 0 and u.id = any(v_down)
       group by 1, 2 order by 3 desc limit 5),
    win_after as (
      select n, (select jsonb_agg(jsonb_build_object('a', a, 'share', round(s, 4)) order by s desc) from (
                   select * from (select d.archetype_id a, sum(d.weight) / sum(sum(d.weight)) over () s
                                    from t1_private.meta_decks d
                                   where d.format = p_format and d.on_date >= ch.on_date and d.on_date < ch.on_date + n
                                   group by 1) x where s >= 0.005 order by s desc limit 20) t) j
        from unnest(array[14, 30, 60]) n where ch.on_date + n - 1 <= p_through),
    top_after as (select a from sh where w = 'after' order by s desc limit 8),
    days as (select (ch.on_date + g)::date d, g from generate_series(0, least(89, p_through - ch.on_date)) g),
    roll as (
      select t.a, dd.g,
             (select sum(d.weight) filter (where d.archetype_id = t.a) / nullif(sum(d.weight), 0)
                from t1_private.meta_decks d
               where d.format = p_format and d.on_date > dd.d - 7 and d.on_date <= dd.d) v
        from top_after t cross join days dd)
    select jsonb_build_object(
      'change', ch.id, 'on', ch.on_date::text,
      'before', coalesce((select jsonb_agg(jsonb_build_object('a', a, 'share', round(s, 4)) order by s desc)
                            from (select a, s from sh where w = 'before' and s >= 0.005 order by s desc limit 20) b), '[]'::jsonb),
      'after', coalesce((select jsonb_object_agg(n::text, coalesce(j, '[]'::jsonb)) from win_after), '{}'::jsonb),
      'after_days', v_after_days,
      'losers', coalesce((select jsonb_agg(jsonb_build_object('a', a, 'before', round(bs, 4), 'after', round(afs, 4)) order by bs desc) from losers), '[]'::jsonb),
      'gainers', coalesce((select jsonb_agg(jsonb_build_object('a', a, 'before', round(bs, 4), 'after', round(afs, 4)) order by afs - bs desc) from gainers), '[]'::jsonb),
      'replacements', coalesce((
        select jsonb_agg(jsonb_build_object('c', r.id, 'n', o.name, 'before', round(coalesce(r.bf, 0), 4), 'after', round(r.af, 4), 'in', r.a)
                         order by r.a, r.af - coalesce(r.bf, 0) desc)
          from (select a, id, bf, af from repl_top union all select a, id, 0, af from adopt) r
          join public.card_oracles o on o.oracle_id = r.id), '[]'::jsonb),
      'daily', jsonb_build_object('from', ch.on_date::text, 'lines', coalesce((
        select jsonb_agg(jsonb_build_object('a', a, 'v', v)) from (
          select a, jsonb_agg(round(v, 4) order by g) v from roll group by a) x), '[]'::jsonb)))
      into v_study;
    v_out := v_out || jsonb_build_array(v_study);
  end loop;
  return v_out;
end $$;
