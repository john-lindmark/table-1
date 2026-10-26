-- Following decks, cubes and binders (contract/follows-2026-10-25.md): follow someone else's binder, deck or cube
-- that you can see (on their profile, or through a link you opened) and get one push when they've finished a round
-- of changes. A change stamps the followed item; t1_private.follow_digest (pg_cron, every 5 minutes) sends an item
-- once it has been quiet for 30 minutes and at most every 6 hours, as the net difference from the last update.
-- A follow lasts only while you can still see the item: it's checked again at every push and every read.
-- Also (contract § Trade wants): when a friend puts cards you want into their for-trade binders, one push per round
-- (quiet 30 minutes, at most one per friend every 12 hours), from t1_private.trade_want_digest.

-- ==================================================================== a_tables
-- One row per followed item: what followers were last told (snapshot), and when changes started and stopped.
create table if not exists t1_private.follow_items (
  item_id uuid primary key,
  kind text not null check (kind in ('binder', 'deck', 'cube')),
  owner uuid not null,
  snapshot jsonb not null,                      -- {"<board>:<card_id>": qty}; binders have no board (":<card_id>")
  announced_at timestamptz,                     -- the last update; null = none yet
  dirty_first timestamptz,                      -- changed since the last update: the first and latest change
  dirty_last timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists follow_items_dirty_idx on t1_private.follow_items (dirty_last) where dirty_last is not null;
create index if not exists follow_items_owner_idx on t1_private.follow_items (owner);

create table if not exists public.follows (
  user_id uuid not null references auth.users (id) on delete cascade,
  item_id uuid not null references t1_private.follow_items (item_id) on delete cascade,
  kind text not null check (kind in ('binder', 'deck', 'cube')),
  push boolean not null default true,
  link_id bigint references public.share_links (id) on delete set null,   -- followed through this link
  followed_at timestamptz not null default now(),
  seen_at timestamptz not null default now(),
  primary key (user_id, item_id)
);
create index if not exists follows_item_idx on public.follows (item_id);
alter table public.follows enable row level security;
-- No policy: read and written only through the RPCs below.
revoke all on public.follows from anon, authenticated;

-- What changed in one update: [[card_id, board | null, delta], ...], added first.
create table if not exists t1_private.follow_updates (
  id bigint generated always as identity primary key,
  item_id uuid not null references t1_private.follow_items (item_id) on delete cascade,
  at timestamptz not null default now(),
  added integer not null,
  removed integer not null,
  cards jsonb not null
);
create index if not exists follow_updates_item_idx on t1_private.follow_updates (item_id, at desc);
create index if not exists follow_updates_at_idx on t1_private.follow_updates (at);

-- ==================================================================== b_helpers
-- How an item reaches a viewer: 'profile' (its setting, capped by the profile), 'link' (the live link they
-- followed through, whose name moderation hasn't unshared), or null. Never their own, a deleted or demo owner's,
-- a deleted item, or across a block.
create or replace function t1_private.follow_reach(p_viewer uuid, p_kind text, p_id uuid, p_link bigint)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  v_owner uuid;
  v_vis text;
  v_name text;
  v_level integer;
  s public.share_settings;
begin
  if p_kind = 'binder' then
    select b.user_id, b.visibility, b.name into v_owner, v_vis, v_name
      from public.binders b where b.id = p_id and b.deleted_at is null;
  elsif p_kind in ('deck', 'cube') then
    select l.user_id, l.visibility, l.name into v_owner, v_vis, v_name
      from public.card_lists l where l.id = p_id and l.kind = p_kind and l.deleted_at is null;
  end if;
  if v_owner is null or p_viewer is null or v_owner = p_viewer
     or not exists (select 1 from public.profiles pr where pr.id = v_owner and pr.deleted_at is null and not pr.is_demo) then
    return null;
  end if;
  v_level := t1_private.share_level(v_owner, p_viewer);
  if v_level < 0 then return null; end if;
  s := t1_private.share_of(v_owner);
  if t1_private.vis_ok(v_level, s.profile,
       coalesce(v_vis, case p_kind when 'binder' then s.binders when 'deck' then s.decks else s.cubes end, s.library)) then
    return 'profile';
  end if;
  if p_link is not null
     and exists (select 1 from public.share_links k where k.id = p_link and k.item_id = p_id and k.revoked_at is null)
     and not exists (select 1 from public.moderation_actions a join public.moderation_checks c on c.id = a.check_id
                      where a.subject_id = p_id and a.action = 'unshare' and a.reverted_at is null and c.content = v_name) then
    return 'link';
  end if;
  return null;
end $$;

-- The item's cards as followers compare them: decks and cubes by section and card (Considering left out), binders
-- by printing.
create or replace function t1_private.follow_snapshot(p_kind text, p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(x.k, x.n), '{}'::jsonb) from (
    select e.board || ':' || e.card_id::text k, sum(e.qty)::int n from public.card_list_entries e
     where p_kind in ('deck', 'cube') and e.list_id = p_id and e.board <> 'maybe' and e.qty > 0
     group by 1
    union all
    select ':' || bi.card_id::text, sum(bi.qty)::int from public.binder_items bi
     where p_kind = 'binder' and bi.binder_id = p_id and bi.qty > 0
     group by bi.card_id
  ) x;
$$;

-- New minus old: [[card_id, board | null, delta], ...], additions first, then the biggest moves. (A join, not a
-- lookup per key: each ->> on a stored snapshot would read it again.)
create or replace function t1_private.follow_diff(p_old jsonb, p_new jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_array(split_part(x.k, ':', 2), nullif(split_part(x.k, ':', 1), ''), x.d)
                            order by x.d < 0, abs(x.d) desc, x.k), '[]'::jsonb)
    from (select coalesce(n.key, o.key) k, coalesce(n.value::int, 0) - coalesce(o.value::int, 0) d
            from jsonb_each_text(p_old) o full join jsonb_each_text(p_new) n on n.key = o.key) x
   where x.d <> 0;
$$;

-- Up to 3 card names from a diff, added (1) or taken out (-1), biggest moves first. One index lookup per card read:
-- the diff has no statistics, so a join would scan the catalog.
create or replace function t1_private.follow_names(p_cards jsonb, p_sign integer)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(n.name order by n.ord), '[]'::jsonb) from (
    select a.name, min(a.ord) ord from (
      select (select o.name from public.cards cd join public.card_oracles o on o.oracle_id = cd.oracle_id
               where cd.id = (t.c ->> 0)::uuid) name, t.ord
        from jsonb_array_elements(p_cards) with ordinality t(c, ord)
       where sign((t.c ->> 2)::int) = p_sign order by t.ord limit 12) a
     where a.name is not null group by a.name order by min(a.ord) limit 3) n;
