-- Spice: how far a deck or cube is from its peers (contract/spice-2026-10-28.md, plan
-- table-1-context/docs/plan-spiciness-2026-10-28.md). Decks compare with Insights' tournament lists; cubes with
-- t1_private.cube_corpus, which stays empty until Cube Cobra allows reading its public cubes. The reference is
-- testdata/spice/make_cases.py; supabase/tests/66_spice_test.sql checks these functions against its cases.

-- ==================================================================== a_tables
-- Comparison cubes. cards: the distinct non-basic Oracle ids of the cube's main section.
create table if not exists t1_private.cube_corpus (
  id bigserial primary key,
  source text not null default 'cubecobra' check (source in ('cubecobra', 'table1')),
  source_id text not null,
  name text not null,
  cards uuid[] not null,
  fetched_at timestamptz not null default now(),
  unique (source, source_id)
);
create index if not exists cube_corpus_cards_idx on t1_private.cube_corpus using gin (cards);

-- One answer per list, good for the list's seq on that day.
create table if not exists t1_private.list_spice (
  list_id uuid primary key references public.card_lists(id) on delete cascade,
  seq bigint not null,
  on_day date not null,
  result jsonb not null,
  computed_at timestamptz not null default now()
);

-- ==================================================================== b_helpers
create or replace function t1_private.spice_word(p_score integer)
returns text language sql immutable as $$
  select case when p_score is null then null when p_score < 10 then 'stock' when p_score < 25 then 'tuned'
              when p_score < 50 then 'spicy' else 'brew' end;
$$;

create or replace function t1_private.spice_none(p_kind text, p_reason text)
returns jsonb language sql immutable as $$
  select jsonb_build_object('kind', p_kind, 'score', null, 'word', null, 'reason', p_reason, 'basis', null,
                            'cards', '[]'::jsonb, 'stock_missing', '[]'::jsonb);
$$;

-- A card of this colour identity fits a list of these colours (WUBRG letters; colourless fits every list).
create or replace function t1_private.spice_fits(p_identity text[], p_colors text)
returns boolean language sql immutable as $$
  select not exists (select 1 from unnest(coalesce(p_identity, '{}')) x where position(x in coalesce(p_colors, '')) = 0);
$$;

-- ==================================================================== c_decks
-- How many of each format's lists play each card, per archetype (-1 = the whole format) and window, rebuilt once a
-- day (pg_cron t1-spice-counts) so a deck's spice is a handful of index reads. Counts are per list, not per copy.
create table if not exists t1_private.spice_lists (
  format text not null,
  archetype_id integer not null,
  days smallint not null,
  n integer not null,
  mtgo integer not null,
  topdeck integer not null,
  built_on date not null,
  primary key (format, days, archetype_id)
);
create table if not exists t1_private.spice_counts (
  format text not null,
  archetype_id integer not null,
  days smallint not null,
  card uuid not null,
  main integer not null,
  side integer not null,
  primary key (format, days, archetype_id, card)
);

create or replace function t1_private.spice_refresh(p_today date default current_date)
returns integer language plpgsql security definer set search_path = '' as $$
declare f text; v_rows integer := 0; v_n integer;
begin
  for f in select distinct dk.format from t1_private.meta_decks dk where dk.on_date > p_today - 365 loop
    delete from t1_private.spice_lists where format = f;
    delete from t1_private.spice_counts where format = f;
    insert into t1_private.spice_lists (format, archetype_id, days, n, mtgo, topdeck, built_on)
    select f, x.a, w.days, count(*), count(*) filter (where e.source = 'mtgo'), count(*) filter (where e.source = 'topdeck'),
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

-- p_main is the main deck and commander, p_side the sideboard (Oracle ids with copies, repeats summed). p_label is
-- the deck's archetype by Insights' rules (0 = Other). Peers, in order: the archetype, the closest archetype, the
-- format; singleton formats compare each card with the lists whose colours can play it. Reads spice_counts (built
-- for p_today by spice_refresh), less the twin: the year's newest list identical to the main deck, the one a copied
-- deck most likely came from.
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
                   case when l.topdeck - (v_tw = 1 and t.source = 'topdeck')::int > 0 then 'topdeck' end], null))
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

