-- A push can no longer wipe a ranking (contract/cube-rankings-2026-10-21.md, "Server" and "Saving").
-- On 2026-10-23 00:17 UTC an iPhone sent overlapping pushes after a double tap on Lock in; its conflict recovery left it
-- believing the server held a few screens, and its next push (current rev, keep = a handful) replaced 504 screens. The
-- server took it because rev was all it checked. Now:
--  - p_count: the screens the app believes the server holds. A different count is a conflict (PT409).
--  - p_drop: screens to take out wherever they sit (undo, redo, let the pick win), matched by session, cards and time, so
--    an app never re-sends the log after a removed screen (re-sending stopped working past 1000 screens: a push carries
--    at most 1000). New apps always push p_keep = p_count = the whole log, p_drop = what they removed, p_add = what they
--    locked in.
--  - p_removed: how many screens the push means to take out. The server works out what it really removes (old screens
--    after p_keep that p_add doesn't send again, plus the p_drop screens it finds); a different number is a conflict.
--    Apps built before this send neither: they may remove at most 25.
--  - Every screen a push removes is kept in t1_private.cube_ranking_removed (with where it sat), so any removal can be
--    put back with t1_private.cube_ranking_restore_removed(entry).
-- PT409, never 40001 (see 20261022120000_ranking_conflict_409.sql).

create table if not exists t1_private.cube_ranking_removed (
  id bigint generated always as identity primary key,
  ranking_id uuid not null references public.cube_rankings (id) on delete cascade,
  user_id uuid not null,
  rev integer not null,                 -- the rev the push replaced
  op_id uuid,
  keep integer not null,
  count_before integer not null,
  screens jsonb not null,               -- [{i, screen}]: each removed screen and its index in the log before the push
  declared boolean not null,            -- the app said how many it meant to remove (p_removed)
  at timestamptz not null default now()
);
create index if not exists cube_ranking_removed_ranking on t1_private.cube_ranking_removed (ranking_id, id);
alter table t1_private.cube_ranking_removed enable row level security;
revoke all on t1_private.cube_ranking_removed from anon, authenticated, public;

-- What makes two screens the same screen: session, cards in order, and time (whole ms).
create or replace function t1_private.ranking_screen_key(e jsonb) returns text language sql immutable set search_path = '' as $$
  select (e->>'s') || '|' || (e->'o')::text || '|' || coalesce(round((e->>'t')::numeric)::text, '') $$;
revoke execute on function t1_private.ranking_screen_key(jsonb) from public;

drop function if exists public.cube_ranking_push(uuid, integer, integer, jsonb, integer, integer, integer, uuid, jsonb);
create or replace function public.cube_ranking_push(
  p_id uuid, p_rev integer, p_keep integer, p_add jsonb default '[]'::jsonb,
  p_sorted integer default null, p_categories integer default null, p_ranked integer default null, p_op_id uuid default null,
  p_changes jsonb default '[]'::jsonb, p_count integer default null, p_removed integer default null,
  p_drop jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  r public.cube_rankings;
  v_add jsonb := coalesce(p_add, '[]'::jsonb);
  v_drop jsonb := coalesce(p_drop, '[]'::jsonb);
  v_changes jsonb := coalesce(p_changes, '[]'::jsonb);
  v_keep jsonb;
  v_bad text;
  v_removed jsonb;
  v_n integer;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into r from public.cube_rankings where id = p_id for update;
  if r.id is null or r.user_id <> v_uid then raise exception 'That''s private' using errcode = '42501'; end if;
  if p_op_id is not null and r.last_op = p_op_id then return t1_private.ranking_json(r, v_uid); end if;
  if p_rev is distinct from r.rev or (p_count is not null and p_count <> r.screen_count) then
    raise exception 'This ranking changed on another device' using errcode = 'PT409';
  end if;
  if p_keep is null or p_keep < 0 or p_keep > r.screen_count then
    raise exception 'Keep between 0 and % screens', r.screen_count using errcode = '22023';
  end if;
  if jsonb_typeof(v_add) <> 'array' then raise exception 'Screens come as a list' using errcode = '22023'; end if;
  if jsonb_array_length(v_add) > 1000 then
    raise exception 'At most 1000 screens in one save' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(v_add) e
              where jsonb_typeof(e) <> 'object'
                 or coalesce(e->>'s', '') not in ('W', 'U', 'B', 'R', 'G', 'M', 'C', 'L', 'F', 'P')
                 or jsonb_typeof(e->'o') is distinct from 'array'
                 or jsonb_array_length(e->'o') not between 2 and case when e->>'s' = 'P' then 15 else 4 end
                 or (e ? 't' and jsonb_typeof(e->'t') <> 'number')
                 or exists (select 1 from jsonb_array_elements(e->'o') x
                             where jsonb_typeof(x) <> 'string'
                                or x #>> '{}' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
                 or (select count(distinct x) from jsonb_array_elements_text(e->'o') x) <> jsonb_array_length(e->'o')) then
    raise exception 'A screen is 2 to 4 different cards (a pick, up to 15) and a session' using errcode = '22023';
  end if;
  if jsonb_typeof(v_changes) <> 'array' or jsonb_array_length(v_changes) > 2000
     or exists (select 1 from jsonb_array_elements(v_changes) e
                 where jsonb_typeof(e) <> 'object'
                    or coalesce(e->>'s', '') not in ('W', 'U', 'B', 'R', 'G', 'M', 'C', 'L', 'F')
                    or coalesce(e->>'c', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                    or jsonb_typeof(coalesce(e->'f', 'null')) not in ('null', 'number')
                    or jsonb_typeof(coalesce(e->'to', 'null')) not in ('null', 'number')
                    or coalesce(e->>'by', 'screen') not in ('screen', 'undo', 'redo', 'pick', 'pick_win', 'settings')) then
    raise exception 'A change is a list, a card and its places' using errcode = '22023';
  end if;
  select string_agg(distinct x, ', ') into v_bad
    from jsonb_array_elements(v_add) e, jsonb_array_elements_text(e->'o') x
   where not exists (select 1 from public.card_oracles o where o.oracle_id = x::uuid);
  if v_bad is not null then raise exception 'Unknown card: %', v_bad using errcode = '22023'; end if;
  if jsonb_typeof(v_drop) <> 'array' or jsonb_array_length(v_drop) > 1000
     or exists (select 1 from jsonb_array_elements(v_drop) e where jsonb_typeof(e) <> 'object' or jsonb_typeof(e->'o') is distinct from 'array') then
    raise exception 'Screens to take out come as a list' using errcode = '22023';
  end if;

  -- What the push takes out: old screens after p_keep that p_add doesn't send again (each re-sent copy covers one),
  -- and the p_drop screens found among the kept ones (one each; one already gone is skipped).
  with old as (
    select e, n, t1_private.ranking_screen_key(e) k, row_number() over (partition by t1_private.ranking_screen_key(e) order by n) rn
      from jsonb_array_elements(r.screens) with ordinality x(e, n)),
  again as (select t1_private.ranking_screen_key(e) k, count(*) c from jsonb_array_elements(v_add) e group by 1),
  drops as (select t1_private.ranking_screen_key(e) k, count(*) c from jsonb_array_elements(v_drop) e group by 1),
  tail as (select old.* from old where old.n > p_keep),
  tail_rn as (select tail.*, row_number() over (partition by tail.k order by tail.n) trn from tail),
  kept_rn as (select old.*, row_number() over (partition by old.k order by old.n) krn from old where old.n <= p_keep),
  gone as (
    select t.e, t.n from tail_rn t left join again a on a.k = t.k where t.trn > coalesce(a.c, 0)
    union all
    select k.e, k.n from kept_rn k join drops d on d.k = k.k where k.krn <= d.c)
  select coalesce(jsonb_agg(jsonb_build_object('i', gone.n - 1, 'screen', gone.e) order by gone.n), '[]'::jsonb),
         coalesce((select jsonb_agg(k.e order by k.n) from kept_rn k left join drops d on d.k = k.k where k.krn > coalesce(d.c, 0)), '[]'::jsonb)
    into v_removed, v_keep
    from gone;
  v_n := jsonb_array_length(v_removed);
  if p_removed is not null and p_removed <> v_n then
    raise exception 'This ranking changed on another device (the save would remove % screens, not %)', v_n, p_removed
      using errcode = 'PT409';
  end if;
  if p_removed is null and v_n > 25 then
    raise exception 'This ranking changed on another device (the save would remove % screens)', v_n using errcode = 'PT409';
  end if;
  if v_n > 0 then
    insert into t1_private.cube_ranking_removed (ranking_id, user_id, rev, op_id, keep, count_before, screens, declared)
    values (r.id, v_uid, r.rev, p_op_id, p_keep, r.screen_count, v_removed, p_removed is not null);
  end if;

  if jsonb_array_length(v_keep) + jsonb_array_length(v_add) > 6000 then
    raise exception 'At most 6000 screens in a ranking' using errcode = '22023';
  end if;
  update public.cube_rankings set
    screens = v_keep || coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('s', e->'s', 'o', e->'o', 't', e->'t'))
                                                   order by n)
                                    from jsonb_array_elements(v_add) with ordinality y(e, n)), '[]'::jsonb),
    screen_count = jsonb_array_length(v_keep) + jsonb_array_length(v_add),
    changes = (select coalesce(jsonb_agg(e order by n), '[]'::jsonb)
                 from jsonb_array_elements(changes || (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                          's', e->'s', 'c', e->'c', 'f', e->'f', 'to', e->'to', 't', e->'t', 'by', e->'by', 'n', e->'n')) order by n), '[]'::jsonb)
                                                         from jsonb_array_elements(v_changes) with ordinality y(e, n)))
                      with ordinality x(e, n)
                where n > jsonb_array_length(changes) + jsonb_array_length(v_changes) - 5000),
    rev = rev + 1, last_op = p_op_id,
    sorted = least(greatest(coalesce(p_sorted, sorted), 0), 8),
    categories = least(greatest(coalesce(p_categories, categories), 0), 8),
    ranked = least(greatest(coalesce(p_ranked, ranked), 0), top_size),
    updated_at = now()
   where id = p_id returning * into r;
  return t1_private.ranking_json(r, v_uid);