$$;

-- The item's name and owner, if it's live.
create or replace function t1_private.follow_item(p_kind text, p_id uuid, out owner uuid, out name text)
language sql stable security definer set search_path = '' as $$
  select b.user_id, b.name from public.binders b where p_kind = 'binder' and b.id = p_id and b.deleted_at is null
  union all
  select l.user_id, l.name from public.card_lists l where p_kind in ('deck', 'cube') and l.id = p_id and l.kind = p_kind and l.deleted_at is null
  limit 1;
$$;

-- What the client shows about one follow (follow_get's shape).
create or replace function t1_private.follow_state(p_uid uuid, p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'following', fo.user_id is not null,
    'push', coalesce(fo.push, true),
    'unseen', case when ok then (select count(*) from t1_private.follow_updates u
                                  where u.item_id = p_id and u.at > fo.followed_at and u.at > fo.seen_at) else 0 end,
    'last_update', case when ok then (select jsonb_build_object('at', u.at, 'added', u.added, 'removed', u.removed)
                                        from t1_private.follow_updates u
                                       where u.item_id = p_id and u.at > fo.followed_at order by u.at desc limit 1) end)
  from (select 1) one
  left join public.follows fo on fo.user_id = p_uid and fo.item_id = p_id
  cross join lateral (select fo.user_id is not null
                         and t1_private.follow_reach(p_uid, fo.kind, p_id, fo.link_id) is not null ok) v;
$$;

-- ==================================================================== c_changes
-- Stamps followed items when their cards change (one statement-level update; items nobody follows cost nothing).
create or replace function t1_private.follow_dirty_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'card_list_entries' then
    if tg_op in ('INSERT', 'UPDATE') then
      update t1_private.follow_items f set dirty_first = coalesce(f.dirty_first, now()), dirty_last = now()
       where f.item_id in (select distinct n.list_id from new_rows n);
    end if;
    if tg_op in ('DELETE', 'UPDATE') then
      update t1_private.follow_items f set dirty_first = coalesce(f.dirty_first, now()), dirty_last = now()
       where f.item_id in (select distinct o.list_id from old_rows o);
    end if;
  else
    if tg_op in ('INSERT', 'UPDATE') then
      update t1_private.follow_items f set dirty_first = coalesce(f.dirty_first, now()), dirty_last = now()
       where f.item_id in (select distinct n.binder_id from new_rows n);
    end if;
    if tg_op in ('DELETE', 'UPDATE') then
      update t1_private.follow_items f set dirty_first = coalesce(f.dirty_first, now()), dirty_last = now()
       where f.item_id in (select distinct o.binder_id from old_rows o);
    end if;
  end if;
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['card_list_entries', 'binder_items'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_follow_ins', t);
    execute format('drop trigger if exists %I on public.%I', t || '_follow_upd', t);
    execute format('drop trigger if exists %I on public.%I', t || '_follow_del', t);
    execute format('create trigger %I after insert on public.%I referencing new table as new_rows
                    for each statement execute function t1_private.follow_dirty_trg()', t || '_follow_ins', t);
    execute format('create trigger %I after update on public.%I referencing old table as old_rows new table as new_rows
                    for each statement execute function t1_private.follow_dirty_trg()', t || '_follow_upd', t);
    execute format('create trigger %I after delete on public.%I referencing old table as old_rows
                    for each statement execute function t1_private.follow_dirty_trg()', t || '_follow_del', t);
  end loop;
end $$;

-- Sends what's due, oldest first and p_max a run (the cron job runs every 5 minutes): items quiet for p_quiet whose
-- last update is at least p_gap old. The net difference from the
-- snapshot becomes one update and one push to the followers with pushes on who can still see it. Returns updates made.
create or replace function t1_private.follow_digest(
  p_quiet interval default interval '30 minutes', p_gap interval default interval '6 hours', p_max integer default 200)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  f t1_private.follow_items;
  v_item record;
  v_now jsonb;
  v_cards jsonb;
  v_added integer;
  v_removed integer;
  v_users uuid[];
  v_n integer := 0;
begin
  for f in select * from t1_private.follow_items i
            where i.dirty_last is not null and i.dirty_last <= now() - p_quiet
              and (i.announced_at is null or i.announced_at <= now() - p_gap)
            order by i.dirty_first limit p_max
              for update skip locked loop
    update t1_private.follow_items set dirty_first = null, dirty_last = null where item_id = f.item_id;
    select * into v_item from t1_private.follow_item(f.kind, f.item_id);
    if v_item.owner is null then continue; end if;
    v_now := t1_private.follow_snapshot(f.kind, f.item_id);
    v_cards := t1_private.follow_diff(f.snapshot, v_now);
    if jsonb_array_length(v_cards) = 0 then continue; end if;
    select coalesce(sum((c ->> 2)::int) filter (where (c ->> 2)::int > 0), 0),
           coalesce(-sum((c ->> 2)::int) filter (where (c ->> 2)::int < 0), 0)
      into v_added, v_removed from jsonb_array_elements(v_cards) c;
    insert into t1_private.follow_updates (item_id, added, removed, cards) values (f.item_id, v_added, v_removed, v_cards);
    update t1_private.follow_items set snapshot = v_now, announced_at = now() where item_id = f.item_id;
    v_n := v_n + 1;

    select array_agg(fo.user_id) into v_users from public.follows fo
     where fo.item_id = f.item_id and fo.push and t1_private.follow_reach(fo.user_id, f.kind, f.item_id, fo.link_id) is not null;
    if v_users is null then continue; end if;
    perform public.enqueue_notification('follow.updated', null, v_users, jsonb_build_object(
      'kind', f.kind, 'item_id', f.item_id, 'name', v_item.name,
      'owner_name', (select pr.display_name from public.profiles pr where pr.id = v_item.owner),
      'added', v_added, 'removed', v_removed)
      || jsonb_build_object(
           'in', t1_private.follow_names(v_cards, 1), 'in_n', (select count(*) from jsonb_array_elements(v_cards) c where (c ->> 2)::int > 0),
           'out', t1_private.follow_names(v_cards, -1), 'out_n', (select count(*) from jsonb_array_elements(v_cards) c where (c ->> 2)::int < 0)));
  end loop;
  delete from t1_private.follow_updates where at < now() - interval '180 days';
  return v_n;
end $$;

-- Deleting your account: your follows go, and so do the rows for things you owned (their followers' rows with them).
create or replace function t1_private.follows_forget()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  with gone as (delete from public.follows where user_id = new.id returning item_id)
  delete from t1_private.follow_items i
   where i.item_id in (select item_id from gone)
     and not exists (select 1 from public.follows x where x.item_id = i.item_id and x.user_id <> new.id);
  delete from t1_private.follow_items where owner = new.id;
  return null;
end $$;
drop trigger if exists profiles_follows_forget on public.profiles;
create trigger profiles_follows_forget after update of deleted_at on public.profiles
  for each row when (old.deleted_at is null and new.deleted_at is not null)
  execute function t1_private.follows_forget();

-- ==================================================================== d_rpcs
-- Follow or unfollow; p_push turns pushes on/off (null = keep). p_token = the link you're looking through.
create or replace function public.follow_set(
  p_kind text, p_id uuid, p_follow boolean, p_push boolean default null, p_token text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  fo public.follows;
  v_item record;
  v_link bigint;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_kind is null or p_kind not in ('binder', 'deck', 'cube') or p_id is null or p_follow is null then
    raise exception 'Follow a binder, deck or cube' using errcode = '22023';
  end if;
  -- One change at a time per item, so the last unfollow and a new follow can't cross.
  perform pg_advisory_xact_lock(hashtextextended('follow:' || p_id::text, 0));
  select * into fo from public.follows where user_id = v_uid and item_id = p_id;

  if not p_follow then
    if fo.user_id is not null then
      delete from public.follows where user_id = v_uid and item_id = p_id;
      delete from t1_private.follow_items i where i.item_id = p_id and not exists (select 1 from public.follows x where x.item_id = p_id);
      perform t1_private.account_audit(v_uid, 'follow.set', null, jsonb_build_object('following', true),
        jsonb_build_object('kind', fo.kind, 'id', p_id, 'following', false));
    end if;
    return t1_private.follow_state(v_uid, p_id);
  end if;

  select * into v_item from t1_private.follow_item(p_kind, p_id);
  if v_item.owner = v_uid then raise exception 'That one is yours' using errcode = '22023'; end if;
  if p_token is not null then
    select k.id into v_link from public.share_links k
     where k.token = p_token and k.item_id = p_id and k.part = p_kind and k.revoked_at is null;
  end if;
  v_link := coalesce(v_link, fo.link_id);
  if t1_private.follow_reach(v_uid, p_kind, p_id, v_link) is null then
    raise exception 'That''s private' using errcode = '42501';
  end if;

  if fo.user_id is not null then
    if coalesce(p_push, fo.push) = fo.push and v_link is not distinct from fo.link_id then
      return t1_private.follow_state(v_uid, p_id);
    end if;
    update public.follows set push = coalesce(p_push, fo.push), link_id = v_link where user_id = v_uid and item_id = p_id;
    if coalesce(p_push, fo.push) <> fo.push then
      perform t1_private.account_audit(v_uid, 'follow.set', null, jsonb_build_object('push', fo.push),
        jsonb_build_object('kind', p_kind, 'id', p_id, 'push', p_push));
    end if;
    return t1_private.follow_state(v_uid, p_id);
  end if;

  perform t1_private.account_rate_limit(v_uid, 'follow.set', 100, interval '1 hour');
  if (select count(*) from public.follows where user_id = v_uid) >= 500 then
    raise exception 'You can follow up to 500: unfollow one first' using errcode = '53400';
  end if;
  insert into t1_private.follow_items (item_id, kind, owner, snapshot)
  values (p_id, p_kind, v_item.owner, t1_private.follow_snapshot(p_kind, p_id))
  on conflict (item_id) do nothing;
  insert into public.follows (user_id, item_id, kind, push, link_id)
  values (v_uid, p_id, p_kind, coalesce(p_push, true), v_link);
  perform t1_private.account_audit(v_uid, 'follow.set', null, null,
    jsonb_build_object('kind', p_kind, 'id', p_id, 'following', true, 'push', coalesce(p_push, true), 'link', v_link is not null));
  return t1_private.follow_state(v_uid, p_id);
end $$;

-- Whether you follow it, and its latest update. Never says whether something exists.
create or replace function public.follow_get(p_kind text, p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  return t1_private.follow_state(v_uid, p_id);
end $$;

-- Everything you follow, updated first. Items you can no longer see say only that.
create or replace function public.follows_list()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  return jsonb_build_object('items', coalesce((
    select jsonb_agg(x.j order by x.unseen > 0 desc, x.last_at desc nulls last, x.name nulls last, x.item_id)
      from (
        select f.item_id, f.unseen, f.last_at, it.name,
               case when f.reach is null then
                 jsonb_build_object('kind', f.kind, 'id', f.item_id, 'available', false, 'push', f.push,
                                    'followed_at', f.followed_at, 'unseen', 0)
               else jsonb_strip_nulls(jsonb_build_object(
                 'kind', f.kind, 'id', f.item_id, 'available', true, 'push', f.push, 'followed_at', f.followed_at,
                 'unseen', f.unseen, 'name', it.name, 'format', it.format, 'for_trade', it.for_trade, 'cards', it.cards,
                 'owner', (select jsonb_strip_nulls(jsonb_build_object('display_name', pr.display_name, 'avatar_url', pr.avatar_url))
                             from public.profiles pr where pr.id = it.owner),
                 'user_id', case when f.reach = 'profile' then it.owner end,
                 'token', case when f.reach = 'link' then (select k.token from public.share_links k where k.id = f.link_id) end,
                 'last_update', (select jsonb_build_object('at', u.at, 'added', u.added, 'removed', u.removed)
                                   from t1_private.follow_updates u
                                  where u.item_id = f.item_id and u.at > f.followed_at order by u.at desc limit 1)))
               end j
          from (select fo.*, r.reach,
                       case when r.reach is null then 0 else
                         (select count(*) from t1_private.follow_updates u
                           where u.item_id = fo.item_id and u.at > fo.followed_at and u.at > fo.seen_at) end unseen,
                       case when r.reach is null then null else
                         (select max(u.at) from t1_private.follow_updates u where u.item_id = fo.item_id and u.at > fo.followed_at) end last_at
                  from public.follows fo
                  cross join lateral (select t1_private.follow_reach(v_uid, fo.kind, fo.item_id, fo.link_id) reach) r
                 where fo.user_id = v_uid) f
          left join lateral (
            select b.user_id owner, b.name, null::text format, b.for_trade,
                   (select coalesce(sum(bi.qty), 0)::int from public.binder_items bi where bi.binder_id = b.id and bi.qty > 0) cards
              from public.binders b where f.reach is not null and f.kind = 'binder' and b.id = f.item_id
            union all
            select l.user_id, l.name, l.format, null::boolean,
                   (select coalesce(sum(e.qty), 0)::int from public.card_list_entries e where e.list_id = l.id and e.board <> 'maybe')
              from public.card_lists l where f.reach is not null and f.kind <> 'binder' and l.id = f.item_id
          ) it on true
      ) x), '[]'::jsonb));
end $$;

-- The updates since you followed, newest first; opening them marks them seen.
create or replace function public.follow_changes(p_kind text, p_id uuid, p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  fo public.follows;
  v_out jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into fo from public.follows where user_id = v_uid and item_id = p_id and kind = p_kind;
  if fo.user_id is null or t1_private.follow_reach(v_uid, p_kind, p_id, fo.link_id) is null then
    raise exception 'That''s private' using errcode = '42501';
  end if;
  select jsonb_build_object('kind', p_kind, 'id', p_id, 'name', (t1_private.follow_item(p_kind, p_id)).name,
           'updates', coalesce(jsonb_agg(jsonb_build_object('at', u.at, 'added', u.added, 'removed', u.removed, 'cards', u.cards)
                                         order by u.at desc), '[]'::jsonb))
    into v_out
    from (select * from t1_private.follow_updates u where u.item_id = p_id and u.at > fo.followed_at
           order by u.at desc limit least(greatest(coalesce(p_limit, 20), 1), 100)) u;
  update public.follows set seen_at = now() where user_id = v_uid and item_id = p_id and seen_at < now();
  return v_out;
end $$;

-- ==================================================================== g_trade_wants
-- Copies that went into (or out of) for-trade binders since the last run, net per binder, printing, finish and
-- condition. Removals stay so an add taken back cancels out; moves between trade binders net to zero.
create table if not exists t1_private.trade_adds (
  owner uuid not null,
  binder_id uuid not null,
  card_id uuid not null,
  finish text not null,
  condition text not null,
  qty integer not null,
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  primary key (owner, binder_id, card_id, finish, condition)
);

-- One push per (owner, friend) every 12 hours.
create table if not exists t1_private.trade_want_notices (
  owner uuid not null,
  wanter uuid not null,
  sent_at timestamptz not null default now(),
  primary key (owner, wanter)
);

create or replace function t1_private.trade_adds_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into t1_private.trade_adds as t (owner, binder_id, card_id, finish, condition, qty)
    select d.user_id, d.binder_id, d.card_id, d.finish, d.condition, sum(d.qty)::int
      from new_rows d join public.binders b on b.id = d.binder_id and b.for_trade and b.deleted_at is null
     group by 1, 2, 3, 4, 5 having sum(d.qty) <> 0
    on conflict (owner, binder_id, card_id, finish, condition) do update set qty = t.qty + excluded.qty, last_at = now();
  elsif tg_op = 'UPDATE' then
    insert into t1_private.trade_adds as t (owner, binder_id, card_id, finish, condition, qty)
    select d.user_id, d.binder_id, d.card_id, d.finish, d.condition, sum(d.qty)::int
      from (select n.user_id, n.binder_id, n.card_id, n.finish, n.condition, n.qty from new_rows n
            union all
            select o.user_id, o.binder_id, o.card_id, o.finish, o.condition, -o.qty from old_rows o) d
      join public.binders b on b.id = d.binder_id and b.for_trade and b.deleted_at is null
     group by 1, 2, 3, 4, 5 having sum(d.qty) <> 0
    on conflict (owner, binder_id, card_id, finish, condition) do update set qty = t.qty + excluded.qty, last_at = now();
  else
    insert into t1_private.trade_adds as t (owner, binder_id, card_id, finish, condition, qty)
    select d.user_id, d.binder_id, d.card_id, d.finish, d.condition, -sum(d.qty)::int
      from old_rows d join public.binders b on b.id = d.binder_id and b.for_trade and b.deleted_at is null
     group by 1, 2, 3, 4, 5 having sum(d.qty) <> 0
    on conflict (owner, binder_id, card_id, finish, condition) do update set qty = t.qty + excluded.qty, last_at = now();
  end if;
  return null;
end $$;

drop trigger if exists binder_items_trade_ins on public.binder_items;
drop trigger if exists binder_items_trade_upd on public.binder_items;
drop trigger if exists binder_items_trade_del on public.binder_items;
create trigger binder_items_trade_ins after insert on public.binder_items referencing new table as new_rows
  for each statement execute function t1_private.trade_adds_trg();
create trigger binder_items_trade_upd after update on public.binder_items referencing old table as old_rows new table as new_rows
  for each statement execute function t1_private.trade_adds_trg();
create trigger binder_items_trade_del after delete on public.binder_items referencing old table as old_rows
  for each statement execute function t1_private.trade_adds_trg();

-- Owners quiet for p_quiet: their net adds in for-trade binders their friends can see, against those friends' wants
-- (printing and finish when the want names them; under the want's max price at the copy's condition). One
-- `trade.wants` push per friend with a hit, at most one per (owner, friend) every p_cooldown. Returns pushes queued.
create or replace function t1_private.trade_want_digest(
  p_quiet interval default interval '30 minutes', p_cooldown interval default interval '12 hours', p_max integer default 200)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_owner uuid;
  v_name text;
  r record;
  v_n integer := 0;
begin
  for v_owner in select a.owner from t1_private.trade_adds a group by a.owner
                  having max(a.last_at) <= now() - p_quiet order by min(a.first_at) limit p_max loop
    -- Holds this owner's rows: a binder write now waits for this run instead of slipping between read and delete.
    perform 1 from t1_private.trade_adds a where a.owner = v_owner for update;
    select pr.display_name into v_name from public.profiles pr
     where pr.id = v_owner and pr.deleted_at is null and not pr.is_demo and not t1_private.is_restricted(v_owner);
    if v_name is not null then
      for r in
        with adds as (
          select a.card_id, a.finish, a.condition, sum(a.qty) q from t1_private.trade_adds a
           where a.owner = v_owner and a.binder_id in (select t1_private.trade_binders_for(v_owner, 1))
           group by 1, 2, 3 having sum(a.qty) > 0
        ), friends as (
          select case when f.user_lo = v_owner then f.user_hi else f.user_lo end uid from public.friendships f
           where (f.user_lo = v_owner or f.user_hi = v_owner) and f.status = 'accepted'
        ), hits as (
          select distinct w.user_id uid, c.oracle_id, o.name
            from adds a
            join public.cards c on c.id = a.card_id
            join public.card_oracles o on o.oracle_id = c.oracle_id
            left join public.card_prices p on p.card_id = a.card_id
            join public.wants w on w.oracle_id = c.oracle_id and w.qty > 0
                               and (w.card_id is null or w.card_id = a.card_id) and (w.finish is null or w.finish = a.finish)
            join friends fr on fr.uid = w.user_id
           where w.max_usd is null
              or coalesce(t1_private.condition_price(case a.finish when 'foil' then p.usd_foil when 'etched' then p.usd_etched else p.usd end,
                                                     a.condition), 0) <= w.max_usd
        )
        select h.uid, count(*) n, (array_agg(h.name order by h.name))[1:3] names
          from hits h
          join public.profiles pr on pr.id = h.uid and pr.deleted_at is null and not pr.is_demo
         where not exists (select 1 from t1_private.trade_want_notices x
                            where x.owner = v_owner and x.wanter = h.uid and x.sent_at > now() - p_cooldown)
         group by h.uid
      loop
        insert into t1_private.trade_want_notices (owner, wanter) values (v_owner, r.uid)
        on conflict (owner, wanter) do update set sent_at = now();
        perform public.enqueue_notification('trade.wants', null, array[r.uid], jsonb_build_object(
          'user_id', v_owner, 'owner_name', v_name, 'n', r.n, 'names', to_jsonb(r.names)));
        v_n := v_n + 1;
      end loop;
    end if;
    delete from t1_private.trade_adds a where a.owner = v_owner;
  end loop;
  delete from t1_private.trade_want_notices where sent_at < now() - interval '30 days';
  return v_n;
end $$;

-- Deleting your account clears what was waiting about you.
create or replace function t1_private.trade_wants_forget()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from t1_private.trade_adds where owner = new.id;
  delete from t1_private.trade_want_notices where owner = new.id or wanter = new.id;
  return null;
end $$;
drop trigger if exists profiles_trade_wants_forget on public.profiles;
create trigger profiles_trade_wants_forget after update of deleted_at on public.profiles
  for each row when (old.deleted_at is null and new.deleted_at is not null)
  execute function t1_private.trade_wants_forget();

-- ==================================================================== e_cron
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-follow-digest') then
      perform cron.schedule('t1-follow-digest', '*/5 * * * *',
        $c$select t1_private.follow_digest() where exists (select 1 from t1_private.follow_items where dirty_last is not null)$c$);
    end if;
    if not exists (select 1 from cron.job where jobname = 't1-trade-wants') then
      perform cron.schedule('t1-trade-wants', '*/5 * * * *',
        $c$select t1_private.trade_want_digest() where exists (select 1 from t1_private.trade_adds)$c$);
    end if;
  end if;
end $$;

-- ==================================================================== f_grants
do $$
declare f text;
begin
  foreach f in array array['follow_reach(uuid, text, uuid, bigint)', 'follow_snapshot(text, uuid)', 'follow_diff(jsonb, jsonb)', 'follow_names(jsonb, integer)',
                           'follow_item(text, uuid)', 'follow_state(uuid, uuid)', 'follow_dirty_trg()',
                           'follow_digest(interval, interval, integer)', 'follows_forget()', 'trade_adds_trg()',
                           'trade_want_digest(interval, interval, integer)', 'trade_wants_forget()'] loop
    execute format('revoke execute on function t1_private.%s from public', f);
  end loop;
  foreach f in array array['follow_set(text, uuid, boolean, boolean, text)', 'follow_get(text, uuid)', 'follows_list()',
                           'follow_changes(text, uuid, integer)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
