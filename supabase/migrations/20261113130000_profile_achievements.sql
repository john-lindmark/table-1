-- Achievements on profiles (contract/public-events-leagues-2026-11-13.md § 7; John 2026-11-13: "users should have
-- little achievements on their profile if they've had top placements in a league and their current placement in a
-- general leaderboard. viewability toggleable by the user of course").
--
-- Nothing is stored: achievements are read from the league standings and the format boards each time. Who sees them
-- is one more profile part (private | friends | public, default public), capped by the profile like the others, kept
-- in its own table so the sharing functions stay as they are.

create table if not exists t1_private.achievement_settings (
  user_id uuid primary key references auth.users (id) on delete cascade,
  visibility text not null check (visibility in ('private', 'friends', 'public')),
  updated_at timestamptz not null default now()
);
alter table t1_private.achievement_settings enable row level security;

-- An account's achievements. League: one per season where they are the champion (won the season's final), finished
-- or stand in the top 8, qualified for the final, or won an event. Boards: each board they have a rating on; p_own
-- false keeps only boards that list them (so hiding from the boards hides these too).
create or replace function t1_private.achievements_of(p_user_id uuid, p_own boolean)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s record;
  t record;
  v_players integer;
  v_champion boolean;
  v_items jsonb := '[]'::jsonb;
  b record;
  v_me jsonb;
begin
  for s in
    select ls.id, ls.name, ls.ends_on, l.id as league_id, l.slug, l.name as league_name,
           t1_private.season_state(ls) as state
      from public.league_seasons ls
      join public.leagues l on l.id = ls.league_id and l.archived_at is null and not l.is_demo
     where exists (select 1 from public.event_placements pl
                     join public.league_events le on le.event_id = pl.event_id
                    where le.season_id = ls.id and pl.user_id = p_user_id)
     order by ls.ends_on desc, ls.id
     limit 12
  loop
    select x.rank, x.points, x.wins, x.qualified into t from t1_private.league_table(s.id) x where x.user_id = p_user_id;
    select count(*) into v_players from t1_private.league_table(s.id);
    v_champion := exists (
      select 1 from public.event_placements pl
        join public.league_events le on le.event_id = pl.event_id and le.final
        join public.events e on e.id = pl.event_id and e.status in ('completed', 'archived') and not e.is_demo
       where le.season_id = s.id and pl.user_id = p_user_id and pl.place = 1);
    if v_champion or t.rank <= 8 or t.qualified is not null or t.wins > 0 then
      v_items := v_items || jsonb_build_object(
        'kind', 'league', 'league_id', s.league_id, 'league_slug', s.slug, 'league_name', s.league_name,
        'season_id', s.id, 'season_name', s.name, 'state', s.state, 'rank', t.rank, 'players', v_players,
        'points', t.points, 'wins', coalesce(t.wins, 0), 'qualified', t.qualified, 'champion', v_champion);
    end if;
  end loop;
  for b in
    select r.board, (t1_private.board_me(r.board, p_user_id)) as me
      from t1_private.format_ratings r where r.user_id = p_user_id
     order by r.board
  loop
    v_me := b.me;
    if p_own or v_me->>'rank' is not null then
      v_items := v_items || jsonb_build_object(
        'kind', 'board', 'board', b.board, 'label', t1_private.format_key_label(b.board),
        'rank', (v_me->>'rank')::integer, 'rating', (v_me->>'rating')::integer, 'matches', (v_me->>'matches')::integer,
        'to_go', (v_me->>'to_go')::integer,
        'players', (select count(*) from t1_private.board_rows(b.board))::integer);
    end if;
  end loop;
  -- Champions first, then leagues newest first (as gathered), then boards best rank first.
  return coalesce((
    select jsonb_agg(i.item order by (i.item->>'kind' = 'league') desc, coalesce((i.item->>'champion')::boolean, false) desc,
                     case when i.item->>'kind' = 'board' then coalesce((i.item->>'rank')::integer, 1000000) end, i.n)
      from jsonb_array_elements(v_items) with ordinality i(item, n)), '[]'::jsonb);
end $$;

-- A profile's achievements for the viewer: {items}; on your own profile also {visibility, listed}. Someone who
-- can't see them (the part doesn't reach them, a block, a restricted account) reads an empty list.
create or replace function public.profile_achievements(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  pr public.profiles;
  s public.share_settings;
  v_vis text;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into pr from public.profiles where id = p_user_id;
  if pr.id is null or pr.deleted_at is not null or (pr.is_demo and pr.id <> v_uid) then
    raise exception 'That account isn''t on Table 1' using errcode = 'P0002';
  end if;
  select a.visibility into v_vis from t1_private.achievement_settings a where a.user_id = p_user_id;
  v_vis := coalesce(v_vis, 'public');
  if p_user_id = v_uid then
    return jsonb_build_object(
      'items', t1_private.achievements_of(p_user_id, true), 'visibility', v_vis,
      'listed', not exists (select 1 from t1_private.leaderboard_hidden h where h.user_id = v_uid));
  end if;
  s := t1_private.share_of(p_user_id);
  if not t1_private.vis_ok(t1_private.share_level(p_user_id, v_uid), s.profile, v_vis) then
    return jsonb_build_object('items', '[]'::jsonb);
  end if;
  return jsonb_build_object('items', t1_private.achievements_of(p_user_id, false));
end $$;

-- Who sees your achievements: private, friends or public (still capped by who sees your profile).
create or replace function public.achievements_visibility_set(p_visibility text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_before text;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_visibility is null or p_visibility not in ('private', 'friends', 'public') then
    raise exception 'Visibility is private, friends or public' using errcode = '22023';
  end if;
  select a.visibility into v_before from t1_private.achievement_settings a where a.user_id = v_uid;
  insert into t1_private.achievement_settings (user_id, visibility) values (v_uid, p_visibility)
  on conflict (user_id) do update set visibility = excluded.visibility, updated_at = now();
  if coalesce(v_before, 'public') <> p_visibility then
    insert into public.account_audit (actor, action, before, after)
    values (v_uid, 'sharing.achievements', jsonb_build_object('visibility', coalesce(v_before, 'public')),
            jsonb_build_object('visibility', p_visibility));
  end if;
  return jsonb_build_object('visibility', p_visibility);
end $$;

revoke execute on function t1_private.achievements_of(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.profile_achievements(uuid) from public, anon;
revoke execute on function public.achievements_visibility_set(text) from public, anon;
grant execute on function public.profile_achievements(uuid), public.achievements_visibility_set(text) to authenticated;
