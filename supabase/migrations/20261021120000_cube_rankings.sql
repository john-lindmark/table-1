-- Cube rankings (contract/cube-rankings-2026-10-21.md): stack-rank a cube's cards, cuberanker.com style. A ranking is
-- one person's log of screens (2-4 cards put in order, best first) for one cube; clients work out everything else (the
-- order of each color, the final top N, the next screen, comparisons) from that log with the shared engine
-- (testdata/cube-ranking/make_cases.py). The server keeps the log, who can see it, and the progress shown in lists.
--  - Anyone who can see a cube can rank it (its owner, or friends / anyone when it's shared on the owner's profile).
--  - A ranking shows to everyone who can see the cube (sharing 'cube', the default) or only to its maker ('private').
--  - Written only through these security definer RPCs; the table has RLS on and no policies.
--  - Deleting the cube deletes its rankings; deleting the account deletes the account's rankings (FK cascade).
--  - A shared ranking's name is checked by moderation like a list name (subject 'ranking_name', action 'unshare').
--  - P1P1 picks are screens too (s 'P': the picked card first, then the rest of its pack, up to 15 cards).
--  - The change log (`changes`) is what the maker's client saw move after each change it saved; the newest 5000 stay.

create table if not exists public.cube_rankings (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  list_id uuid not null references public.card_lists(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  depth text not null default 'half' check (depth in ('half', 'full')),
  top_size integer not null default 100 check (top_size in (50, 100)),
  sharing text not null default 'cube' check (sharing in ('cube', 'private')),
  screens jsonb not null default '[]'::jsonb,   -- [{s: W|U|B|R|G|M|C|L|F|P, o: [oracle ids, best first], t?: epoch ms}]
  changes jsonb not null default '[]'::jsonb,   -- [{s: job, c: oracle id, f: place | null, to: place | null, t, by, n}]
  screen_count integer not null default 0,
  rev integer not null default 0,               -- bumped by every push; a push names the rev it builds on
  last_op uuid,                                 -- the last push's op id, so a retried push is answered, not refused
  sorted integer not null default 0 check (sorted between 0 and 8),
  categories integer not null default 0 check (categories between 0 and 8),
  ranked integer not null default 0 check (ranked between 0 and 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists cube_rankings_list_idx on public.cube_rankings (list_id, updated_at desc);
create index if not exists cube_rankings_user_idx on public.cube_rankings (user_id, updated_at desc);
alter table public.cube_rankings enable row level security;
revoke all on public.cube_rankings from anon, authenticated;

-- Briefs (ranking-brief edge function): Claude's 2-5 sentence comparison of two rankings for one list, cached per
-- ordered pair, list and a hash of the inputs (both revs, settings, names and the cube's cards), so each is written
-- once per change. Written and read only by the edge function (service role) after it has read both rankings as the
-- caller; RLS on, no policies, no grants. Deleting either ranking deletes its briefs.
create table if not exists public.ranking_briefs (
  a uuid not null references public.cube_rankings(id) on delete cascade,
  b uuid not null references public.cube_rankings(id) on delete cascade,
  list text not null check (list in ('W', 'U', 'B', 'R', 'G', 'M', 'C', 'L', 'F')),
  input_hash text not null,
  brief text not null check (char_length(brief) between 1 and 1500),
  model text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (a, b, list, input_hash)
);
create index if not exists ranking_briefs_creator_idx on public.ranking_briefs (created_by, created_at);
alter table public.ranking_briefs enable row level security;
revoke all on public.ranking_briefs from anon, authenticated;

-- ==================================================================== a_helpers
-- A live cube the viewer may see: their own, or shared with them on the owner's profile.
create or replace function t1_private.cube_seen(p_list_id uuid, p_viewer uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_viewer is not null and exists (
    select 1 from public.card_lists l, t1_private.share_of(l.user_id) s
     where l.id = p_list_id and l.kind = 'cube' and l.deleted_at is null
       and (l.user_id = p_viewer
            or (t1_private.live_account(l.user_id)
                and t1_private.vis_ok(t1_private.share_level(l.user_id, p_viewer), s.profile,
                                      coalesce(l.visibility, s.cubes, s.library)))));
$$;

-- A ranking the viewer may see: their own, or shared with the cube's audience by a live, unrestricted account that
-- hasn't blocked them (or been blocked by them).
create or replace function t1_private.ranking_seen(r public.cube_rankings, p_viewer uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_viewer is not null and (r.user_id = p_viewer
    or (r.sharing = 'cube' and t1_private.live_account(r.user_id) and not t1_private.is_restricted(r.user_id)
        and t1_private.share_level(r.user_id, p_viewer) >= 0 and t1_private.cube_seen(r.list_id, p_viewer)));
$$;

create or replace function t1_private.ranking_json(r public.cube_rankings, p_viewer uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', r.id, 'list_id', r.list_id, 'name', r.name, 'depth', r.depth, 'top', r.top_size,
           'sharing', r.sharing, 'screens', r.screen_count, 'rev', r.rev, 'sorted', r.sorted,
           'categories', r.categories, 'ranked', r.ranked, 'created_at', r.created_at, 'updated_at', r.updated_at,
           'mine', r.user_id = p_viewer, 'by', t1_private.person_json(r.user_id));
$$;

create or replace function t1_private.cube_json(p_list_id uuid, p_viewer uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', l.id, 'name', l.name, 'mine', l.user_id = p_viewer,
           'owner', t1_private.person_json(l.user_id), 'can_see', t1_private.cube_seen(l.id, p_viewer))
    from public.card_lists l where l.id = p_list_id and l.deleted_at is null;
$$;

-- ==================================================================== b_rpcs
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
  insert into public.cube_rankings (id, user_id, list_id, name, depth, top_size, sharing)
  values (p_id, v_uid, p_list_id, v_name, p_depth, p_top, p_sharing)
  returning * into r;
  return t1_private.ranking_json(r, v_uid);
end $$;

-- Renames or changes the settings of the caller's ranking. Nulls leave a field alone.
create or replace function public.cube_ranking_update(
  p_id uuid, p_name text default null, p_depth text default null, p_top integer default null, p_sharing text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  r public.cube_rankings;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into r from public.cube_rankings where id = p_id for update;
  if r.id is null or r.user_id <> v_uid then raise exception 'That''s private' using errcode = '42501'; end if;
  if p_name is not null and btrim(p_name) = '' then raise exception 'Give the ranking a name' using errcode = '22023'; end if;
  if p_depth is not null and p_depth not in ('half', 'full') then raise exception 'Sort the top half or every card' using errcode = '22023'; end if;
  if p_top is not null and p_top not in (50, 100) then raise exception 'The final is a top 50 or a top 100' using errcode = '22023'; end if;
  if p_sharing is not null and p_sharing not in ('cube', 'private') then raise exception 'Unknown sharing' using errcode = '22023'; end if;
  update public.cube_rankings set
    name = coalesce(left(btrim(p_name), 60), name), depth = coalesce(p_depth, depth), top_size = coalesce(p_top, top_size),
    sharing = coalesce(p_sharing, sharing), updated_at = now()
   where id = p_id returning * into r;
  return t1_private.ranking_json(r, v_uid);
end $$;

-- Changes the log: keeps its first p_keep screens and appends p_add. Appending a screen keeps them all; undo keeps all
-- but the last; a redo of screen i keeps i and re-sends the ones after it. p_rev must be the rev the client built on
-- (else 40001 and the client reloads); p_op_id makes a retry of the same push return the stored result.
-- p_sorted / p_categories / p_ranked are the client's progress for list rows; p_changes is appended to the change log.
create or replace function public.cube_ranking_push(
  p_id uuid, p_rev integer, p_keep integer, p_add jsonb default '[]'::jsonb,
  p_sorted integer default null, p_categories integer default null, p_ranked integer default null, p_op_id uuid default null,
  p_changes jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  r public.cube_rankings;
  v_add jsonb := coalesce(p_add, '[]'::jsonb);
  v_changes jsonb := coalesce(p_changes, '[]'::jsonb);
  v_keep jsonb;
  v_bad text;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into r from public.cube_rankings where id = p_id for update;
  if r.id is null or r.user_id <> v_uid then raise exception 'That''s private' using errcode = '42501'; end if;
  if p_op_id is not null and r.last_op = p_op_id then return t1_private.ranking_json(r, v_uid); end if;
  if p_rev is distinct from r.rev then
    raise exception 'This ranking changed on another device' using errcode = '40001';
  end if;
  if p_keep is null or p_keep < 0 or p_keep > r.screen_count then
    raise exception 'Keep between 0 and % screens', r.screen_count using errcode = '22023';
  end if;
  if jsonb_typeof(v_add) <> 'array' then raise exception 'Screens come as a list' using errcode = '22023'; end if;
  if jsonb_array_length(v_add) > 1000 or p_keep + jsonb_array_length(v_add) > 6000 then
    raise exception 'At most 6000 screens in a ranking' using errcode = '22023';
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

  select coalesce(jsonb_agg(e order by n), '[]'::jsonb) into v_keep
    from jsonb_array_elements(r.screens) with ordinality x(e, n) where n <= p_keep;
  update public.cube_rankings set
    screens = v_keep || coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('s', e->'s', 'o', e->'o', 't', e->'t'))
                                                   order by n)
                                    from jsonb_array_elements(v_add) with ordinality y(e, n)), '[]'::jsonb),
    screen_count = p_keep + jsonb_array_length(v_add),
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

create or replace function public.cube_ranking_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select user_id into v_owner from public.cube_rankings where id = p_id;
  if v_owner is null then return jsonb_build_object('deleted', false); end if;
  if v_owner <> v_uid then raise exception 'That''s private' using errcode = '42501'; end if;
  delete from public.cube_rankings where id = p_id;
  return jsonb_build_object('deleted', true);
end $$;

-- The rankings of one cube the caller can see (theirs first, then the newest), or with no cube every ranking of the
-- caller's own. Each row says which cube it ranks.
create or replace function public.cube_rankings(p_list_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_rows jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_list_id is null then
    select coalesce(jsonb_agg(t1_private.ranking_json(r, v_uid)
                                || jsonb_build_object('cube', t1_private.cube_json(r.list_id, v_uid))
                              order by r.updated_at desc, r.id), '[]'::jsonb) into v_rows
      from public.cube_rankings r
     where r.user_id = v_uid and exists (select 1 from public.card_lists l where l.id = r.list_id and l.deleted_at is null);
    return jsonb_build_object('cube', null, 'can_rank', false, 'rankings', v_rows);
  end if;
  if not t1_private.cube_seen(p_list_id, v_uid)
     and not exists (select 1 from public.cube_rankings r where r.list_id = p_list_id and r.user_id = v_uid) then
    raise exception 'That''s private' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(t1_private.ranking_json(r, v_uid) order by r.user_id <> v_uid, r.updated_at desc, r.id), '[]'::jsonb)
    into v_rows
    from (select r.* from public.cube_rankings r
           where r.list_id = p_list_id and t1_private.ranking_seen(r, v_uid)
           order by r.user_id <> v_uid, r.updated_at desc, r.id limit 300) r;
  return jsonb_build_object('cube', t1_private.cube_json(p_list_id, v_uid),
                            'can_rank', t1_private.cube_seen(p_list_id, v_uid), 'rankings', v_rows);
end $$;

-- One ranking with its whole log, and its cube's main cards (distinct Oracle ids, sorted) when the caller can see it.
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
    v_cube := v_cube || jsonb_build_object('cards', (
      select coalesce(jsonb_agg(o order by o), '[]'::jsonb)
        from (select distinct c.oracle_id::text o from public.card_list_entries e join public.cards c on c.id = e.card_id
               where e.list_id = r.list_id and e.board = 'main' and e.qty > 0) d));
  end if;
  return t1_private.ranking_json(r, v_uid) || jsonb_build_object('log', r.screens, 'changes', r.changes, 'cube', v_cube);
end $$;

-- Cubes other people own that the caller can see and rank: their friends' and the people they've played with (as
-- the trade matcher reads people), by owner then name. Nobody else's are listed
-- (a public cube of a stranger is reached through their profile).
create or replace function public.rankable_cubes()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'owner', t1_private.person_json(c.user_id), 'cards', c.cards,
                                        'rankings', c.rankings, 'mine', c.mine)
                     order by lower(c.owner_name), lower(c.name), c.id)
      from (select l.id, l.name, l.user_id, pr.display_name owner_name,
                   (select count(distinct cd.oracle_id)::int from public.card_list_entries e join public.cards cd on cd.id = e.card_id
                     where e.list_id = l.id and e.board = 'main' and e.qty > 0) cards,
                   (select count(*)::int from public.cube_rankings r where r.list_id = l.id and t1_private.ranking_seen(r, v_uid)) rankings,
                   (select count(*)::int from public.cube_rankings r where r.list_id = l.id and r.user_id = v_uid) mine
              from public.card_lists l
              join public.profiles pr on pr.id = l.user_id
             where l.kind = 'cube' and l.deleted_at is null and l.user_id <> v_uid
               and l.user_id in (select case when f.user_lo = v_uid then f.user_hi else f.user_lo end
                                   from public.friendships f
                                  where f.status = 'accepted' and (f.user_lo = v_uid or f.user_hi = v_uid)
                                 union
                                 select pw.user_id from t1_private.played_with(v_uid) pw)
               and t1_private.cube_seen(l.id, v_uid)
             limit 300) c), '[]'::jsonb);
