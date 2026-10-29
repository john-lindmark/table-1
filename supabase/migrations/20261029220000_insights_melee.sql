-- Melee.gg results through fbettega/MTG_decklistcache (contract/insights-2026-10-24.md § Sources and tiers):
-- meta-sync lists the cache's MTGmelee files and queues them as source 'melee' with no format (the file says which),
-- then ingests the events of the enabled formats like TopDeck's: paper, whole-field records and rounds.
--   * meta_queue / meta_events take source 'melee'; a queued melee file has no format until it's read
--   * meta_queue_add: melee rows go in without a format (the rest as before: enabled formats only)
--   * meta_ingest: accepts 'melee' (body otherwise 20261025180000_insights_colour_rules.sql)
--   * meta_archetype: an archetype's record is paper events' (TopDeck or Melee) when there are any, as before for
--     TopDeck alone (body otherwise 20261026020000_insights_other_groups.sql)
--   * spice: spice_lists counts Melee lists, and a deck's basis names 'melee' among its sources
--     (bodies otherwise 20261028160000_spice.sql)

alter table t1_private.meta_queue drop constraint if exists meta_queue_source_check;
alter table t1_private.meta_queue add constraint meta_queue_source_check check (source in ('mtgo', 'topdeck', 'melee'));
alter table t1_private.meta_queue alter column format drop not null;
alter table t1_private.meta_queue drop constraint if exists meta_queue_format_known;
alter table t1_private.meta_queue add constraint meta_queue_format_known check (format is not null or source = 'melee');
alter table t1_private.meta_events drop constraint if exists meta_events_source_check;
alter table t1_private.meta_events add constraint meta_events_source_check check (source in ('mtgo', 'topdeck', 'melee'));
alter table t1_private.spice_lists add column if not exists melee integer not null default 0;

