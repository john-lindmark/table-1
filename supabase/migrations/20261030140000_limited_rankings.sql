-- Rank a Limited set from Insights (John, 2026-10-30; contract/cube-rankings-2026-10-21.md § Sets). A ranking ranks a
-- cube (list_id, as before) or a Limited subject (set_key): a Scryfall set by its code (FRA) or one version of an Arena
-- cube (PWR-2510, 20261030140000_limited_cube_versions.sql). Set rankings use the same log, engine, saving and screens:
-- cube_ranking_get returns the subject in `cube` (id "set:<key>") with `set` and `kind` and its cards, so the clients' ranker works as is.
--  - What is ranked: the set's English printings, one per card (Oracle id), basic lands, tokens and art cards left out,
--    each drawn as its lowest collector number in the set (the regular frame). A cube version ranks the cards 17Lands
--    lists for it. Cards Scryfall adds later (spoilers) join like cards added to a cube: they wait outside the lists.
--  - Who sees one: its maker, and (sharing 'cube', shown as "Shared with friends") their friends. Everyone can see a
--    set, so "shared with the set" would have meant everyone on Table 1.
--  - cube_rankings(p_list_id, p_set, p_sets): one cube's, one set's (p_set), or all of yours; your set rankings are in
--    that last list only with p_sets (builds before this one would try to open a set ranking's cube).
--  - limited_rankable(): the sets and cube versions you can rank (recent and upcoming sets with cards in the catalog),
--    with your and your friends' rankings of each.
-- Replaces t1_private.ranking_seen, t1_private.ranking_json, t1_private.ranking_name_visible (20261021120000),
-- public.cube_ranking_create (20261022190000; gains p_set), public.cube_rankings (20261021120000; gains p_set, p_sets),
-- public.cube_ranking_get and public.cube_ranking_catch_up (20261022160000).

alter table public.cube_rankings alter column list_id drop not null;
alter table public.cube_rankings add column if not exists set_key text;
alter table public.cube_rankings drop constraint if exists cube_rankings_subject_check;
alter table public.cube_rankings add constraint cube_rankings_subject_check
  check ((list_id is null) <> (set_key is null) and (set_key is null or set_key ~ '^[A-Z0-9]{2,8}(-[0-9]{4})?$'));
create index if not exists cube_rankings_set_idx on public.cube_rankings (set_key, updated_at desc) where set_key is not null;
-- A set's printings (the ranker's cards, limited_rankable's counts); the catalog had no index by set.
create index if not exists cards_set_idx on public.cards (set_code, lang);

-- ==================================================================== a_subjects
-- Set types a Limited subject can be (as limited_candidates).
create or replace function t1_private.limited_set_ok(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.mtg_sets s
                  where s.code = lower(p_key) and not s.digital
                    and s.set_type in ('expansion', 'core', 'draft_innovation', 'masters', 'remastered'));
$$;

-- A set's cards: one English printing per card, the lowest collector number, no basics, tokens or art cards.
create or replace function t1_private.limited_set_printings(p_key text)
returns table (oracle_id uuid, card_id uuid) language sql stable security definer set search_path = '' as $$
  select distinct on (c.oracle_id) c.oracle_id, c.id
    from public.cards c join public.card_oracles o on o.oracle_id = c.oracle_id
   where c.set_code = lower(p_key) and c.lang = 'en'
     and o.layout not in ('token', 'double_faced_token', 'emblem', 'art_series')
     and not (coalesce(o.type_line, '') ~* '\mbasic\M' and coalesce(o.type_line, '') ~* '\mland\M')
   order by c.oracle_id, (c.collector_number ~ '^[0-9]+$') desc,
            nullif(regexp_replace(c.collector_number, '[^0-9]', '', 'g'), '')::bigint nulls last, c.id;
$$;

-- The subject's cards (sorted Oracle ids as text) and, for a set, the printing each is drawn in.
create or replace function t1_private.limited_subject_cards(p_key text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_cards uuid[] := (select cards from t1_private.limited_cube_versions where key = upper(p_key));
begin
  if v_cards is not null then
    return jsonb_build_object('cards', coalesce((select jsonb_agg(x order by x) from (select distinct c::text x from unnest(v_cards) c) d), '[]'::jsonb),
                              'printings', '{}'::jsonb);
  end if;
  return (select jsonb_build_object('cards', coalesce(jsonb_agg(p.oracle_id::text order by p.oracle_id::text), '[]'::jsonb),
                                    'printings', coalesce(jsonb_object_agg(p.oracle_id::text, p.card_id::text), '{}'::jsonb))
            from t1_private.limited_set_printings(p_key) p);
end $$;

-- How a subject reads in a ranking: {id: "set:<key>", set, kind: set | cube, name, released, mine: false, owner: null,
-- can_see}. The id is a string like a cube's (clients decode it as one) that no list id can be.
create or replace function t1_private.set_subject_json(p_key text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := (select jsonb_build_object('id', 'set:' || v.key, 'set', v.key, 'kind', 'cube', 'name', v.name, 'released', v.started::text,
                                            'mine', false, 'owner', null, 'can_see', true)
                     from t1_private.limited_cube_versions v where v.key = upper(p_key));
begin
  if v is not null then return v; end if;
  return (select jsonb_build_object('id', 'set:' || upper(s.code), 'set', upper(s.code), 'kind', 'set', 'name', s.name, 'released', s.released_at::text,
                                    'mine', false, 'owner', null, 'can_see', true)
            from public.mtg_sets s where s.code = lower(p_key));
end $$;

-- A subject someone may start a ranking of: a cube version, or a draftable paper set.
create or replace function t1_private.limited_subject_ok(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(p_key ~ '^[A-Z0-9]{2,8}(-[0-9]{4})?$', false)
     and (exists (select 1 from t1_private.limited_cube_versions where key = p_key)
          or (p_key !~ '-' and t1_private.limited_set_ok(p_key)));
$$;

-- ==================================================================== b_helpers
-- A ranking the viewer may see: their own; a cube's when shared with the cube's audience (as before); a set's when
-- shared with friends. Always by a live, unrestricted account across no block.
create or replace function t1_private.ranking_seen(r public.cube_rankings, p_viewer uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_viewer is not null and (r.user_id = p_viewer
    or (r.sharing = 'cube' and t1_private.live_account(r.user_id) and not t1_private.is_restricted(r.user_id)
        and case when r.set_key is not null then t1_private.share_level(r.user_id, p_viewer) >= 1
                 else t1_private.share_level(r.user_id, p_viewer) >= 0 and t1_private.cube_seen(r.list_id, p_viewer) end));
$$;

create or replace function t1_private.ranking_json(r public.cube_rankings, p_viewer uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', r.id, 'list_id', r.list_id, 'set_key', r.set_key, 'name', r.name, 'depth', r.depth,
           'top', r.top_size, 'sharing', r.sharing, 'screens', r.screen_count, 'rev', r.rev, 'sorted', r.sorted,
           'categories', r.categories, 'ranked', r.ranked, 'created_at', r.created_at, 'updated_at', r.updated_at,
           'mine', r.user_id = p_viewer, 'by', t1_private.person_json(r.user_id));
$$;

-- The subject a ranking ranks, as cube_rankings / cube_ranking_get return it.
create or replace function t1_private.ranking_subject_json(r public.cube_rankings, p_viewer uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when r.set_key is not null then t1_private.set_subject_json(r.set_key) else t1_private.cube_json(r.list_id, p_viewer) end;
$$;

-- The subject's cards now, as a baseline.
create or replace function t1_private.ranking_cards(r public.cube_rankings)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when r.set_key is not null then t1_private.limited_subject_cards(r.set_key)->'cards' else t1_private.cube_cards(r.list_id) end;
$$;

-- A set ranking's name reaches others whenever it's shared (its maker's friends); a cube ranking's as before.
create or replace function t1_private.ranking_name_visible(r public.cube_rankings)
returns boolean language sql stable security definer set search_path = '' as $$
  select r.sharing = 'cube' and (r.set_key is not null
    or exists (select 1 from public.card_lists l where l.id = r.list_id and l.deleted_at is null
                and (l.user_id <> r.user_id or t1_private.item_visible('list', l.id))));
$$;

-- ==================================================================== c_rpcs
drop function if exists public.cube_ranking_create(uuid, uuid, text, text, integer, text);
-- Starts a ranking of a cube the caller can see, or of a Limited set (p_set). The id is the client's, so a retry
-- returns the same ranking.
create or replace function public.cube_ranking_create(
  p_id uuid, p_list_id uuid default null, p_name text default null, p_depth text default 'half', p_top integer default 100,
  p_sharing text default 'cube', p_set text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_name text := left(coalesce(nullif(btrim(p_name), ''), 'My ranking'), 60);
  v_set text := nullif(upper(btrim(p_set)), '');
  r public.cube_rankings;
begin
  if v_uid is null then raise exception 'Sign in to rank a cube' using errcode = '28000'; end if;
  if p_id is null or (p_list_id is null) = (v_set is null) then raise exception 'Say which cube or set to rank' using errcode = '22023'; end if;
  select * into r from public.cube_rankings where id = p_id;
  if r.id is not null then
    if r.user_id <> v_uid then raise exception 'That''s private' using errcode = '42501'; end if;
    return t1_private.ranking_json(r, v_uid);
  end if;
  if v_set is not null then
    if not t1_private.limited_subject_ok(v_set) then raise exception 'There''s no set to rank by that name' using errcode = '22023'; end if;
  elsif not t1_private.cube_seen(p_list_id, v_uid) then raise exception 'That''s private' using errcode = '42501';
  end if;
  if coalesce(p_depth, '') not in ('quarter', 'third', 'half', 'full') then raise exception 'Sort the top quarter, third or half, or every card' using errcode = '22023'; end if;
  if coalesce(p_top, 0) not in (50, 100) then raise exception 'The final is a top 50 or a top 100' using errcode = '22023'; end if;
  if coalesce(p_sharing, '') not in ('cube', 'private') then raise exception 'Unknown sharing' using errcode = '22023'; end if;
  if (select count(*) from public.cube_rankings where user_id = v_uid) >= 200 then
    raise exception 'At most 200 rankings: delete one first' using errcode = '22023';
  end if;
  insert into public.cube_rankings (id, user_id, list_id, set_key, name, depth, top_size, sharing, baseline)
  values (p_id, v_uid, p_list_id, v_set, v_name, p_depth, p_top, p_sharing,
          case when v_set is not null then t1_private.limited_subject_cards(v_set)->'cards' else t1_private.cube_cards(p_list_id) end)
  returning * into r;
  perform t1_private.ranking_tell_owner(r);
  return t1_private.ranking_json(r, v_uid);
end $$;

drop function if exists public.cube_rankings(uuid);
-- The rankings of one cube the caller can see, or of one set (p_set), theirs first, then the newest; or with neither
-- every ranking of the caller's own (their set rankings too with p_sets). Each row of the last says what it ranks.
create or replace function public.cube_rankings(p_list_id uuid default null, p_set text default null, p_sets boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_set text := nullif(upper(btrim(p_set)), '');
  v_rows jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if v_set is not null then
    if not t1_private.limited_subject_ok(v_set) then raise exception 'There''s no set to rank by that name' using errcode = '22023'; end if;
    select coalesce(jsonb_agg(t1_private.ranking_json(r, v_uid) order by r.user_id <> v_uid, r.updated_at desc, r.id), '[]'::jsonb)
      into v_rows
      from (select r.* from public.cube_rankings r
             where r.set_key = v_set and t1_private.ranking_seen(r, v_uid)
             order by r.user_id <> v_uid, r.updated_at desc, r.id limit 300) r;
    return jsonb_build_object('cube', t1_private.set_subject_json(v_set), 'can_rank', true, 'rankings', v_rows);
  end if;
  if p_list_id is null then
    select coalesce(jsonb_agg(t1_private.ranking_json(r, v_uid)
                                || jsonb_build_object('cube', t1_private.ranking_subject_json(r, v_uid))
                              order by r.updated_at desc, r.id), '[]'::jsonb) into v_rows
      from public.cube_rankings r
     where r.user_id = v_uid
       and (exists (select 1 from public.card_lists l where l.id = r.list_id and l.deleted_at is null)
            or (p_sets and r.set_key is not null));
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

-- The ranking has caught up with its cube or set (as 20261022160000).
create or replace function public.cube_ranking_catch_up(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  r public.cube_rankings;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into r from public.cube_rankings where id = p_id for update;
  if r.id is null or r.user_id <> v_uid then raise exception 'That''s private' using errcode = '42501'; end if;
  update public.cube_rankings set baseline = t1_private.ranking_cards(r), updated_at = now()
   where id = p_id returning * into r;
  return t1_private.ranking_json(r, v_uid) || jsonb_build_object('baseline', r.baseline);
end $$;

-- One ranking with its log, change log, baseline and its subject's cards: a cube's main board and the printing it holds
-- of each (when the caller can see the cube), or a set's cards and the printing each is drawn in.
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
  if r.set_key is not null then
    v_cube := coalesce(t1_private.set_subject_json(r.set_key), jsonb_build_object('id', 'set:' || r.set_key, 'set', r.set_key, 'name', r.set_key,
                                                                                  'mine', false, 'can_see', true))
              || t1_private.limited_subject_cards(r.set_key);
  else
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
  end if;
  return t1_private.ranking_json(r, v_uid) || jsonb_build_object('log', r.screens, 'changes', r.changes, 'cube', v_cube,
                                                                 'baseline', coalesce(r.baseline, '[]'::jsonb));
end $$;

-- Sets and cube versions to rank, newest first: paper sets from the last 400 days and the next 45 with at least 60 cards
-- in the catalog, and every Arena cube version 17Lands has shown. `pack`: Insights has its 17Lands numbers; `mine`:
-- your rankings of it; `rankings`: the ones you can see (yours and your friends').
create or replace function public.limited_rankable()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  with subj as (
    select upper(s.code) k, s.name, s.released_at released, 'set'::text kind,
           (select count(*) from t1_private.limited_set_printings(s.code))::int n
      from public.mtg_sets s
     where not s.digital and s.set_type in ('expansion', 'core', 'draft_innovation', 'masters', 'remastered')
       and s.released_at between current_date - 400 and current_date + 45
       and exists (select 1 from public.cards c where c.set_code = s.code and c.lang = 'en')
    union all
    select v.key, v.name, v.started, 'cube', cardinality(v.cards)
      from t1_private.limited_cube_versions v where cardinality(v.cards) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object('key', s.k, 'name', s.name, 'released', s.released::text, 'kind', s.kind,
                                               'cards', s.n, 'pack', p.key is not null,
                                               'mine', (select count(*) from public.cube_rankings r where r.set_key = s.k and r.user_id = v_uid),
                                               'rankings', (select count(*) from public.cube_rankings r where r.set_key = s.k and t1_private.ranking_seen(r, v_uid)))
                            order by s.released desc, s.k), '[]'::jsonb) into v
    from subj s left join t1_private.insight_packs p on p.kind = 'limited' and p.key = s.k
   where s.kind = 'cube' or s.n >= 60;
  return v;
end $$;

revoke execute on function t1_private.limited_set_ok(text) from public;
revoke execute on function t1_private.limited_set_printings(text) from public;
revoke execute on function t1_private.limited_subject_cards(text) from public;
revoke execute on function t1_private.set_subject_json(text) from public;
revoke execute on function t1_private.limited_subject_ok(text) from public;
revoke execute on function t1_private.ranking_subject_json(public.cube_rankings, uuid) from public;
revoke execute on function t1_private.ranking_cards(public.cube_rankings) from public;
do $$
declare f text;
begin
  foreach f in array array['cube_ranking_create(uuid, uuid, text, text, integer, text, text)',
                           'cube_rankings(uuid, text, boolean)', 'cube_ranking_get(uuid)', 'cube_ranking_catch_up(uuid)',
                           'limited_rankable()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