end $$;

-- ==================================================================== c_cleanup
-- Deleting a cube (a tombstone) deletes every ranking of it.
create or replace function t1_private.cube_rankings_gone()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.deleted_at is not null and old.deleted_at is null and new.kind = 'cube' then
    delete from public.cube_rankings where list_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists card_lists_rankings_gone on public.card_lists;
create trigger card_lists_rankings_gone after update of deleted_at on public.card_lists
  for each row execute function t1_private.cube_rankings_gone();

-- ==================================================================== d_moderation
-- A ranking's name reaches someone else when it's shared with the cube and the cube reaches anyone but its maker: a
-- cube someone else owns always does (its owner); the maker's own cube when it's shared.
create or replace function t1_private.ranking_name_visible(r public.cube_rankings)
returns boolean language sql stable security definer set search_path = '' as $$
  select r.sharing = 'cube' and exists (select 1 from public.card_lists l where l.id = r.list_id and l.deleted_at is null
                                         and (l.user_id <> r.user_id or t1_private.item_visible('list', l.id)));
$$;

alter table public.moderation_checks drop constraint if exists moderation_checks_subject_kind_check;
alter table public.moderation_checks add constraint moderation_checks_subject_kind_check
  check (subject_kind in ('display_name', 'handle', 'avatar', 'list_name', 'binder_name', 'event_name', 'guest_name',
                          'deck_photo', 'deck_photo_note', 'ranking_name'));

