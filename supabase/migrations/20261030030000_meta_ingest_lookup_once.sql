-- 20261030020000 meant to look each card name up once, but the planner flattens the distinct-names subquery into the
-- UPDATE and runs t1_private.meta_card_id once per card line: 45,000 lookups (8.3 s on live) for a 1,500-player
-- event, which still hit the 8 s statement timeout. A materialized CTE looks each name up once (0.44 s).
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
  v_players_map jsonb;
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
  with c as materialized (select name, t1_private.meta_card_id(name) id from (select distinct name from meta_lines) n)
  update meta_lines m set id = c.id from c where c.name = m.name;

  insert into t1_private.meta_unmatched as u (source, name)
  select distinct p_event->>'source', name from meta_lines where id is null
  on conflict (source, name) do update set seen = u.seen + 1, last_seen = current_date;
  select count(distinct name) into v_unmatched from meta_lines where id is null;

  insert into t1_private.meta_decks (event_id, format, on_date, tier, weight, player, rank, wins, losses, draws, top8,
                                     main, main_qty, side, side_qty)
  with lines as (
    select n, side, array_agg(id order by id) ids, array_agg(q::smallint order by id) qty
      from (select n, side, id, sum(qty) q from meta_lines where id is not null group by n, side, id) x
     group by n, side)
  select v_event, v_format, (p_event->>'on')::date, v_tier,
         t.weight * case when coalesce((d.v->>'top8')::boolean, false) then v_set.top8_factor else 1 end,
         encode(extensions.digest(v_set.salt || (p_event->>'source') || ':' || coalesce(d.v->>'player', d.n::text), 'sha256'), 'hex'),
         nullif(d.v->>'rank', '')::integer, nullif(d.v->>'wins', '')::integer, nullif(d.v->>'losses', '')::integer,
         nullif(d.v->>'draws', '')::integer, coalesce((d.v->>'top8')::boolean, false),
         coalesce(m.ids, '{}'), coalesce(m.qty, '{}'), coalesce(s.ids, '{}'), coalesce(s.qty, '{}')
    from jsonb_array_elements(coalesce(p_event->'decks', '[]'::jsonb)) with ordinality d(v, n)
    cross join t1_private.meta_tiers t
    left join lines m on m.n = d.n and not m.side
    left join lines s on s.n = d.n and s.side
   where t.tier = v_tier;
  get diagnostics v_decks = row_count;

  update t1_private.meta_decks set colors = t1_private.meta_colors(main, main_qty) where event_id = v_event;
  update t1_private.meta_decks set archetype_id = t1_private.meta_label(format, main, side, colors) where event_id = v_event;

  select jsonb_object_agg(player, id) into v_players_map from t1_private.meta_decks where event_id = v_event;
  insert into t1_private.meta_matches (event_id, round, a, b, a_wins, b_wins, result)
  select distinct on (m.round, m.a, m.b) v_event, m.round, m.a, m.b, m.a_wins, m.b_wins, m.result
    from (select m->>'round' round, m->>'result' result,
                 nullif(m->>'a_wins', '')::integer a_wins, nullif(m->>'b_wins', '')::integer b_wins,
                 (v_players_map->>encode(extensions.digest(v_set.salt || (p_event->>'source') || ':' || (m->>'a'), 'sha256'), 'hex'))::bigint a,
                 (v_players_map->>encode(extensions.digest(v_set.salt || (p_event->>'source') || ':' || (m->>'b'), 'sha256'), 'hex'))::bigint b
            from jsonb_array_elements(coalesce(p_event->'matches', '[]'::jsonb)) m
           where m->>'result' in ('a', 'b', 'draw')) m
   where m.a is not null and m.b is not null and m.a <> m.b;

  return jsonb_build_object('event_id', v_event, 'tier', v_tier, 'decks', v_decks, 'unmatched', v_unmatched);
end $$;
