-- Leagues you can see without searching (contract/public-events-leagues-2026-11-13.md § 3 "Leagues on the Events home").
-- leagues_home gains `active`: leagues running now that you neither run nor follow, so the Events home and
-- Find → Leagues can show some before anything is typed. A league is running when it has a season that isn't over or
-- an event still to play. Soonest event first, then by name; 20 at most. Old builds ignore the key.
create or replace function public.leagues_home(p_query text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_q text := lower(btrim(coalesce(p_query, '')));
begin
  return jsonb_build_object(
    'mine', coalesce((
      select jsonb_agg(t1_private.league_card_json(l) || jsonb_build_object('role', m.role) order by lower(l.name))
        from public.league_members m join public.leagues l on l.id = m.league_id
       where m.user_id = v_uid and l.archived_at is null), '[]'::jsonb),
    'following', coalesce((
      select jsonb_agg(t1_private.league_card_json(l) || jsonb_build_object('notify', f.notify) order by lower(l.name))
        from public.league_follows f join public.leagues l on l.id = f.league_id
       where f.user_id = v_uid and f.following and l.archived_at is null and not l.is_demo
         and not exists (select 1 from public.league_members m where m.league_id = l.id and m.user_id = v_uid)), '[]'::jsonb),
    'found', case when char_length(v_q) < 2 then '[]'::jsonb else coalesce((
      select jsonb_agg(t1_private.league_card_json(x) order by lower(x.name))
        from (select l.* from public.leagues l
               where l.archived_at is null and not l.is_demo
                 and (position(v_q in lower(l.name)) > 0 or position(v_q in lower(coalesce(l.region, ''))) > 0)
               order by lower(l.name) limit 30) x), '[]'::jsonb) end,
    'active', case when char_length(v_q) >= 2 then '[]'::jsonb else coalesce((
      select jsonb_agg(t1_private.league_card_json(x.l) order by x.next_at nulls last, lower((x.l).name))
        from (select l, (select min(coalesce(e.starts_at, e.created_at))
                           from public.league_events le join public.events e on e.id = le.event_id
                          where le.league_id = l.id and e.status in ('setup', 'seated', 'in_progress') and not e.is_demo) next_at
                from public.leagues l
               where l.archived_at is null and not l.is_demo
                 and (v_uid is null or not exists (select 1 from public.league_members m where m.league_id = l.id and m.user_id = v_uid))
                 and (v_uid is null or not exists (select 1 from public.league_follows f
                                                    where f.league_id = l.id and f.user_id = v_uid and f.following))
                 and (exists (select 1 from public.league_seasons s where s.league_id = l.id and t1_private.season_state(s) <> 'over')
                      or exists (select 1 from public.league_events le join public.events e on e.id = le.event_id
                                  where le.league_id = l.id and e.status in ('setup', 'seated', 'in_progress') and not e.is_demo))
               order by 2 nulls last, lower(l.name) limit 20) x), '[]'::jsonb) end);
end $$;