create or replace function t1_private.mod_rankings_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if current_setting('t1.moderating', true) = 'on' then return null; end if;
  if (tg_op = 'INSERT' or new.name is distinct from old.name or new.sharing is distinct from old.sharing)
     and t1_private.ranking_name_visible(new) then
    perform t1_private.moderation_enqueue('ranking_name', new.id, new.user_id, new.name, null);
  end if;
  return null;
end $$;
drop trigger if exists cube_rankings_moderation on public.cube_rankings;
create trigger cube_rankings_moderation after insert or update of name, sharing on public.cube_rankings
  for each row execute function t1_private.mod_rankings_trg();

-- Sharing opened up: the names that now reach someone get checked (adds rankings to the 2026-10-18 sweep).
create or replace function t1_private.moderation_sweep_user(p_uid uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_n integer := 0; r record;
begin
  for r in select 'list_name' k, l.id, l.name from public.card_lists l
            where l.user_id = p_uid and l.deleted_at is null and t1_private.item_visible('list', l.id)
           union all
           select 'binder_name', b.id, b.name from public.binders b
            where b.user_id = p_uid and b.deleted_at is null and t1_private.item_visible('binder', b.id)
           union all
           select 'ranking_name', x.id, x.name from public.cube_rankings x
            where x.user_id = p_uid and t1_private.ranking_name_visible(x) loop
    perform t1_private.moderation_enqueue(r.k, r.id, p_uid, r.name, null, 'sweep');
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- The 2026-10-18 enforce and revert, unchanged but for a shared ranking's name: its action is 'unshare' (the
-- ranking goes private) and a revert shares it with the cube again.
create or replace function t1_private.moderation_enforce(p_check_id bigint, p_auto boolean default true, p_by uuid default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  c public.moderation_checks;
  v_action text;
  v_label text;
  v_before jsonb;
  v_replaced jsonb;
  v_owner uuid;
  v_id bigint;
  v_cur text;
  v_event uuid;
begin
  select * into c from public.moderation_checks where id = p_check_id;
  if c.id is null then return null; end if;
  -- Already acted on this check.
  select id into v_id from public.moderation_actions where check_id = c.id and reverted_at is null;
  if v_id is not null then return v_id; end if;
  perform set_config('t1.moderating', 'on', true);
  v_owner := c.owner;

  if c.subject_kind = 'display_name' then
    select display_name into v_cur from public.profiles where id = c.subject_id;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'reset_name'; v_label := 'Your display name';
    v_before := jsonb_build_object('display_name', v_cur);
    v_replaced := jsonb_build_object('display_name', 'Player ' || upper(right(replace(c.subject_id::text, '-', ''), 4)));
    update public.profiles set display_name = v_replaced->>'display_name', updated_at = now() where id = c.subject_id;
    update public.participants set display_name = v_replaced->>'display_name' where user_id = c.subject_id and display_name = v_cur;
  elsif c.subject_kind = 'handle' then
    select handle into v_cur from public.profiles where id = c.subject_id;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'clear_handle'; v_label := 'Your handle';
    v_before := jsonb_build_object('handle', v_cur);
    v_replaced := jsonb_build_object('handle', null);
    update public.profiles set handle = null, updated_at = now() where id = c.subject_id;
  elsif c.subject_kind = 'avatar' then
    select avatar_url into v_cur from public.profiles where id = c.subject_id;
    if v_cur is distinct from c.path then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'remove_avatar'; v_label := 'Your profile photo';
    v_before := jsonb_build_object('avatar_url', v_cur);
    v_replaced := jsonb_build_object('avatar_url', null);
    update public.profiles set avatar_url = null, updated_at = now() where id = c.subject_id;
  elsif c.subject_kind = 'list_name' then
    select name, kind into v_cur, v_label from public.card_lists where id = c.subject_id and deleted_at is null;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'unshare';
    v_label := initcap(v_label) || ' ' || v_cur;
    select jsonb_build_object('visibility', visibility) into v_before from public.card_lists where id = c.subject_id;
    v_replaced := jsonb_build_object('visibility', 'private');
    update public.card_lists set visibility = 'private' where id = c.subject_id;
  elsif c.subject_kind = 'ranking_name' then
    select name into v_cur from public.cube_rankings where id = c.subject_id;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'unshare'; v_label := 'Ranking ' || v_cur;
    select jsonb_build_object('sharing', sharing) into v_before from public.cube_rankings where id = c.subject_id;
    v_replaced := jsonb_build_object('sharing', 'private');
    update public.cube_rankings set sharing = 'private' where id = c.subject_id;
  elsif c.subject_kind = 'binder_name' then
    select name into v_cur from public.binders where id = c.subject_id and deleted_at is null;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'unshare'; v_label := 'Binder ' || v_cur;
    select jsonb_build_object('visibility', visibility) into v_before from public.binders where id = c.subject_id;
    v_replaced := jsonb_build_object('visibility', 'private');
    update public.binders set visibility = 'private' where id = c.subject_id;
  elsif c.subject_kind = 'event_name' then
    select name into v_cur from public.events where id = c.subject_id;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'rename_event'; v_label := 'Event ' || v_cur;
    v_before := jsonb_build_object('name', v_cur);
    v_replaced := jsonb_build_object('name', 'Event ' || (select short_code from public.events where id = c.subject_id));
    update public.events set name = v_replaced->>'name', updated_at = now() where id = c.subject_id;
    insert into public.audit_log (event_id, actor_label, action, target_type, target_id, reason, before, after)
    values (c.subject_id, 'Table 1 moderation', 'moderation.renamed', 'event', c.subject_id, c.category, v_before, v_replaced);
  elsif c.subject_kind = 'guest_name' then
    select display_name, event_id into v_cur, v_event from public.participants where id = c.subject_id;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'rename_guest'; v_label := 'Guest ' || v_cur;
    v_before := jsonb_build_object('display_name', v_cur);
    v_replaced := jsonb_build_object('display_name', 'Guest ' || coalesce((select seat::text from public.participants where id = c.subject_id), ''));
    update public.participants set display_name = v_replaced->>'display_name' where id = c.subject_id;
    insert into public.audit_log (event_id, actor_label, action, target_type, target_id, reason, before, after)
    values (v_event, 'Table 1 moderation', 'moderation.renamed', 'participant', c.subject_id, c.category, v_before, v_replaced);
  elsif c.subject_kind = 'deck_photo' then
    if not exists (select 1 from public.event_deck_photos where id = c.subject_id and path = c.path and hidden_at is null) then
      perform set_config('t1.moderating', '', true); return null;
    end if;
    v_action := 'hide_photo'; v_label := 'Your deck photo';
    v_before := jsonb_build_object('hidden_at', null);
    v_replaced := jsonb_build_object('hidden_at', now());
    update public.event_deck_photos set hidden_at = now() where id = c.subject_id;
  elsif c.subject_kind = 'deck_photo_note' then
    select note into v_cur from public.event_deck_photos where id = c.subject_id;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'clear_note'; v_label := 'Your deck photo note';
    v_before := jsonb_build_object('note', v_cur);
    v_replaced := jsonb_build_object('note', '');
    update public.event_deck_photos set note = '', updated_at = now() where id = c.subject_id;
  else
    perform set_config('t1.moderating', '', true);
    return null;
  end if;

  insert into public.moderation_actions (check_id, owner, subject_kind, subject_id, action, category, label, before, replaced, auto, by_user)
  values (c.id, v_owner, c.subject_kind, c.subject_id, v_action, c.category, v_label, v_before, v_replaced, p_auto, p_by)
  returning id into v_id;
  if v_owner is not null then
    perform public.enqueue_notification('moderation.notice', null, array[v_owner],
      jsonb_build_object('label', v_label, 'action', v_action, 'action_id', v_id));
  end if;
  perform set_config('t1.moderating', '', true);
  return v_id;
end $$;

create or replace function t1_private.moderation_revert(p_action_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare a public.moderation_actions;
begin
  select * into a from public.moderation_actions where id = p_action_id for update;
  if a.id is null or a.reverted_at is not null then return; end if;
  perform set_config('t1.moderating', 'on', true);
  if a.action = 'reset_name' then
    update public.profiles set display_name = a.before->>'display_name', updated_at = now()
     where id = a.subject_id and display_name = a.replaced->>'display_name';
    update public.participants set display_name = a.before->>'display_name'
     where user_id = a.subject_id and display_name = a.replaced->>'display_name';
  elsif a.action = 'clear_handle' then
    update public.profiles set handle = a.before->>'handle', updated_at = now() where id = a.subject_id and handle is null
       and not exists (select 1 from public.profiles x where x.handle = a.before->>'handle');
  elsif a.action = 'remove_avatar' then
    update public.profiles set avatar_url = a.before->>'avatar_url', updated_at = now() where id = a.subject_id and avatar_url is null;
  elsif a.action = 'unshare' and a.subject_kind = 'list_name' then
    update public.card_lists set visibility = a.before->>'visibility' where id = a.subject_id and visibility = 'private';
  elsif a.action = 'unshare' and a.subject_kind = 'ranking_name' then
    update public.cube_rankings set sharing = a.before->>'sharing' where id = a.subject_id and sharing = 'private';
  elsif a.action = 'unshare' then
    update public.binders set visibility = a.before->>'visibility' where id = a.subject_id and visibility = 'private';
  elsif a.action = 'rename_event' then
    update public.events set name = a.before->>'name', updated_at = now() where id = a.subject_id and name = a.replaced->>'name';
    insert into public.audit_log (event_id, actor_label, action, target_type, target_id, before, after)
    values (a.subject_id, 'Table 1 moderation', 'moderation.restored', 'event', a.subject_id, a.replaced, a.before);
  elsif a.action = 'rename_guest' then
    update public.participants set display_name = a.before->>'display_name'
     where id = a.subject_id and display_name = a.replaced->>'display_name';
  elsif a.action = 'hide_photo' then
    update public.event_deck_photos set hidden_at = null where id = a.subject_id;
  elsif a.action = 'clear_note' then
    update public.event_deck_photos set note = a.before->>'note', updated_at = now() where id = a.subject_id and note = '';
  end if;
  update public.moderation_actions set reverted_at = now() where id = a.id;
  perform set_config('t1.moderating', '', true);
end $$;

revoke execute on function t1_private.cube_seen(uuid, uuid) from public;
revoke execute on function t1_private.ranking_seen(public.cube_rankings, uuid) from public;
revoke execute on function t1_private.ranking_json(public.cube_rankings, uuid) from public;
revoke execute on function t1_private.cube_json(uuid, uuid) from public;
revoke execute on function t1_private.cube_rankings_gone() from public;
revoke execute on function t1_private.ranking_name_visible(public.cube_rankings) from public;
revoke execute on function t1_private.mod_rankings_trg() from public;
do $$
declare f text;
begin
  foreach f in array array['cube_ranking_create(uuid, uuid, text, text, integer, text)',
                           'cube_ranking_update(uuid, text, text, integer, text)',
                           'cube_ranking_push(uuid, integer, integer, jsonb, integer, integer, integer, uuid, jsonb)',
                           'cube_ranking_delete(uuid)', 'cube_rankings(uuid)', 'cube_ranking_get(uuid)', 'rankable_cubes()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