end $$;
revoke execute on function public.cube_ranking_push(uuid, integer, integer, jsonb, integer, integer, integer, uuid, jsonb, integer, integer, jsonb)
  from public, anon;
grant execute on function public.cube_ranking_push(uuid, integer, integer, jsonb, integer, integer, integer, uuid, jsonb, integer, integer, jsonb)
  to authenticated;

-- Support: puts back the screens one push removed, at the end of the log (a screen's place in the log only matters when
-- two screens contradict each other), skipping any that are back already. Bumps rev so an open app reloads instead of
-- saving over it. Service role / SQL editor only.
create or replace function t1_private.cube_ranking_restore_removed(p_entry bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e t1_private.cube_ranking_removed;
  r public.cube_rankings;
  v_back jsonb;
begin
  select * into e from t1_private.cube_ranking_removed where id = p_entry;
  if e.id is null then raise exception 'No removal %', p_entry using errcode = '22023'; end if;
  select * into r from public.cube_rankings where id = e.ranking_id for update;
  select coalesce(jsonb_agg(x->'screen' order by (x->>'i')::int), '[]'::jsonb) into v_back
    from jsonb_array_elements(e.screens) x
   where not exists (select 1 from jsonb_array_elements(r.screens) s
                      where t1_private.ranking_screen_key(s) = t1_private.ranking_screen_key(x->'screen'));
  if jsonb_array_length(v_back) = 0 then
    return jsonb_build_object('restored', 0, 'screens', r.screen_count, 'rev', r.rev);
  end if;
  if r.screen_count + jsonb_array_length(v_back) > 6000 then
    raise exception 'At most 6000 screens in a ranking' using errcode = '22023';
  end if;
  update public.cube_rankings set screens = screens || v_back, screen_count = screen_count + jsonb_array_length(v_back),
         rev = rev + 1, last_op = null, updated_at = now()
   where id = r.id returning * into r;
  return jsonb_build_object('restored', jsonb_array_length(v_back), 'screens', r.screen_count, 'rev', r.rev);
end $$;
revoke execute on function t1_private.cube_ranking_restore_removed(bigint) from public, anon, authenticated;