create or replace function public.meta_queue_add(p_items jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  insert into t1_private.meta_queue (source, format, slug, url)
  select i->>'source', case when i->>'source' <> 'melee' then i->>'format' end, i->>'slug', i->>'url'
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i
   where i->>'source' = 'melee' or exists (select 1 from t1_private.meta_formats f where f.format = i->>'format' and f.enabled)
  on conflict (source, slug) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.meta_ingest(p_event jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_set t1_private.meta_settings;
  v_event bigint;
  v_tier text;
  v_format text := p_event->>'format';
  v_kind text := coalesce(p_event->>'kind', 'other');
  v_players integer := nullif(p_event->>'players', '')::integer;
  v_decks integer;
  v_unmatched integer;
begin
  if not exists (select 1 from t1_private.meta_formats where format = v_format) then
    raise exception 'Unknown format %', v_format using errcode = '22023';
  end if;
  if coalesce(p_event->>'source', '') not in ('mtgo', 'topdeck', 'melee') or coalesce(p_event->>'source_id', '') = ''
     or (p_event->>'on') is null then
    raise exception 'An event needs a source, an id and a date' using errcode = '22023';
  end if;
  select * into v_set from t1_private.meta_settings;
  v_tier := t1_private.meta_tier(v_kind, v_players);

  insert into t1_private.meta_events as e (source, source_id, format, name, kind, on_date, players, tier, url, complete)
  values (p_event->>'source', p_event->>'source_id', v_format, coalesce(p_event->>'name', ''), v_kind,
          (p_event->>'on')::date, v_players, v_tier, p_event->>'url', coalesce((p_event->>'complete')::boolean, false))
  on conflict (source, source_id) do update
    set name = excluded.name, kind = excluded.kind, on_date = excluded.on_date, players = excluded.players,
        tier = excluded.tier, url = excluded.url, complete = excluded.complete, ingested_at = now()
  returning id into v_event;
  delete from t1_private.meta_decks where event_id = v_event;

  -- Every card line, resolved once.
  if to_regclass('pg_temp.meta_lines') is null then
    create temporary table meta_lines (n integer, player text, side boolean, name text, qty integer, id uuid) on commit drop;
  else
    truncate meta_lines;
  end if;
  insert into meta_lines
  select d.n, d.v->>'player', s.side, l->>0, (l->>1)::integer, null
    from jsonb_array_elements(coalesce(p_event->'decks', '[]'::jsonb)) with ordinality d(v, n)
    cross join lateral (values (false, d.v->'main'), (true, d.v->'side')) s(side, lines)
    cross join lateral jsonb_array_elements(coalesce(s.lines, '[]'::jsonb)) l
   where coalesce((l->>1)::integer, 0) > 0;
  update meta_lines m set id = c.id
    from (select distinct name, t1_private.meta_card_id(name) id from meta_lines) c where c.name = m.name;

  insert into t1_private.meta_unmatched as u (source, name)
  select distinct p_event->>'source', name from meta_lines where id is null
  on conflict (source, name) do update set seen = u.seen + 1, last_seen = current_date;
  select count(distinct name) into v_unmatched from meta_lines where id is null;

  insert into t1_private.meta_decks (event_id, format, on_date, tier, weight, player, rank, wins, losses, draws, top8,
                                     main, main_qty, side, side_qty)
  select v_event, v_format, (p_event->>'on')::date, v_tier,
         t.weight * case when coalesce((d.v->>'top8')::boolean, false) then v_set.top8_factor else 1 end,
         encode(extensions.digest(v_set.salt || (p_event->>'source') || ':' || coalesce(d.v->>'player', d.n::text), 'sha256'), 'hex'),
         nullif(d.v->>'rank', '')::integer, nullif(d.v->>'wins', '')::integer, nullif(d.v->>'losses', '')::integer,
         nullif(d.v->>'draws', '')::integer, coalesce((d.v->>'top8')::boolean, false),
         coalesce(m.ids, '{}'), coalesce(m.qty, '{}'), coalesce(s.ids, '{}'), coalesce(s.qty, '{}')
    from jsonb_array_elements(coalesce(p_event->'decks', '[]'::jsonb)) with ordinality d(v, n)
    cross join t1_private.meta_tiers t
    left join lateral (select array_agg(id order by id) ids, array_agg(q::smallint order by id) qty
                         from (select id, sum(qty) q from meta_lines where n = d.n and not side and id is not null group by id) x) m on true
    left join lateral (select array_agg(id order by id) ids, array_agg(q::smallint order by id) qty
                         from (select id, sum(qty) q from meta_lines where n = d.n and side and id is not null group by id) x) s on true
   where t.tier = v_tier;
  get diagnostics v_decks = row_count;

  update t1_private.meta_decks set colors = t1_private.meta_colors(main, main_qty) where event_id = v_event;
  update t1_private.meta_decks set archetype_id = t1_private.meta_label(format, main, side, colors) where event_id = v_event;

  insert into t1_private.meta_matches (event_id, round, a, b, a_wins, b_wins, result)
  select distinct on (m->>'round', da.id, db.id) v_event, m->>'round', da.id, db.id,
         nullif(m->>'a_wins', '')::integer, nullif(m->>'b_wins', '')::integer, m->>'result'
    from jsonb_array_elements(coalesce(p_event->'matches', '[]'::jsonb)) m
    join t1_private.meta_decks da on da.event_id = v_event
     and da.player = encode(extensions.digest(v_set.salt || (p_event->>'source') || ':' || (m->>'a'), 'sha256'), 'hex')
    join t1_private.meta_decks db on db.event_id = v_event
     and db.player = encode(extensions.digest(v_set.salt || (p_event->>'source') || ':' || (m->>'b'), 'sha256'), 'hex')
   where m->>'result' in ('a', 'b', 'draw') and da.id <> db.id;

  return jsonb_build_object('event_id', v_event, 'tier', v_tier, 'decks', v_decks, 'unmatched', v_unmatched);
end $$;

create or replace function public.meta_archetype(p_format text, p_archetype integer, p_tier text default 'all', p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_arch jsonb;
  v_days integer := case when p_days in (7, 14, 30, 90) then p_days else 30 end;
  v_out jsonb;
begin
  perform t1_private.meta_require(p_format, p_tier);
  if p_archetype = 0 then
    v_arch := jsonb_build_object('id', 0, 'name', 'Other', 'family', 'midrange', 'colors', '');
  else
    select jsonb_build_object('id', id, 'name', name, 'family', family, 'colors', colors) into v_arch
      from t1_private.meta_archetypes where id = p_archetype and format = p_format and status = 'approved';
  end if;
  if v_arch is null then raise exception 'Unknown archetype' using errcode = '22023'; end if;

  with win as (
    select d.* from t1_private.meta_decks d
     where d.format = p_format and d.on_date > current_date - v_days and t1_private.meta_tier_in(d.tier, p_tier)),
  mine as (select * from win where archetype_id = p_archetype),
  mt as (select coalesce(sum(weight), 0) w, count(*) n from mine),
  wins as (select count(*) n, count(*) filter (where top8) t8 from win d join t1_private.meta_events e on e.id = d.event_id and e.complete),
  mwins as (select count(*) n, count(*) filter (where top8) t8 from mine d join t1_private.meta_events e on e.id = d.event_id and e.complete),
  -- paper events' records (TopDeck, Melee) cover the whole field, so when there are any they're the record; else
  -- MTGO's top 32. The basis keeps the wire value 'topdeck' for paper, which the apps already read.
  recs as (
    select e.source, d.wins, d.losses, d.draws from mine d join t1_private.meta_events e on e.id = d.event_id
     where d.wins is not null and e.kind <> 'league'),
  rec as (
    select sum(wins) w, sum(losses) l, sum(coalesce(draws, 0)) dr, bool_or(source <> 'mtgo') td
      from recs where source <> 'mtgo' or not exists (select 1 from recs where source <> 'mtgo')),
  lines as (
    select s.side, u.id, sum(m.weight) w, sum(m.weight * u.q) wq
      from mine m cross join lateral (values (false, m.main, m.main_qty), (true, m.side, m.side_qty)) s(side, ids, qty)
      cross join lateral unnest(s.ids, s.qty) u(id, q) group by 1, 2),
  rated as (
    select l.side, l.id, o.name, l.w / nullif((select w from mt), 0) rate, l.wq / l.w copies
      from lines l join public.card_oracles o on o.oracle_id = l.id where coalesce(o.type_line, '') !~ '^Basic'),
  weeks as (select g from generate_series(0, 25) g),
  series as (
    select w.g, (select sum(weight) filter (where d.archetype_id = p_archetype) / nullif(sum(weight), 0)
                   from t1_private.meta_decks d
                  where d.format = p_format and t1_private.meta_tier_in(d.tier, p_tier)
                    and d.on_date > current_date - 7 * (26 - w.g) and d.on_date <= current_date - 7 * (25 - w.g)) v
      from weeks w),
  mu as (
    select case when da.archetype_id = p_archetype then db.archetype_id else da.archetype_id end vs,
           count(*) filter (where (mm.result = 'a') = (da.archetype_id = p_archetype) and mm.result <> 'draw') wn,
           count(*) filter (where (mm.result = 'b') = (da.archetype_id = p_archetype) and mm.result <> 'draw') ls,
           count(*) filter (where mm.result = 'draw') dr
      from t1_private.meta_matches mm
      join t1_private.meta_decks da on da.id = mm.a join t1_private.meta_decks db on db.id = mm.b
     where da.format = p_format and da.on_date > current_date - 90
       and (da.archetype_id = p_archetype) <> (db.archetype_id = p_archetype)
     group by 1),
  -- Other (0): its decks by colours, each with its most-played cards and its best list as an example
  grp as (
    select m.colors, count(*) n, sum(m.weight) w from mine m where p_archetype = 0
     group by m.colors order by sum(m.weight) desc, m.colors limit 8),
  gex as (
    select distinct on (m.colors) m.colors, m.id from mine m join grp using (colors)
     order by m.colors, m.weight desc, m.rank nulls last, m.on_date desc),
  gcards as (
    select g.colors, o.name, count(*)::numeric / max(g.n) rate
      from grp g join mine m using (colors) cross join lateral unnest(m.main) u(id)
      join public.card_oracles o on o.oracle_id = u.id
     where coalesce(o.type_line, '') !~ 'Land'
     group by g.colors, o.name),
  fin as (
    select x.*, row_number() over (order by x.weight desc, x.rank nulls last, x.on_date desc, x.id) - 1 pos from (
      select m.*, e.name ev, e.players, e.url from mine m join t1_private.meta_events e on e.id = m.event_id
       where m.id in (select id from (select id from mine order by weight desc, rank nulls last, on_date desc limit 10) t)
          or m.id in (select id from gex)) x)
  select jsonb_build_object(
    'archetype', v_arch,
    'decks', (select n from mt),
    'series', jsonb_build_object('from', (current_date - 7 * 26 + 1)::text, 'weeks', 26,
                                 'v', (select jsonb_agg(round(v, 4) order by g) from series)),
    'record', (select case when w is null then null else jsonb_build_object('wins', w, 'losses', l, 'draws', dr,
                 'basis', case when td then 'topdeck' else 'mtgo_top32' end) end from rec),
    'conv', (select case when wins.t8 > 0 and mwins.n >= 20 then round((mwins.t8::numeric / wins.t8) / (mwins.n::numeric / wins.n), 2) end from wins, mwins),
    'core', coalesce((select jsonb_agg(jsonb_build_object('c', id, 'n', name, 'rate', round(rate, 4), 'copies', round(copies, 2)) order by rate desc, name)
                        from rated where not side and rate >= 0.8), '[]'::jsonb),
    'flex', coalesce((select jsonb_agg(jsonb_build_object('c', id, 'n', name, 'rate', round(rate, 4), 'copies', round(copies, 2)) order by rate desc, name)
                        from (select * from rated where not side and rate >= 0.2 and rate < 0.8 order by rate desc limit 30) f), '[]'::jsonb),
    'side', coalesce((select jsonb_agg(jsonb_build_object('c', id, 'n', name, 'rate', round(rate, 4), 'copies', round(copies, 2)) order by rate desc, name)
                        from (select * from rated where side and rate >= 0.2 order by rate desc limit 30) s), '[]'::jsonb),
    'matchups', coalesce((select jsonb_agg(jsonb_build_object('vs', vs, 'wins', wn, 'losses', ls, 'draws', dr) order by wn + ls + dr desc) from mu), '[]'::jsonb),
    'finishes', coalesce((select jsonb_agg(jsonb_build_object(
        'event', f.ev, 'on', f.on_date::text, 'players', f.players, 'tier', f.tier, 'rank', f.rank, 'url', f.url,
        'main', (select jsonb_agg(jsonb_build_array(o.name, u.q) order by coalesce(o.type_line, '') ~ 'Land', o.cmc, o.name) from unnest(f.main, f.main_qty) u(id, q)
                   join public.card_oracles o on o.oracle_id = u.id),
        'side', coalesce((select jsonb_agg(jsonb_build_array(o.name, u.q) order by coalesce(o.type_line, '') ~ 'Land', o.cmc, o.name) from unnest(f.side, f.side_qty) u(id, q)
                   join public.card_oracles o on o.oracle_id = u.id), '[]'::jsonb))
        order by f.pos) from fin f), '[]'::jsonb),
    'groups', coalesce((select jsonb_agg(jsonb_build_object(
        'colors', g.colors, 'decks', g.n, 'share', round(g.w / nullif((select w from mt), 0), 4),
        'cards', (select coalesce(jsonb_agg(c.name order by c.rate desc, c.name), '[]'::jsonb) from (
                    select name, rate from gcards where gcards.colors = g.colors order by rate desc, name limit 4) c),
        'example', (select f.pos from fin f join gex on gex.id = f.id where gex.colors = g.colors))
        order by g.w desc, g.colors) from grp g), '[]'::jsonb),
    'brief', (select brief from t1_private.insight_briefs where view = 'arch:' || p_format || ':' || p_archetype))
  into v_out;
  return v_out;
end $$;

create or replace function t1_private.spice_refresh(p_today date default current_date)
returns integer language plpgsql security definer set search_path = '' as $$
declare f text; v_rows integer := 0; v_n integer;
begin
  for f in select distinct dk.format from t1_private.meta_decks dk where dk.on_date > p_today - 365 loop
    delete from t1_private.spice_lists where format = f;
    delete from t1_private.spice_counts where format = f;
    insert into t1_private.spice_lists (format, archetype_id, days, n, mtgo, topdeck, melee, built_on)
    select f, x.a, w.days, count(*), count(*) filter (where e.source = 'mtgo'), count(*) filter (where e.source = 'topdeck'),
           count(*) filter (where e.source = 'melee'),
           p_today
      from t1_private.meta_decks dk join t1_private.meta_events e on e.id = dk.event_id
      cross join (values (90), (365)) w(days)
      cross join lateral (values (dk.archetype_id), (-1)) x(a)
     where dk.format = f and dk.on_date > p_today - w.days
     group by x.a, w.days;
    insert into t1_private.spice_counts (format, archetype_id, days, card, main, side)
    select f, x.a, w.days, c.card, sum(c.m), sum(c.s)
      from t1_private.meta_decks dk
      cross join (values (90), (365)) w(days)
      cross join lateral (values (dk.archetype_id), (-1)) x(a)
      cross join lateral (select u, 1, 0 from unnest(dk.main) u union all select u, 0, 1 from unnest(dk.side) u) c(card, m, s)
     where dk.format = f and dk.on_date > p_today - w.days
     group by x.a, w.days, c.card;
    get diagnostics v_n = row_count;
    v_rows := v_rows + v_n;
  end loop;
  delete from t1_private.spice_lists l where l.built_on < p_today;
  delete from t1_private.spice_counts c
   where not exists (select 1 from t1_private.spice_lists l where l.format = c.format);
  return v_rows;
end $$;

create or replace function t1_private.spice_deck(
  p_format text, p_label integer, p_main uuid[], p_main_qty integer[], p_side uuid[], p_side_qty integer[],
  p_today date default current_date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_all uuid[];
  v_key text;
  v_ids uuid[];
  v_qty integer[];
  v_sids uuid[];
  v_sqty integer[];
  v_total integer;
  t record;
  v_year integer;
  v_kind text;
  v_arch integer;
  v_key_a integer;
  v_days integer;
  v_n integer;
  v_kq bigint;
  v_tw integer;
  v_num bigint;
  v_snum numeric;
  v_score integer;
  v_cards jsonb;
  v_missing jsonb;
  v_sources jsonb;
  d integer;
begin
  select coalesce(array_agg(c order by c), '{}'), coalesce(string_agg(c::text || ':' || q, ',' order by c), '')
    into v_all, v_key
    from (select u.c, sum(u.q)::int q from unnest(coalesce(p_main, '{}'), coalesce(p_main_qty, '{}')) u(c, q)
           where u.c is not null group by u.c) f;
  select coalesce(array_agg(f.c order by f.c), '{}'), coalesce(array_agg(f.q order by f.c), '{}')
    into v_ids, v_qty
    from (select u.c, sum(u.q)::int q from unnest(coalesce(p_main, '{}'), coalesce(p_main_qty, '{}')) u(c, q)
           where u.c is not null group by u.c) f
   where not t1_private.meta_is_basic(f.c);
  select coalesce(array_agg(f.c order by f.c), '{}'), coalesce(array_agg(f.q order by f.c), '{}')
    into v_sids, v_sqty
    from (select u.c, sum(u.q)::int q from unnest(coalesce(p_side, '{}'), coalesce(p_side_qty, '{}')) u(c, q)
           where u.c is not null group by u.c) f
   where not t1_private.meta_is_basic(f.c);
  select coalesce(sum(q), 0) into v_total from unnest(v_qty) q;
  if v_total = 0 then return t1_private.spice_none('deck', 'empty'); end if;

  select dk.id, dk.on_date, dk.archetype_id, dk.main, dk.side, dk.colors, e.source into t
    from t1_private.meta_decks dk join t1_private.meta_events e on e.id = dk.event_id
   where dk.format = p_format and dk.on_date > p_today - 365 and dk.main @> v_all and dk.main <@ v_all
     and (select string_agg(f.c::text || ':' || f.q, ',' order by f.c)
            from (select u.c, sum(u.q)::int q from unnest(dk.main, dk.main_qty) u(c, q) group by u.c) f) = v_key
   order by dk.on_date desc, dk.id desc limit 1;

  select l.n - (t.id is not null)::int into v_year from t1_private.spice_lists l
   where l.format = p_format and l.days = 365 and l.archetype_id = -1;
  if coalesce(v_year, 0) < 30 then return t1_private.spice_none('deck', 'no_data'); end if;

  -- Singleton formats: each card against the year's lists that can play it (few lists: read them directly).
  if p_format = 'canlander' then
    with pool as (select dk.main, dk.side, dk.colors, dk.event_id from t1_private.meta_decks dk
                   where dk.format = p_format and dk.on_date > p_today - 365 and dk.id is distinct from t.id),
         mine as (select 'main' section, q.c, q.q from unnest(v_ids, v_qty) q(c, q)
                  union all select 'side', q.c, q.q from unnest(v_sids, v_sqty) q(c, q)),
         rated as (select m.section, m.c, m.q, o.name,
                          (select count(*) from pool p where t1_private.spice_fits(o.color_identity, p.colors))::int of_n,
                          (select count(*) from pool p where t1_private.spice_fits(o.color_identity, p.colors)
                              and m.c = any(case when m.section = 'main' then p.main else p.side end))::int k
                     from mine m join public.card_oracles o on o.oracle_id = m.c)
    select (select sum(r.q * case when r.of_n = 0 then 1 else greatest(0, r.of_n - 10 * r.k)::numeric / r.of_n end)
              from rated r where r.section = 'main'),
           (select coalesce(jsonb_agg(jsonb_build_object('c', r.c, 'n', r.name, 'section', r.section, 'copies', r.q,
                      'rate', case when r.of_n = 0 then 0 else round(r.k::numeric / r.of_n, 4) end, 'seen', r.k, 'of', r.of_n)
                      order by r.section <> 'main', r.k, r.q desc, r.name collate "C"), '[]')
              from rated r where r.of_n = 0 or 10 * r.k < r.of_n),
           (select coalesce(jsonb_agg(s order by s), '[]') from (select distinct e.source s from pool p
              join t1_private.meta_events e on e.id = p.event_id) z)
      into v_snum, v_cards, v_sources;
    v_score := floor(100 * v_snum / v_total + 0.5)::int;
    return jsonb_build_object('kind', 'deck', 'score', v_score, 'word', t1_private.spice_word(v_score), 'reason', null,
      'basis', jsonb_build_object('kind', 'colors', 'format', p_format, 'archetype', null, 'name', null, 'lists', v_year,
                                  'days', 365, 'sources', v_sources, 'close', null, 'cubes', null),
      'cards', v_cards, 'stock_missing', '[]'::jsonb);
  end if;

  -- 1. The deck's archetype with 30+ lists: last 90 days, then the year.
  if coalesce(p_label, 0) <> 0 then
    foreach d in array array[90, 365] loop
      select l.n - (t.id is not null and t.on_date > p_today - d and t.archetype_id = p_label)::int into v_n
        from t1_private.spice_lists l where l.format = p_format and l.days = d and l.archetype_id = p_label;
      if coalesce(v_n, 0) >= 30 then v_kind := 'archetype'; v_arch := p_label; v_days := d; exit; end if;
    end loop;
  end if;

  -- 2. The closest archetype: the most copies × main-deck rate, if it plays at least a quarter of the deck.
  if v_kind is null then
    foreach d in array array[90, 365] loop
      with n as (select l.archetype_id a,
                        l.n - (t.id is not null and t.on_date > p_today - d and t.archetype_id = l.archetype_id)::int n
                   from t1_private.spice_lists l where l.format = p_format and l.days = d and l.archetype_id > 0),
           n30 as (select * from n where n.n >= 30),
           s as (select c.archetype_id a, sum(q.q::bigint * (c.main - (t.id is not null and t.on_date > p_today - d
                          and t.archetype_id = c.archetype_id and c.card = any(t.main))::int)) kq
                   from t1_private.spice_counts c join unnest(v_ids, v_qty) q(c, q) on q.c = c.card
                  where c.format = p_format and c.days = d and c.archetype_id in (select n30.a from n30)
                  group by 1)
      select n30.a, n30.n, coalesce(s.kq, 0) into v_arch, v_n, v_kq from n30 left join s on s.a = n30.a
       order by coalesce(s.kq, 0)::numeric / n30.n desc, n30.n desc, n30.a limit 1;
      if v_arch is not null then
        if 4 * v_kq >= v_n::bigint * v_total then v_kind := 'closest'; v_days := d; else v_arch := null; end if;
        exit;
      end if;
    end loop;
  end if;

  -- 3. The whole format: last 90 days, else the year.
  if v_kind is null then
    v_kind := 'format';
    select l.n - (t.id is not null and t.on_date > p_today - 90)::int into v_n
      from t1_private.spice_lists l where l.format = p_format and l.days = 90 and l.archetype_id = -1;
    if coalesce(v_n, 0) >= 30 then v_days := 90; else v_days := 365; v_n := v_year; end if;
  end if;

  v_key_a := coalesce(v_arch, -1);
  v_tw := (t.id is not null and t.on_date > p_today - v_days and (v_key_a = -1 or t.archetype_id = v_key_a))::int;
  with mine as (select 'main' section, q.c, q.q,
                       coalesce(c.main, 0) - (v_tw = 1 and q.c = any(t.main))::int k
                  from unnest(v_ids, v_qty) q(c, q)
                  left join t1_private.spice_counts c
                    on c.format = p_format and c.days = v_days and c.archetype_id = v_key_a and c.card = q.c
                union all
                select 'side', q.c, q.q, coalesce(c.side, 0) - (v_tw = 1 and q.c = any(t.side))::int
                  from unnest(v_sids, v_sqty) q(c, q)
                  left join t1_private.spice_counts c
                    on c.format = p_format and c.days = v_days and c.archetype_id = v_key_a and c.card = q.c),
       -- Stock cards you don't play: only against an archetype (the whole format's staples say nothing).
       miss as (select x.card c, x.k, o.name
                  from (select c.card, c.main - (v_tw = 1 and c.card = any(t.main))::int k from t1_private.spice_counts c
                         where c.format = p_format and c.days = v_days and c.archetype_id = v_key_a
                           and v_kind <> 'format' and not (c.card = any(v_ids))) x
                  join public.card_oracles o on o.oracle_id = x.card
                 where 2 * x.k >= v_n and coalesce(o.type_line, '') !~ '^Basic'
                 order by x.k desc, o.name collate "C" limit 12)
  select (select sum(m.q::bigint * greatest(0, v_n - 4 * m.k)) from mine m where m.section = 'main'),
         (select coalesce(jsonb_agg(jsonb_build_object('c', m.c, 'n', o.name, 'section', m.section, 'copies', m.q,
                    'rate', round(m.k::numeric / v_n, 4), 'seen', m.k, 'of', v_n)
                    order by m.section <> 'main', m.k, m.q desc, o.name collate "C"), '[]')
            from mine m join public.card_oracles o on o.oracle_id = m.c where 4 * m.k < v_n),
         (select coalesce(jsonb_agg(jsonb_build_object('c', x.c, 'n', x.name, 'rate', round(x.k::numeric / v_n, 4),
                    'seen', x.k, 'of', v_n) order by x.k desc, x.name collate "C"), '[]') from miss x),
         (select to_jsonb(array_remove(array[
                   case when l.mtgo - (v_tw = 1 and t.source = 'mtgo')::int > 0 then 'mtgo' end,
                   case when l.topdeck - (v_tw = 1 and t.source = 'topdeck')::int > 0 then 'topdeck' end,
                   case when l.melee - (v_tw = 1 and t.source = 'melee')::int > 0 then 'melee' end], null))
            from t1_private.spice_lists l where l.format = p_format and l.days = v_days and l.archetype_id = v_key_a)
    into v_num, v_cards, v_missing, v_sources;
  -- Exact: 100 × Σ copies × max(0, n − 4k) / (n × copies), half up.
  v_score := ((200 * v_num + v_n::bigint * v_total) / (2 * v_n::bigint * v_total))::int;
  return jsonb_build_object('kind', 'deck', 'score', v_score, 'word', t1_private.spice_word(v_score), 'reason', null,
    'basis', jsonb_build_object('kind', v_kind, 'format', p_format, 'archetype', v_arch,
                                'name', (select a.name from t1_private.meta_archetypes a where a.id = v_arch),
                                'lists', v_n, 'days', v_days, 'sources', coalesce(v_sources, '[]'::jsonb),
                                'close', null, 'cubes', null),
    'cards', v_cards, 'stock_missing', v_missing);
end $$;