-- ==================================================================== d_cubes
-- A cube's main section against its 20 nearest comparison cubes (Jaccard over non-basic Oracle ids, each weighted
-- by its overlap). One identical cube is left out.
create or replace function t1_private.spice_cube(p_cards uuid[], p_qty integer[])
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_ids uuid[];
  v_qty integer[];
  v_total integer;
  v_twin bigint;
  v_sims integer;
  v_snum numeric;
  v_score integer;
  v_close boolean;
  v_peers integer;
  v_cards jsonb;
  v_missing jsonb;
  v_cubes jsonb;
begin
  select coalesce(array_agg(f.c order by f.c), '{}'), coalesce(array_agg(f.q order by f.c), '{}')
    into v_ids, v_qty
    from (select u.c, sum(u.q)::int q from unnest(coalesce(p_cards, '{}'), coalesce(p_qty, '{}')) u(c, q)
           where u.c is not null group by u.c) f
   where not t1_private.meta_is_basic(f.c);
  select coalesce(sum(q), 0) into v_total from unnest(v_qty) q;
  if v_total = 0 then return t1_private.spice_none('cube', 'empty'); end if;

  select k.id into v_twin from t1_private.cube_corpus k
   where k.cards @> v_ids and k.cards <@ v_ids order by k.id limit 1;
  select count(*) into v_sims from t1_private.cube_corpus k where k.cards && v_ids and k.id is distinct from v_twin;
  if v_sims < 5 then return t1_private.spice_none('cube', 'no_cubes'); end if;

  with sims as (select k.id, k.source_id, k.name, k.cards, i.inter,
                       cardinality(v_ids) + cardinality(k.cards) - i.inter uni
                  from t1_private.cube_corpus k
                  cross join lateral (select count(*)::int inter from unnest(k.cards) x where x = any(v_ids)) i
                 where k.cards && v_ids and k.id is distinct from v_twin),
       peers as (select s.*, s.inter::numeric / s.uni w, row_number() over (order by s.inter::numeric / s.uni desc,
                        s.source_id collate "C") rn
                   from sims s order by s.inter::numeric / s.uni desc, s.source_id collate "C" limit 20),
       tot as (select sum(p.w) wsum, count(*)::int n from peers p),
       rates as (select x.c, sum(p.w) / (select wsum from tot) r, count(*)::int seen
                   from peers p cross join lateral unnest(p.cards) x(c) group by x.c),
       mine as (select q.c, q.q, coalesce(r.r, 0) r, coalesce(r.seen, 0) seen
                  from unnest(v_ids, v_qty) q(c, q) left join rates r on r.c = q.c)
  select (select sum(m.q * greatest(0, 1 - 4 * m.r)) from mine m),
         (select coalesce(jsonb_agg(jsonb_build_object('c', m.c, 'n', o.name, 'section', 'main', 'copies', m.q,
                    'rate', round(m.r, 4), 'seen', m.seen, 'of', (select n from tot))
                    order by round(m.r, 4), m.q desc, o.name collate "C"), '[]')
            from mine m join public.card_oracles o on o.oracle_id = m.c where 4 * m.r < 1),
         (select coalesce(jsonb_agg(jsonb_build_object('c', x.c, 'n', x.name, 'rate', x.rate, 'seen', x.seen, 'of', x.of_n)
                    order by x.rate desc, x.name collate "C"), '[]')
            from (select r.c, o.name, round(r.r, 4) rate, r.seen, (select n from tot) of_n
                    from rates r join public.card_oracles o on o.oracle_id = r.c
                   where 2 * r.r >= 1 and not (r.c = any(v_ids)) and coalesce(o.type_line, '') !~ '^Basic'
                   order by round(r.r, 4) desc, o.name collate "C" limit 12) x),
         (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'overlap', round(p.w, 4)) order by p.rn), '[]')
            from peers p where p.rn <= 5),
         (select 100 * p.inter >= 15 * p.uni from peers p where p.rn = 1),
         (select n from tot)
    into v_snum, v_cards, v_missing, v_cubes, v_close, v_peers;
  v_score := floor(100 * v_snum / v_total + 0.5)::int;
  return jsonb_build_object('kind', 'cube', 'score', v_score, 'word', t1_private.spice_word(v_score), 'reason', null,
    'basis', jsonb_build_object('kind', 'cubes', 'format', null, 'archetype', null, 'name', null, 'lists', v_peers,
                                'days', null, 'sources', '["cubecobra"]'::jsonb, 'close', v_close, 'cubes', v_cubes),
    'cards', v_cards, 'stock_missing', v_missing);
