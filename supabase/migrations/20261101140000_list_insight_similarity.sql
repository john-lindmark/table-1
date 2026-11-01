-- A deck's archetype on its own screen says how close the deck is, and stays away from brews (John, 2026-11-01: "not
-- all decks are going to match meta decks exactly and sometimes it looks weird to reference insights for another
-- deck. Maybe don't show insights for brews"). Contract: contract/insights-2026-10-24.md § A deck's archetype.
--
-- similarity: the deck against its archetype's 10 nearest lists (fewer when it has fewer), the mean of Σ min(copies)
--   ÷ the larger of the two decks' copies, over non-basic main and commander cards (basics never count, as in Spice
--   and Missing). Ten, not the nearest one: on live a Selesnya deck read 100% Jeskai Energy off one odd list with that
--   label. The archetype's lists of the last 90 days (all tiers), else the year; null when the deck has no non-basic
--   card or the archetype no list. Worked out per call (the archetype's records stay kept per archetype and day).
-- brew: a deck Spice calls a Brew (score 50+, list_spice, which keeps its own answer per list seq and day) gets
--   {format, a: null, reason: 'brew', archetype, similarity}, so builds from before this hide the rows too.

create or replace function t1_private.meta_similarity(p_format text, p_archetype integer, p_main uuid[], p_qty integer[])
returns numeric language plpgsql stable security definer set search_path = '' as $$
declare
  v_basic uuid[];
  v_ids uuid[];
  v_qty integer[];
  v_total integer;
  v_days integer;
  v_best numeric;
begin
  select coalesce(array_agg(o.oracle_id), '{}') into v_basic
    from public.card_oracles o where o.type_line like 'Basic%';
  select coalesce(array_agg(f.c), '{}'), coalesce(array_agg(f.q), '{}'), coalesce(sum(f.q), 0)
    into v_ids, v_qty, v_total
    from (select u.c, sum(u.q)::int q from unnest(coalesce(p_main, '{}'), coalesce(p_qty, '{}')) u(c, q)
           where u.c is not null and u.q > 0 and u.c <> all(v_basic) group by u.c) f;
  if v_total = 0 then return null; end if;

  foreach v_days in array array[90, 365] loop
    with me as materialized (select * from unnest(v_ids, v_qty) m(c, q)),
    lists as (
      select d.id, d.main, d.main_qty from t1_private.meta_decks d
       where d.format = p_format and d.archetype_id = p_archetype
         and d.on_date > current_date - v_days and d.on_date <= current_date)
    select avg(n.v) into v_best
      from (select x.shared::numeric / greatest(v_total, x.total) v
              from lists l
              cross join lateral (
                select coalesce(sum(least(u.q, coalesce(me.q, 0))), 0) shared, coalesce(sum(u.q), 0) total
                  from unnest(l.main, l.main_qty) u(c, q) left join me on me.c = u.c
                 where u.c <> all(v_basic)) x
             order by 1 desc limit 10) n;
    if v_best is not null then return round(v_best, 3); end if;
  end loop;
  return null;
end $$;

create or replace function public.list_insight(p_list_id uuid, p_token text default null)
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
  v_a integer;
  v_name text;
  v_sim numeric;
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

  if l.kind <> 'deck' or not exists (select 1 from t1_private.meta_formats f where f.format = l.format) then
    return jsonb_build_object('format', l.format, 'a', null, 'reason', 'no_format');
  end if;

  select coalesce(array_agg(c.oracle_id) filter (where e.board in ('main', 'commander')), '{}'),
         coalesce(array_agg(e.qty) filter (where e.board in ('main', 'commander')), '{}'),
         coalesce(array_agg(c.oracle_id) filter (where e.board = 'side'), '{}')
    into v_main, v_mqty, v_side
    from public.card_list_entries e join public.cards c on c.id = e.card_id
   where e.list_id = l.id;
  v_a := t1_private.meta_label(l.format, v_main, v_side, t1_private.meta_colors(v_main, v_mqty::smallint[]));
  select a.name into v_name from t1_private.meta_archetypes a where a.id = v_a and a.format = l.format and a.status = 'approved';
  if v_a = 0 or v_name is null then
    return jsonb_build_object('format', l.format, 'a', 0, 'reason', 'other');
  end if;

  v_sim := t1_private.meta_similarity(l.format, v_a, v_main, v_mqty);
  if public.list_spice(p_list_id, p_token)->>'word' = 'brew' then
    return jsonb_build_object('format', l.format, 'a', null, 'reason', 'brew', 'archetype', v_a, 'similarity', v_sim);
  end if;

  select i.result into r from t1_private.archetype_insight i
   where i.format = l.format and i.archetype_id = v_a and i.on_day = current_date;
  if r is not null then return r || jsonb_build_object('similarity', v_sim); end if;

  -- the archetype's decks of the last 90 days, then each one's matches by event and deck (meta_matches' key), then
  -- the opponent's deck; mirrors left out
  with mine as materialized (
    select d.id, d.event_id, d.on_date from t1_private.meta_decks d
     where d.format = l.format and d.archetype_id = v_a and d.on_date > current_date - 90),
  sides as (
    select m.on_date, mm.b opp, case mm.result when 'a' then 'w' when 'b' then 'l' else 'd' end res
      from mine m join t1_private.meta_matches mm on mm.event_id = m.event_id and mm.a = m.id
    union all
    select m.on_date, mm.a, case mm.result when 'b' then 'w' when 'a' then 'l' else 'd' end
      from mine m join t1_private.meta_matches mm on mm.event_id = m.event_id and mm.b = m.id),
  games as (
    select sd.on_date, od.archetype_id vs, sd.res from sides sd join t1_private.meta_decks od on od.id = sd.opp
     where od.archetype_id <> v_a),
  rec as (
    select p.key, count(*) filter (where g.res = 'w') w, count(*) filter (where g.res = 'l') ls, count(*) filter (where g.res = 'd') dr
      from (values ('month', 30, 0), ('week', 7, 0), ('prev', 14, 7)) p(key, back, upto)
      left join games g on g.on_date > current_date - p.back and g.on_date <= current_date - p.upto
     group by p.key),
  vs as (
    select g.vs, count(*) filter (where g.res = 'w') w, count(*) filter (where g.res = 'l') ls, count(*) filter (where g.res = 'd') dr
      from games g where g.vs <> 0 group by g.vs)
  select jsonb_build_object(
    'format', l.format, 'a', v_a, 'name', v_name,
    'month', (select jsonb_build_object('wins', w, 'losses', ls, 'draws', dr) from rec where key = 'month'),
    'week', (select jsonb_build_object('wins', w, 'losses', ls, 'draws', dr) from rec where key = 'week'),
    'prev', (select jsonb_build_object('wins', w, 'losses', ls, 'draws', dr) from rec where key = 'prev'),
    'matchups', coalesce((select jsonb_agg(jsonb_build_object('vs', v.vs, 'name', a.name, 'wins', v.w, 'losses', v.ls, 'draws', v.dr)
                                           order by v.w + v.ls + v.dr desc, v.vs)
                            from vs v join t1_private.meta_archetypes a on a.id = v.vs and a.status = 'approved'), '[]'::jsonb))
    into r;
  insert into t1_private.archetype_insight (format, archetype_id, on_day, result) values (l.format, v_a, current_date, r)
  on conflict (format, archetype_id) do update set on_day = excluded.on_day, result = excluded.result;
  return r || jsonb_build_object('similarity', v_sim);
end $$;

revoke execute on function t1_private.meta_similarity(text, integer, uuid[], integer[]) from public, anon, authenticated;
revoke execute on function public.list_insight(uuid, text) from public;
grant execute on function public.list_insight(uuid, text) to anon, authenticated;
