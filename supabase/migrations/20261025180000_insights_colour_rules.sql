-- Archetype rules can require a deck's exact colours ({"colors": "WUB"}), alone or with cards: singleton formats
-- (Canadian Highlander) share few cards between lists, and their players name decks by colours and plan. Colours are
-- the deck's own (t1_private.meta_colors: a colour counts with 4+ nonland cards of it), WUBRG order. meta_label takes
-- them, so meta_ingest sets colours before labelling and meta_relabel passes them.

alter table t1_private.meta_archetypes add column if not exists r_colors text;

-- As in 20261025120000_insights.sql, also compiling colors into r_colors.
create or replace function t1_private.meta_rule_compile(p_id integer)
returns void language plpgsql security definer set search_path = '' as $$
declare r jsonb; v_missing text[]; v_blocked boolean;
begin
  select rule into r from t1_private.meta_archetypes where id = p_id;
  if r is null then return; end if;
  select coalesce(array_agg(distinct x), '{}') into v_missing
    from (select jsonb_array_elements_text(coalesce(r->'main', '[]')) x
          union all select jsonb_array_elements_text(coalesce(r->'deck', '[]'))
          union all select jsonb_array_elements_text(coalesce(r->'not', '[]'))
          union all select jsonb_array_elements_text(g) from jsonb_array_elements(coalesce(r->'any', '[]')) g) n
   where t1_private.meta_card_id(x) is null;
  select exists (select 1 from (select jsonb_array_elements_text(coalesce(r->'main', '[]')) x
                                union all select jsonb_array_elements_text(coalesce(r->'deck', '[]'))) n
                  where t1_private.meta_card_id(x) is null) into v_blocked;
  update t1_private.meta_archetypes set
    r_main = t1_private.meta_ids(r->'main'),
    r_deck = t1_private.meta_ids(r->'deck'),
    r_not = t1_private.meta_ids(r->'not'),
    r_any1 = case when jsonb_array_length(coalesce(r->'any', '[]')) >= 1 then t1_private.meta_ids(r->'any'->0) end,
    r_any2 = case when jsonb_array_length(coalesce(r->'any', '[]')) >= 2 then t1_private.meta_ids(r->'any'->1) end,
    r_any3 = case when jsonb_array_length(coalesce(r->'any', '[]')) >= 3 then t1_private.meta_ids(r->'any'->2) end,
    r_colors = nullif(r->>'colors', ''),
    missing = v_missing, blocked = v_blocked, updated_at = now()
   where id = p_id;
end $$;

drop function if exists t1_private.meta_label(text, uuid[], uuid[]);
-- The first approved archetype (by priority) whose rule a deck meets; 0 = Other. A blocked rule never matches; a rule
-- with colours matches only decks of exactly those colours.
create or replace function t1_private.meta_label(p_format text, p_main uuid[], p_side uuid[], p_colors text default null)
returns integer language sql stable set search_path = '' as $$
  select coalesce((
    select a.id from t1_private.meta_archetypes a
     where a.format = p_format and a.status = 'approved' and not a.blocked
       and ((cardinality(a.r_main) + cardinality(a.r_deck) + coalesce(cardinality(a.r_any1), 0)) > 0 or a.r_colors is not null)
       and (a.r_colors is null or a.r_colors = p_colors)
       and a.r_main <@ p_main
       and a.r_deck <@ (p_main || p_side)
       and (a.r_any1 is null or a.r_any1 && (p_main || p_side))
       and (a.r_any2 is null or a.r_any2 && (p_main || p_side))
       and (a.r_any3 is null or a.r_any3 && (p_main || p_side))
       and not (a.r_not && (p_main || p_side))
     order by a.priority, a.id limit 1), 0);
$$;

-- As in 20261025120000_insights.sql, labelling with the deck's colours.
create or replace function public.meta_relabel(p_format text, p_other_only boolean default false)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform t1_private.meta_rule_compile(id) from t1_private.meta_archetypes where format = p_format and status = 'approved';
  update t1_private.meta_decks d set archetype_id = l.a
    from (select id, t1_private.meta_label(format, main, side, colors) a from t1_private.meta_decks
           where format = p_format and (not p_other_only or archetype_id = 0)) l
   where d.id = l.id and d.archetype_id is distinct from l.a;
  get diagnostics n = row_count;
  return n;
end $$;

-- As in 20261025120000_insights.sql, with colours set before the label.
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
  if coalesce(p_event->>'source', '') not in ('mtgo', 'topdeck') or coalesce(p_event->>'source_id', '') = ''
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