end $$;

-- ==================================================================== e_rpc
-- The owner, anyone the list is shared with (blocks win), or a live link's holder. Cached per list seq and day.
create or replace function public.list_spice(p_list_id uuid, p_token text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  l public.card_lists;
  k public.share_links;
  s public.share_settings;
  v_ok boolean := false;
  v_main uuid[];
  v_mqty integer[];
  v_side uuid[];
  v_sqty integer[];
  v_label integer;
  r jsonb;
begin
  select * into l from public.card_lists cl where cl.id = p_list_id and cl.deleted_at is null;
  if l.id is not null then
    if p_token is not null then
      k := t1_private.share_link_open(p_token);
      v_ok := k.item_id = l.id and k.part = l.kind;
    elsif v_uid is not null then
      if l.user_id = v_uid then
        v_ok := true;
      elsif exists (select 1 from public.profiles pr where pr.id = l.user_id and pr.deleted_at is null and not pr.is_demo) then
        s := t1_private.share_of(l.user_id);
        v_ok := t1_private.vis_ok(t1_private.share_level(l.user_id, v_uid), s.profile,
                                  coalesce(l.visibility, case l.kind when 'cube' then s.cubes else s.decks end, s.library));
      end if;
    end if;
  end if;
  if not coalesce(v_ok, false) then raise exception 'That''s private' using errcode = '42501'; end if;

  select c.result into r from t1_private.list_spice c
   where c.list_id = l.id and c.seq = l.seq and c.on_day = current_date;
  if r is not null then return r; end if;

  select coalesce(array_agg(o.oracle_id) filter (where e.board in ('main', 'commander')), '{}'),
         coalesce(array_agg(e.qty) filter (where e.board in ('main', 'commander')), '{}'),
         coalesce(array_agg(o.oracle_id) filter (where e.board = 'side'), '{}'),
         coalesce(array_agg(e.qty) filter (where e.board = 'side'), '{}')
    into v_main, v_mqty, v_side, v_sqty
    from public.card_list_entries e join public.cards o on o.id = e.card_id
   where e.list_id = l.id;

  if l.kind = 'cube' then
    r := t1_private.spice_cube(v_main, v_mqty);
  else
    v_label := t1_private.meta_label(l.format, v_main, v_side,
                 t1_private.meta_colors(v_main, v_mqty::smallint[]));
    r := t1_private.spice_deck(l.format, v_label, v_main, v_mqty, v_side, v_sqty);
  end if;

  insert into t1_private.list_spice (list_id, seq, on_day, result) values (l.id, l.seq, current_date, r)
  on conflict (list_id) do update set seq = excluded.seq, on_day = excluded.on_day, result = excluded.result,
                                      computed_at = now();
  return r;
end $$;

-- ==================================================================== f_grants
revoke all on t1_private.cube_corpus, t1_private.list_spice, t1_private.spice_lists, t1_private.spice_counts
  from public, anon, authenticated;
revoke execute on function t1_private.spice_refresh(date) from public;
revoke execute on function t1_private.spice_word(integer) from public;
revoke execute on function t1_private.spice_none(text, text) from public;
revoke execute on function t1_private.spice_fits(text[], text) from public;
revoke execute on function t1_private.spice_deck(text, integer, uuid[], integer[], uuid[], integer[], date) from public;
revoke execute on function t1_private.spice_cube(uuid[], integer[]) from public;
revoke execute on function public.list_spice(uuid, text) from public;
grant execute on function public.list_spice(uuid, text) to anon, authenticated;

-- ==================================================================== g_cron
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-spice-counts') then
      perform cron.schedule('t1-spice-counts', '40 4 * * *', 'select t1_private.spice_refresh()');
    end if;
  end if;
end $$;
-- Counts for today, so spice works as soon as this is applied.
select t1_private.spice_refresh();
