-- When a cube changes after it's ranked (John, 2026-10-22; contract/cube-rankings-2026-10-21.md, "Cube changes"),
-- and telling a cube's owner that someone ranked it.
--  - cube_rankings.baseline: the cube's main-board Oracle ids the ranking last caught up with (sorted). Set when the
--    ranking starts; existing rankings take the cube as it is now. Clients compare it with the cube's cards: cards
--    added since wait outside the lists until they're placed (the engine), cards removed are simply gone from them.
--  - cube_ranking_get returns `baseline`; cube_ranking_catch_up(p_id) (the ranking's maker) sets it to the cube as it
--    is now, once every new card is placed (or there were only removals).
--  - ranking.started: when someone else starts a ranking of your cube that you can see (shared with the cube; not
--    Only me), or later switches theirs from Only me to shared, you get one push: at most one per person and cube a
--    week, never across a block, never for your own rankings.

alter table public.cube_rankings add column if not exists baseline jsonb;

-- The cube's main-board cards, as Oracle ids (sorted text).
create or replace function t1_private.cube_cards(p_list_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(o order by o), '[]'::jsonb)
    from (select distinct c.oracle_id::text o from public.card_list_entries e join public.cards c on c.id = e.card_id
           where e.list_id = p_list_id and e.board = 'main' and e.qty > 0) d;
$$;

update public.cube_rankings r set baseline = t1_private.cube_cards(r.list_id) where baseline is null;

-- One push per (person, cube) a week, so starting and deleting rankings can't be used to page an owner.
create table if not exists t1_private.ranking_notices (
  ranker uuid not null references auth.users (id) on delete cascade,
  list_id uuid not null references public.card_lists (id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (ranker, list_id)
);

-- Tells the cube's owner about a ranking of their cube by someone else, when the owner can see it.
create or replace function t1_private.ranking_tell_owner(r public.cube_rankings)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_owner uuid := (select user_id from public.card_lists where id = r.list_id and deleted_at is null);
  v_sent timestamptz;
begin
  if v_owner is null or v_owner = r.user_id or r.sharing <> 'cube' or not t1_private.ranking_seen(r, v_owner) then return; end if;
  select sent_at into v_sent from t1_private.ranking_notices where ranker = r.user_id and list_id = r.list_id;
  if v_sent is not null and v_sent > now() - interval '7 days' then return; end if;
  insert into t1_private.ranking_notices (ranker, list_id) values (r.user_id, r.list_id)
  on conflict (ranker, list_id) do update set sent_at = now();
  perform public.enqueue_notification('ranking.started', null, array[v_owner], jsonb_build_object(
    'from_name', (select display_name from public.profiles where id = r.user_id),
    'cube_name', (select name from public.card_lists where id = r.list_id),
    'ranking_id', r.id, 'list_id', r.list_id, 'user_id', r.user_id));
end $$;

-- Starts a ranking of a cube the caller can see. The id is the client's, so a retry returns the same ranking.
create or replace function public.cube_ranking_create(
  p_id uuid, p_list_id uuid, p_name text default null, p_depth text default 'half', p_top integer default 100,
  p_sharing text default 'cube')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_name text := left(coalesce(nullif(btrim(p_name), ''), 'My ranking'), 60);
  r public.cube_rankings;
begin
  if v_uid is null then raise exception 'Sign in to rank a cube' using errcode = '28000'; end if;
  if p_id is null or p_list_id is null then raise exception 'Say which cube to rank' using errcode = '22023'; end if;
  select * into r from public.cube_rankings where id = p_id;
  if r.id is not null then
    if r.user_id <> v_uid then raise exception 'That''s private' using errcode = '42501'; end if;
    return t1_private.ranking_json(r, v_uid);
  end if;
  if not t1_private.cube_seen(p_list_id, v_uid) then raise exception 'That''s private' using errcode = '42501'; end if;
  if coalesce(p_depth, '') not in ('half', 'full') then raise exception 'Sort the top half or every card' using errcode = '22023'; end if;
  if coalesce(p_top, 0) not in (50, 100) then raise exception 'The final is a top 50 or a top 100' using errcode = '22023'; end if;
  if coalesce(p_sharing, '') not in ('cube', 'private') then raise exception 'Unknown sharing' using errcode = '22023'; end if;
  if (select count(*) from public.cube_rankings where user_id = v_uid) >= 200 then
    raise exception 'At most 200 rankings: delete one first' using errcode = '22023';
  end if;
  insert into public.cube_rankings (id, user_id, list_id, name, depth, top_size, sharing, baseline)
  values (p_id, v_uid, p_list_id, v_name, p_depth, p_top, p_sharing, t1_private.cube_cards(p_list_id))
  returning * into r;
  perform t1_private.ranking_tell_owner(r);
  return t1_private.ranking_json(r, v_uid);
end $$;

-- Renames or changes the settings of the caller's ranking. Nulls leave a field alone. Sharing an Only me ranking with
-- the cube tells the owner (once a week at most, as above).
create or replace function public.cube_ranking_update(
  p_id uuid, p_name text default null, p_depth text default null, p_top integer default null, p_sharing text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  r public.cube_rankings;
  v_was text;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into r from public.cube_rankings where id = p_id for update;
  if r.id is null or r.user_id <> v_uid then raise exception 'That''s private' using errcode = '42501'; end if;
  if p_name is not null and btrim(p_name) = '' then raise exception 'Give the ranking a name' using errcode = '22023'; end if;
  if p_depth is not null and p_depth not in ('half', 'full') then raise exception 'Sort the top half or every card' using errcode = '22023'; end if;
  if p_top is not null and p_top not in (50, 100) then raise exception 'The final is a top 50 or a top 100' using errcode = '22023'; end if;
  if p_sharing is not null and p_sharing not in ('cube', 'private') then raise exception 'Unknown sharing' using errcode = '22023'; end if;
  v_was := r.sharing;
  update public.cube_rankings set
    name = coalesce(left(btrim(p_name), 60), name), depth = coalesce(p_depth, depth), top_size = coalesce(p_top, top_size),
    sharing = coalesce(p_sharing, sharing), updated_at = now()
   where id = p_id returning * into r;
  if v_was = 'private' and r.sharing = 'cube' then perform t1_private.ranking_tell_owner(r); end if;
  return t1_private.ranking_json(r, v_uid);
end $$;

-- The ranking has caught up with its cube: every card added since it last did is placed (or only cards left).
-- Only its maker; the baseline becomes the cube's cards as they are now.
create or replace function public.cube_ranking_catch_up(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  r public.cube_rankings;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into r from public.cube_rankings where id = p_id for update;
  if r.id is null or r.user_id <> v_uid then raise exception 'That''s private' using errcode = '42501'; end if;
  update public.cube_rankings set baseline = t1_private.cube_cards(list_id), updated_at = now()
   where id = p_id returning * into r;
  return t1_private.ranking_json(r, v_uid) || jsonb_build_object('baseline', r.baseline);
end $$;

-- One ranking with its log, change log, baseline and (when the caller can see the cube) the cube's cards and the
-- printing it holds of each.
create or replace function public.cube_ranking_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  r public.cube_rankings;
  v_cube jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into r from public.cube_rankings where id = p_id;
  if r.id is null or not t1_private.ranking_seen(r, v_uid) then raise exception 'That''s private' using errcode = '42501'; end if;
  v_cube := t1_private.cube_json(r.list_id, v_uid);
  if (v_cube->>'can_see')::boolean then
    v_cube := v_cube || jsonb_build_object('cards', t1_private.cube_cards(r.list_id),
      'printings', (
      select coalesce(jsonb_object_agg(o, card), '{}'::jsonb)
        from (select distinct on (o) o, card
                from (select c.oracle_id::text o, e.card_id::text card, sum(e.qty) q
                        from public.card_list_entries e join public.cards c on c.id = e.card_id
                       where e.list_id = r.list_id and e.board = 'main' and e.qty > 0
                       group by 1, 2) p
               order by o, q desc, card) d));
  end if;
  return t1_private.ranking_json(r, v_uid) || jsonb_build_object('log', r.screens, 'changes', r.changes, 'cube', v_cube,
                                                                 'baseline', coalesce(r.baseline, '[]'::jsonb));
end $$;

revoke execute on function t1_private.cube_cards(uuid) from public;
revoke execute on function t1_private.ranking_tell_owner(public.cube_rankings) from public;
revoke execute on function public.cube_ranking_catch_up(uuid) from public, anon;
grant execute on function public.cube_ranking_catch_up(uuid) to authenticated;
