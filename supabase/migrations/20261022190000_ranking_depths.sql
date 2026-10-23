-- Rankings can sort the top quarter or the top third of each color, as well as the top half or every card
-- (contract/cube-rankings-2026-10-21.md, "Depth"; John, 2026-10-23). The final top N comes out exact at any depth: it
-- places a card only once it's known to beat every card still in the running, and asks about a card itself when a color
-- has more cards in the top N than it sorted. On a 540-card cube with a top 50, a quarter of each color took about a
-- third fewer screens than a half (simulated with testdata/cube-ranking/make_cases.py's engine). Only the allowed
-- values change; cube_ranking_create and cube_ranking_update are otherwise as in 20261022160000_ranking_cube_changes.sql.

alter table public.cube_rankings drop constraint if exists cube_rankings_depth_check;
alter table public.cube_rankings add constraint cube_rankings_depth_check check (depth in ('quarter', 'third', 'half', 'full'));

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
  if coalesce(p_depth, '') not in ('quarter', 'third', 'half', 'full') then raise exception 'Sort the top quarter, third or half, or every card' using errcode = '22023'; end if;
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
  if p_depth is not null and p_depth not in ('quarter', 'third', 'half', 'full') then raise exception 'Sort the top quarter, third or half, or every card' using errcode = '22023'; end if;
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
