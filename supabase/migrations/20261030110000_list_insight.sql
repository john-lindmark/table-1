-- A deck's archetype in Insights, on the deck's own screen (John, 2026-10-30): the archetype Insights' rules give the
-- deck (meta_label, as Spice does), its match record over the last 30 days, this week and the week before, and its
-- record against each other archetype over 90 days. Contract: contract/insights-2026-10-24.md § A deck's archetype.
--
-- Records count matches between two known decks of different archetypes (TopDeck and Melee rounds, MTGO top 8
-- brackets), all tiers; the clients word them (testdata/insights/deck-insight.json). Who may ask is list_spice's
-- rule: the owner, someone the deck is shared with, or a share link's holder. The records are the same for every deck
-- of an archetype, so they're kept per archetype and day in t1_private.archetype_insight (the first ask of the day
-- for Modern's largest archetype took ~0.5 s on live).

create table if not exists t1_private.archetype_insight (
  format text not null,
  archetype_id integer not null,
  on_day date not null,
  result jsonb not null,
  primary key (format, archetype_id)
);
revoke all on t1_private.archetype_insight from public, anon, authenticated;

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

  select i.result into r from t1_private.archetype_insight i
   where i.format = l.format and i.archetype_id = v_a and i.on_day = current_date;
  if r is not null then return r; end if;

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
  return r;
end $$;

revoke execute on function public.list_insight(uuid, text) from public;
grant execute on function public.list_insight(uuid, text) to anon, authenticated;
