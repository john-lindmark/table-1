-- Friends, public profiles, per-part sharing and automatic want ↔ trade matching
-- (contract/friends-sharing-2026-10-18.md).
-- Friendships are mutual (one row per pair, lo < hi). Sharing is a level per part of the Library, private by default;
-- each binder, deck and cube can override its group. Reads of another account's Library only go through the security
-- definer RPCs below, which check the viewer's level (owner / friend / other account / blocked) against both the
-- profile and the part, so nothing private leaves the database. Every write is audited in account_audit (audit_log
-- is event-scoped). Trade matches compare wants with for-trade copies in the order trade_confirm uses: a want for that
-- printing and finish first, then that printing, then any printing.

-- ==================================================================== a_tables
create table if not exists public.account_audit (
  id bigint generated always as identity primary key,
  actor uuid not null,
  action text not null,
  target_user uuid,
  target_id uuid,
  before jsonb,
  after jsonb,
  at timestamptz not null default now()
);
create index if not exists account_audit_actor_idx on public.account_audit (actor, action, at desc);
create index if not exists account_audit_target_idx on public.account_audit (target_user) where target_user is not null;

create table if not exists public.friendships (
  user_lo uuid not null,
  user_hi uuid not null,
  requested_by uuid not null,
  status text not null check (status in ('pending', 'declined', 'accepted')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  primary key (user_lo, user_hi),
  check (user_lo < user_hi),
  check (requested_by in (user_lo, user_hi))
);
create index if not exists friendships_hi_idx on public.friendships (user_hi, user_lo);

create table if not exists public.user_blocks (
  user_id uuid not null,
  blocked_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (user_id, blocked_id),
  check (user_id <> blocked_id)
);
create index if not exists user_blocks_blocked_idx on public.user_blocks (blocked_id, user_id);

-- One row per account that changed anything; no row = the defaults.
create table if not exists public.share_settings (
  user_id uuid primary key,
  profile text not null default 'friends' check (profile in ('private', 'friends', 'public')),
  library text not null default 'private' check (library in ('private', 'friends', 'public')),
  all_cards text check (all_cards in ('private', 'friends', 'public')),
  for_trade text check (for_trade in ('private', 'friends', 'public')),
  wants text check (wants in ('private', 'friends', 'public')),
  binders text check (binders in ('private', 'friends', 'public')),
  decks text check (decks in ('private', 'friends', 'public')),
  cubes text check (cubes in ('private', 'friends', 'public')),
  record text not null default 'private' check (record in ('private', 'friends', 'public')),
  updated_at timestamptz not null default now()
);
create index if not exists share_settings_public_idx on public.share_settings (user_id) where profile = 'public';

-- null = same as its group (Binders / Decks / Cubes), which is null = same as Library.
alter table public.binders add column if not exists visibility text check (visibility in ('private', 'friends', 'public'));
alter table public.card_lists add column if not exists visibility text check (visibility in ('private', 'friends', 'public'));
-- Set by trade_match_start: the account a draft is with. trade_save leaves it alone.
alter table public.trades add column if not exists partner_id uuid;

do $$
declare t text;
begin
  foreach t in array array['account_audit', 'friendships', 'user_blocks', 'share_settings'] loop
    execute format('alter table public.%I enable row level security', t);
    -- No policy: read and written only through the RPCs below.
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ==================================================================== b_helpers
-- What a visibility asks of a viewer: public 0, friends 1, private 3 (only the owner).
-- Viewer levels: 3 owner, 1 friend, 0 any other signed-in account, -1 nothing (blocked either way, signed out).
-- Plain SQL with no search_path so the planner can inline it in the matching queries.
create or replace function t1_private.vis_ok(p_level integer, p_profile text, p_vis text)
returns boolean language sql immutable as $$
  select p_level >= 3 or (p_level >= 0
    and p_level >= case coalesce(p_profile, 'friends') when 'public' then 0 when 'friends' then 1 else 3 end
    and p_level >= case coalesce(p_vis, 'private') when 'public' then 0 when 'friends' then 1 else 3 end);
$$;

create or replace function t1_private.share_level(p_owner uuid, p_viewer uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select case
    when p_viewer is null or p_owner is null then -1
    when p_owner = p_viewer then 3
    when exists (select 1 from public.user_blocks b
                  where (b.user_id = p_owner and b.blocked_id = p_viewer) or (b.user_id = p_viewer and b.blocked_id = p_owner)) then -1
    when exists (select 1 from public.friendships f
                  where f.user_lo = least(p_owner, p_viewer) and f.user_hi = greatest(p_owner, p_viewer)
                    and f.status = 'accepted') then 1
    else 0 end;
$$;

-- An account's settings with the defaults filled in (a row whether or not one is stored).
create or replace function t1_private.share_of(p_owner uuid)
returns public.share_settings language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select s from public.share_settings s where s.user_id = p_owner),
    row(p_owner, 'friends', 'private', null, null, null, null, null, null, 'private', now())::public.share_settings);
$$;

-- How a viewer sees an account: self / friend / requested (viewer asked; a declined request still reads requested) /
-- incoming (they asked the viewer) / blocked (the viewer blocked them) / none.
create or replace function t1_private.relation(p_me uuid, p_other uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when p_me = p_other then 'self'
    when exists (select 1 from public.user_blocks b where b.user_id = p_me and b.blocked_id = p_other) then 'blocked'
    when exists (select 1 from public.user_blocks b where b.user_id = p_other and b.blocked_id = p_me) then 'none'
    else coalesce((select case
                     when f.status = 'accepted' then 'friend'
                     when f.requested_by = p_me then 'requested'
                     when f.status = 'pending' then 'incoming'
                     else 'none' end
                     from public.friendships f
                    where f.user_lo = least(p_me, p_other) and f.user_hi = greatest(p_me, p_other)), 'none') end;
$$;

create or replace function t1_private.person_json(p_uid uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('user_id', pr.id, 'display_name', pr.display_name, 'handle', pr.handle,
                            'avatar_url', pr.avatar_url)
    from public.profiles pr where pr.id = p_uid;
$$;

-- A real, live account another account can befriend or look at.
create or replace function t1_private.live_account(p_uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles pr where pr.id = p_uid and pr.deleted_at is null and not pr.is_demo);
$$;

create or replace function t1_private.account_audit(
  p_actor uuid, p_action text, p_target uuid, p_before jsonb default null, p_after jsonb default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.account_audit (actor, action, target_user, before, after) values (p_actor, p_action, p_target, p_before, p_after);
$$;

create or replace function t1_private.account_rate_limit(p_actor uuid, p_action text, p_max integer, p_window interval)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.account_audit a
       where a.actor = p_actor and a.action = p_action and a.at > now() - p_window) >= p_max then
    raise exception 'Too many requests, try again later' using errcode = '53400';
  end if;
end $$;

-- People the account shared an event with (as a player or organizer, the other as a player), not cancelled, not demo.
create or replace function t1_private.played_with(p_me uuid, p_since timestamptz default null)
returns table(user_id uuid, shared_events integer, last_at timestamptz)
language sql stable security definer set search_path = '' as $$
  with mine as (
    select em.event_id from public.event_members em where em.user_id = p_me
    union
    select p.event_id from public.participants p where p.user_id = p_me
  )
  select p.user_id, count(distinct p.event_id)::int, max(coalesce(e.starts_at, e.created_at))
    from mine
    join public.events e on e.id = mine.event_id
    join public.participants p on p.event_id = mine.event_id
   where p.user_id is not null and p.user_id <> p_me
     and e.status <> 'cancelled' and not e.is_demo
     and (p_since is null or coalesce(e.starts_at, e.created_at) >= p_since)
   group by p.user_id;
$$;

-- ==================================================================== c_friends
create or replace function public.friend_request(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  f public.friendships;
  v_lo uuid := least(v_uid, p_user_id);
  v_hi uuid := greatest(v_uid, p_user_id);
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_user_id is null or p_user_id = v_uid then
    raise exception 'You can''t add yourself' using errcode = '22023';
  end if;
  if not t1_private.live_account(p_user_id) then
    raise exception 'That account isn''t on Table 1' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.user_blocks b where b.user_id = v_uid and b.blocked_id = p_user_id) then
    raise exception 'Unblock them first' using errcode = '22023';
  end if;
  -- They blocked you: the same answer as a sent request, nothing written.
  if exists (select 1 from public.user_blocks b where b.user_id = p_user_id and b.blocked_id = v_uid) then
    return jsonb_build_object('status', 'requested');
  end if;

  select * into f from public.friendships where user_lo = v_lo and user_hi = v_hi for update;
  if f.status = 'accepted' then return jsonb_build_object('status', 'friends'); end if;
  if f.requested_by = v_uid then return jsonb_build_object('status', 'requested'); end if;

  if (select count(*) from public.friendships x
       where (x.user_lo = v_uid or x.user_hi = v_uid) and x.status = 'accepted') >= 1000 then
    raise exception 'You have 1000 friends, the most there can be' using errcode = '53400';
  end if;

  if f.user_lo is not null then
    -- They asked you (pending, or you declined it earlier): asking back makes you friends.
    update public.friendships set status = 'accepted', responded_at = now() where user_lo = v_lo and user_hi = v_hi;
    perform t1_private.account_audit(v_uid, 'friend.accepted', p_user_id);
    perform public.enqueue_notification('friend.accepted', null, array[p_user_id],
      jsonb_build_object('from_name', (select display_name from public.profiles where id = v_uid), 'user_id', v_uid));
    return jsonb_build_object('status', 'friends');
  end if;

  perform t1_private.account_rate_limit(v_uid, 'friend.request', 30, interval '1 hour');
  insert into public.friendships (user_lo, user_hi, requested_by, status) values (v_lo, v_hi, v_uid, 'pending');
  perform t1_private.account_audit(v_uid, 'friend.request', p_user_id);
  perform public.enqueue_notification('friend.request', null, array[p_user_id],
    jsonb_build_object('from_name', (select display_name from public.profiles where id = v_uid), 'user_id', v_uid));
  return jsonb_build_object('status', 'requested');
end $$;

-- By email: existing accounts only. The answer never says whether the address has an account.
create or replace function public.friend_request_by_email(p_email text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(trim(coalesce(p_email, '')));
  v_target uuid;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or length(v_email) > 254 then
    raise exception 'Enter a valid email address' using errcode = '22023';
  end if;
  perform t1_private.account_rate_limit(v_uid, 'friend.email_lookup', 20, interval '1 hour');
  perform t1_private.account_audit(v_uid, 'friend.email_lookup', null);
  select u.id into v_target from auth.users u where lower(u.email) = v_email and u.deleted_at is null limit 1;
  if v_target is not null and v_target <> v_uid and t1_private.live_account(v_target)
     and not exists (select 1 from public.user_blocks b where b.user_id = v_uid and b.blocked_id = v_target) then
    perform public.friend_request(v_target);
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.friend_respond(p_user_id uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  f public.friendships;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into f from public.friendships
   where user_lo = least(v_uid, p_user_id) and user_hi = greatest(v_uid, p_user_id) for update;
  if f.status = 'accepted' then
    if coalesce(p_accept, false) then return jsonb_build_object('status', 'friends'); end if;
    raise exception 'You''re already friends; unfriend them instead' using errcode = '22023';
  end if;
  if f.user_lo is null or f.requested_by = v_uid then
    raise exception 'That request is gone' using errcode = 'P0002';
  end if;
  if coalesce(p_accept, false) then
    update public.friendships set status = 'accepted', responded_at = now()
     where user_lo = f.user_lo and user_hi = f.user_hi;
    perform t1_private.account_audit(v_uid, 'friend.accepted', p_user_id);
    perform public.enqueue_notification('friend.accepted', null, array[p_user_id],
      jsonb_build_object('from_name', (select display_name from public.profiles where id = v_uid), 'user_id', v_uid));
    return jsonb_build_object('status', 'friends');
  end if;
  if f.status = 'pending' then
    update public.friendships set status = 'declined', responded_at = now()
     where user_lo = f.user_lo and user_hi = f.user_hi;
    perform t1_private.account_audit(v_uid, 'friend.declined', p_user_id);
  end if;
  return jsonb_build_object('status', 'declined');
end $$;

-- Cancels your request (pending or declined) or unfriends. A request someone else sent you is declined instead.
create or replace function public.friend_remove(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  f public.friendships;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into f from public.friendships
   where user_lo = least(v_uid, p_user_id) and user_hi = greatest(v_uid, p_user_id) for update;
  if f.user_lo is null then return jsonb_build_object('removed', false); end if;
  if f.status <> 'accepted' and f.requested_by <> v_uid then
    perform public.friend_respond(p_user_id, false);
    return jsonb_build_object('removed', false);
  end if;
  delete from public.friendships where user_lo = f.user_lo and user_hi = f.user_hi;
  perform t1_private.account_audit(v_uid, case when f.status = 'accepted' then 'friend.removed' else 'friend.cancelled' end,
                                   p_user_id, to_jsonb(f), null);
  return jsonb_build_object('removed', true);
end $$;

create or replace function public.user_block(p_user_id uuid, p_blocked boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_n integer;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_user_id is null or p_user_id = v_uid then raise exception 'You can''t block yourself' using errcode = '22023'; end if;
  if coalesce(p_blocked, true) then
    if not exists (select 1 from public.profiles where id = p_user_id) then
      raise exception 'That account isn''t on Table 1' using errcode = 'P0002';
    end if;
    insert into public.user_blocks (user_id, blocked_id) values (v_uid, p_user_id) on conflict do nothing;
    get diagnostics v_n = row_count;
    delete from public.friendships where user_lo = least(v_uid, p_user_id) and user_hi = greatest(v_uid, p_user_id);
    if v_n > 0 then perform t1_private.account_audit(v_uid, 'user.blocked', p_user_id); end if;
    return jsonb_build_object('blocked', true);
  end if;
  delete from public.user_blocks where user_id = v_uid and blocked_id = p_user_id;
  get diagnostics v_n = row_count;
  if v_n > 0 then perform t1_private.account_audit(v_uid, 'user.unblocked', p_user_id); end if;
  return jsonb_build_object('blocked', false);
end $$;

create or replace function public.friends_list()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  with f as (
    select case when f.user_lo = v_uid then f.user_hi else f.user_lo end other, f.*
      from public.friendships f where f.user_lo = v_uid or f.user_hi = v_uid
  ), p as (
    select f.*, pr.display_name, t1_private.person_json(pr.id) person
      from f join public.profiles pr on pr.id = f.other and pr.deleted_at is null
  )
  select jsonb_build_object(
    'friends', coalesce((select jsonb_agg(p.person || jsonb_build_object('since', coalesce(p.responded_at, p.created_at))
                                          order by lower(p.display_name), p.other)
                           from p where p.status = 'accepted'), '[]'::jsonb),
    'incoming', coalesce((select jsonb_agg(p.person || jsonb_build_object('at', p.created_at) order by p.created_at desc)
                            from p where p.status = 'pending' and p.requested_by <> v_uid), '[]'::jsonb),
    'outgoing', coalesce((select jsonb_agg(p.person || jsonb_build_object('at', p.created_at) order by p.created_at desc)
                            from p where p.status <> 'accepted' and p.requested_by = v_uid), '[]'::jsonb),
    'blocked', coalesce((select jsonb_agg(t1_private.person_json(b.blocked_id) order by b.created_at desc)
                           from public.user_blocks b where b.user_id = v_uid), '[]'::jsonb))
    into v;
  return v;
end $$;

-- Played-with suggestions, narrowed by a query that also finds public profiles by name or handle (2+ characters).
create or replace function public.friend_search(p_query text default null, p_limit integer default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_q text := lower(nullif(regexp_replace(trim(coalesce(p_query, '')), '[%_\\]', '', 'g'), ''));
  v jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  with played as (
    select * from t1_private.played_with(v_uid)
  ), pub as (
    select s.user_id from public.share_settings s
      join public.profiles pr on pr.id = s.user_id
     where s.profile = 'public' and length(coalesce(v_q, '')) >= 2
       and (lower(pr.display_name) like v_q || '%' or lower(pr.display_name) like '% ' || v_q || '%'
            or lower(coalesce(pr.handle, '')) like v_q || '%')
  ), cand as (
    select coalesce(pl.user_id, pub.user_id) uid, coalesce(pl.shared_events, 0) n, pl.last_at
      from played pl full join pub on pub.user_id = pl.user_id
  ), hits as (
    select c.*, pr.display_name, t1_private.relation(v_uid, c.uid) rel
      from cand c join public.profiles pr on pr.id = c.uid
     where pr.deleted_at is null and not pr.is_demo and c.uid <> v_uid
       and (v_q is null or lower(pr.display_name) like '%' || v_q || '%' or lower(coalesce(pr.handle, '')) like v_q || '%')
       and not exists (select 1 from public.user_blocks b
                        where (b.user_id = v_uid and b.blocked_id = c.uid) or (b.user_id = c.uid and b.blocked_id = v_uid))
     order by c.n desc, c.last_at desc nulls last, lower(pr.display_name)
     limit least(greatest(coalesce(p_limit, 30), 1), 100)
  )
  select coalesce(jsonb_agg(t1_private.person_json(r.uid) || jsonb_build_object('shared_events', r.n, 'relation', r.rel)
                            order by r.n desc, r.last_at desc nulls last, lower(r.display_name)), '[]'::jsonb)
    into v from hits r;
  return v;
end $$;

-- ==================================================================== d_sharing
create or replace function public.sharing_get()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  s public.share_settings;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  s := t1_private.share_of(v_uid);
  return jsonb_build_object(
    'profile', s.profile, 'library', s.library, 'all_cards', s.all_cards, 'for_trade', s.for_trade, 'wants', s.wants,
    'binders', s.binders, 'decks', s.decks, 'cubes', s.cubes, 'record', s.record,
    'items', coalesce((select jsonb_agg(i order by i->>'kind', lower(i->>'name'), i->>'id') from (
        select jsonb_build_object('kind', 'binder', 'id', b.id, 'name', b.name, 'for_trade', b.for_trade,
                                  'visibility', b.visibility) i
          from public.binders b where b.user_id = v_uid and b.deleted_at is null
        union all
        select jsonb_build_object('kind', l.kind, 'id', l.id, 'name', l.name, 'visibility', l.visibility)
          from public.card_lists l where l.user_id = v_uid and l.deleted_at is null) x), '[]'::jsonb));
end $$;

create or replace function public.sharing_set(p_settings jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_old public.share_settings;
  v_new public.share_settings;
  v_key text;
  v_val text;
  v_item jsonb;
  v_before text;
  v_n integer;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then
    raise exception 'Settings must be an object' using errcode = '22023';
  end if;
  for v_key in select jsonb_object_keys(p_settings) loop
    if v_key not in ('profile', 'library', 'all_cards', 'for_trade', 'wants', 'binders', 'decks', 'cubes', 'record', 'items') then
      raise exception 'Unknown setting: %', v_key using errcode = '22023';
    end if;
    continue when v_key = 'items';
    v_val := p_settings->>v_key;
    if v_val is null and v_key in ('profile', 'library', 'record') then
      raise exception '% needs a value', v_key using errcode = '22023';
    end if;
    if v_val is not null and v_val not in ('private', 'friends', 'public') then
      raise exception 'Visibility is private, friends or public' using errcode = '22023';
    end if;
  end loop;
  if p_settings ? 'items' and (jsonb_typeof(p_settings->'items') <> 'array' or jsonb_array_length(p_settings->'items') > 500) then
    raise exception 'Items must be a list of at most 500' using errcode = '22023';
  end if;

  v_old := t1_private.share_of(v_uid);
  v_new := v_old;
  if p_settings ? 'profile' then v_new.profile := p_settings->>'profile'; end if;
  if p_settings ? 'library' then v_new.library := p_settings->>'library'; end if;
  if p_settings ? 'record' then v_new.record := p_settings->>'record'; end if;
  if p_settings ? 'all_cards' then v_new.all_cards := p_settings->>'all_cards'; end if;
  if p_settings ? 'for_trade' then v_new.for_trade := p_settings->>'for_trade'; end if;
  if p_settings ? 'wants' then v_new.wants := p_settings->>'wants'; end if;
  if p_settings ? 'binders' then v_new.binders := p_settings->>'binders'; end if;
  if p_settings ? 'decks' then v_new.decks := p_settings->>'decks'; end if;
  if p_settings ? 'cubes' then v_new.cubes := p_settings->>'cubes'; end if;
  if (to_jsonb(v_new) - 'updated_at') is distinct from (to_jsonb(v_old) - 'updated_at') then
    insert into public.share_settings as s (user_id, profile, library, all_cards, for_trade, wants, binders, decks, cubes, record)
    values (v_uid, v_new.profile, v_new.library, v_new.all_cards, v_new.for_trade, v_new.wants, v_new.binders,
            v_new.decks, v_new.cubes, v_new.record)
    on conflict (user_id) do update set
      profile = excluded.profile, library = excluded.library, all_cards = excluded.all_cards,
      for_trade = excluded.for_trade, wants = excluded.wants, binders = excluded.binders, decks = excluded.decks,
      cubes = excluded.cubes, record = excluded.record, updated_at = now();
    insert into public.account_audit (actor, action, before, after)
    values (v_uid, 'sharing.set', to_jsonb(v_old) - 'updated_at' - 'user_id', to_jsonb(v_new) - 'updated_at' - 'user_id');
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_settings->'items', '[]'::jsonb)) loop
    v_val := v_item->>'visibility';
    if v_val is not null and v_val not in ('private', 'friends', 'public') then
      raise exception 'Visibility is private, friends or public' using errcode = '22023';
    end if;
    if v_item->>'kind' = 'binder' then
      select visibility into v_before from public.binders
       where id = (v_item->>'id')::uuid and user_id = v_uid and deleted_at is null for update;
      get diagnostics v_n = row_count;
      if v_n = 0 then raise exception 'That isn''t yours' using errcode = '42501'; end if;
      continue when v_before is not distinct from v_val;
      update public.binders set visibility = v_val where id = (v_item->>'id')::uuid;
    elsif v_item->>'kind' in ('deck', 'cube') then
      select visibility into v_before from public.card_lists
       where id = (v_item->>'id')::uuid and user_id = v_uid and kind = v_item->>'kind' and deleted_at is null for update;
      get diagnostics v_n = row_count;
      if v_n = 0 then raise exception 'That isn''t yours' using errcode = '42501'; end if;
      continue when v_before is not distinct from v_val;
      update public.card_lists set visibility = v_val where id = (v_item->>'id')::uuid;
    else
      raise exception 'An item is a binder, deck or cube' using errcode = '22023';
    end if;
    insert into public.account_audit (actor, action, target_id, before, after)
    values (v_uid, 'sharing.item', (v_item->>'id')::uuid, jsonb_build_object('visibility', v_before),
            jsonb_build_object('kind', v_item->>'kind', 'visibility', v_val));
  end loop;
  return public.sharing_get();
end $$;

-- ==================================================================== e_profiles
-- For-trade binders of p_owner whose copies reach a viewer at p_level: For trade reaches them, or that binder does.
create or replace function t1_private.trade_binders_for(p_owner uuid, p_level integer)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select b.id from public.binders b, t1_private.share_of(p_owner) s
   where b.user_id = p_owner and b.for_trade and b.deleted_at is null
     and (t1_private.vis_ok(p_level, s.profile, coalesce(s.for_trade, s.library))
          or t1_private.vis_ok(p_level, s.profile, coalesce(b.visibility, s.binders, s.library)));
$$;

create or replace function public.profile_view(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  pr public.profiles;
  s public.share_settings;
  v_level integer;
  v_sections jsonb := '{}'::jsonb;
  v_rel text;
  v_since timestamptz;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into pr from public.profiles where id = p_user_id;
  if pr.id is null or pr.deleted_at is not null or (pr.is_demo and pr.id <> v_uid) then
    raise exception 'That account isn''t on Table 1' using errcode = 'P0002';
  end if;
  v_level := t1_private.share_level(p_user_id, v_uid);
  v_rel := t1_private.relation(v_uid, p_user_id);
  s := t1_private.share_of(p_user_id);
  if v_rel = 'friend' then
    select coalesce(f.responded_at, f.created_at) into v_since from public.friendships f
     where f.user_lo = least(v_uid, p_user_id) and f.user_hi = greatest(v_uid, p_user_id);
  end if;

  if t1_private.vis_ok(v_level, s.profile, 'public') then
    if t1_private.vis_ok(v_level, s.profile, coalesce(s.all_cards, s.library)) then
      v_sections := v_sections || jsonb_build_object('all_cards', coalesce(
        (select jsonb_build_object('cards', ls.total_qty, 'printings', ls.unique_printings, 'value_usd', ls.value_usd)
           from public.library_summary ls where ls.user_id = p_user_id),
        jsonb_build_object('cards', 0, 'printings', 0, 'value_usd', 0)));
    end if;
    if exists (select 1 from t1_private.trade_binders_for(p_user_id, v_level)) then
      v_sections := v_sections || jsonb_build_object('for_trade', jsonb_build_object('cards',
        (select coalesce(sum(bi.qty), 0) from public.binder_items bi
           where bi.binder_id in (select t1_private.trade_binders_for(p_user_id, v_level)) and bi.qty > 0)));
    end if;
    if t1_private.vis_ok(v_level, s.profile, coalesce(s.wants, s.library)) then
      v_sections := v_sections || jsonb_build_object('wants', jsonb_build_object('cards',
        (select coalesce(sum(w.qty), 0) from public.wants w where w.user_id = p_user_id and w.qty > 0)));
    end if;
    v_sections := v_sections || jsonb_build_object('binders', coalesce((
      select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'for_trade', b.for_trade,
               'cards', (select coalesce(sum(bi.qty), 0) from public.binder_items bi where bi.binder_id = b.id and bi.qty > 0))
             order by lower(b.name), b.id)
        from public.binders b
       where b.user_id = p_user_id and b.deleted_at is null
         and t1_private.vis_ok(v_level, s.profile, coalesce(b.visibility, s.binders, s.library))), '[]'::jsonb));
    v_sections := v_sections || jsonb_build_object('decks', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'format', l.format,
               'cards', (select coalesce(sum(e.qty), 0) from public.card_list_entries e where e.list_id = l.id and e.board <> 'maybe'))
             order by lower(l.name), l.id)
        from public.card_lists l
       where l.user_id = p_user_id and l.kind = 'deck' and l.deleted_at is null
         and t1_private.vis_ok(v_level, s.profile, coalesce(l.visibility, s.decks, s.library))), '[]'::jsonb));
    v_sections := v_sections || jsonb_build_object('cubes', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'format', l.format,
               'cards', (select coalesce(sum(e.qty), 0) from public.card_list_entries e where e.list_id = l.id and e.board <> 'maybe'))
             order by lower(l.name), l.id)
        from public.card_lists l
       where l.user_id = p_user_id and l.kind = 'cube' and l.deleted_at is null
         and t1_private.vis_ok(v_level, s.profile, coalesce(l.visibility, s.cubes, s.library))), '[]'::jsonb));
    if t1_private.vis_ok(v_level, s.profile, s.record) then
      v_sections := v_sections || jsonb_build_object('record', (
        select jsonb_build_object('match_wins', coalesce(sum(o.mw), 0), 'match_losses', coalesce(sum(o.ml), 0),
                                  'match_draws', coalesce(sum(o.md), 0), 'events_played', count(distinct o.event_id))
          from public.match_outcomes o where o.user_id = p_user_id and not o.is_demo));
    end if;
  end if;

  return t1_private.person_json(p_user_id) || jsonb_build_object(
    'relation', v_rel, 'friends_since', v_since,
    'visible', t1_private.vis_ok(v_level, s.profile, 'public'), 'sections', v_sections);
end $$;

-- The cards behind one visible section, paged by offset. Anything that doesn't reach the caller (or doesn't
-- exist) reads "That's private".
create or replace function public.profile_cards(
  p_user_id uuid, p_section text, p_id uuid default null, p_after integer default 0, p_limit integer default 5000)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  s public.share_settings;
  v_level integer;
  v_off integer := greatest(coalesce(p_after, 0), 0);
  v_lim integer := least(greatest(coalesce(p_limit, 5000), 1), 10000);
  v_ok boolean := false;
  v_rows jsonb;
  v_n integer;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles pr where pr.id = p_user_id and pr.deleted_at is null
                  and (not pr.is_demo or pr.id = v_uid)) then
    raise exception 'That''s private' using errcode = '42501';
  end if;
  v_level := t1_private.share_level(p_user_id, v_uid);
  s := t1_private.share_of(p_user_id);
  v_ok := case p_section
    when 'all_cards' then t1_private.vis_ok(v_level, s.profile, coalesce(s.all_cards, s.library))
    when 'for_trade' then exists (select 1 from t1_private.trade_binders_for(p_user_id, v_level))
    when 'wants' then t1_private.vis_ok(v_level, s.profile, coalesce(s.wants, s.library))
    when 'binder' then exists (select 1 from public.binders b where b.id = p_id and b.user_id = p_user_id and b.deleted_at is null
                                and t1_private.vis_ok(v_level, s.profile, coalesce(b.visibility, s.binders, s.library)))
    when 'deck' then exists (select 1 from public.card_lists l where l.id = p_id and l.user_id = p_user_id and l.kind = 'deck'
                              and l.deleted_at is null and t1_private.vis_ok(v_level, s.profile, coalesce(l.visibility, s.decks, s.library)))
    when 'cube' then exists (select 1 from public.card_lists l where l.id = p_id and l.user_id = p_user_id and l.kind = 'cube'
                              and l.deleted_at is null and t1_private.vis_ok(v_level, s.profile, coalesce(l.visibility, s.cubes, s.library)))
    else null end;
  if v_ok is null then raise exception 'Unknown section' using errcode = '22023'; end if;
  if not v_ok then raise exception 'That''s private' using errcode = '42501'; end if;

  if p_section = 'all_cards' then
    select coalesce(jsonb_agg(jsonb_build_array(r.card_id, r.finish, r.qty) order by r.card_id, r.finish), '[]'::jsonb), count(*)
      into v_rows, v_n
      from (select i.card_id, i.finish, sum(i.qty)::int qty from public.collection_items i
             where i.user_id = p_user_id and i.qty > 0 group by 1, 2 order by 1, 2 offset v_off limit v_lim) r;
  elsif p_section in ('for_trade', 'binder') then
    select coalesce(jsonb_agg(jsonb_build_array(r.card_id, r.finish, r.condition, r.lang, r.qty)
                              order by r.card_id, r.finish, r.condition, r.lang), '[]'::jsonb), count(*)
      into v_rows, v_n
      from (select bi.card_id, bi.finish, bi.condition, bi.lang, sum(bi.qty)::int qty from public.binder_items bi
             where bi.qty > 0 and case when p_section = 'binder' then bi.binder_id = p_id
                                       else bi.binder_id in (select t1_private.trade_binders_for(p_user_id, v_level)) end
             group by 1, 2, 3, 4 order by 1, 2, 3, 4 offset v_off limit v_lim) r;
  elsif p_section = 'wants' then
    select coalesce(jsonb_agg(jsonb_build_array(r.oracle_id, r.card_id, r.finish, r.qty) order by r.id), '[]'::jsonb), count(*)
      into v_rows, v_n
      from (select w.id, w.oracle_id, w.card_id, w.finish, w.qty from public.wants w
             where w.user_id = p_user_id and w.qty > 0 order by w.id offset v_off limit v_lim) r;
  else
    select coalesce(jsonb_agg(jsonb_build_array(r.card_id, r.board, r.qty) order by r.board, r.card_id), '[]'::jsonb), count(*)
      into v_rows, v_n
      from (select e.card_id, e.board, e.qty from public.card_list_entries e where e.list_id = p_id
             order by e.board, e.card_id offset v_off limit v_lim) r;
  end if;
  return jsonb_build_object('rows', v_rows, 'more', v_n = v_lim);
end $$;

-- ==================================================================== f_matching
do $$ begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 't1_private' and t.typname = 'mwant') then
    create type t1_private.mwant as (who uuid, oracle_id uuid, card_id uuid, finish text, qty integer, max_usd numeric);
  end if;
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 't1_private' and t.typname = 'mcopy') then
    create type t1_private.mcopy as (who uuid, oracle_id uuid, card_id uuid, finish text, condition text, lang text,
                                     binder_id uuid, qty integer, usd numeric);
  end if;
end $$;

-- Meets wants with copies, separately for each `who` (the other account): wants for that printing and finish take
-- copies first, then wants for that printing in any finish, then wants for any printing (trade_confirm's order).
-- Within one want, copies go NM first, then cheaper, then English. A copy is used once; a want up to its qty.
-- Wants are unique per (who, oracle, printing, finish), so each copy meets at most one want per tier.
create or replace function t1_private.want_match(p_wants t1_private.mwant[], p_copies t1_private.mcopy[])
returns table(who uuid, card_id uuid, finish text, condition text, lang text, binder_id uuid, qty integer, usd numeric,
              tier integer, w_oracle uuid, w_card uuid, w_finish text, max_usd numeric)
-- The arrays carry no statistics, so the planner guesses a few rows and nests loops over thousands: hash joins only.
language sql stable set search_path = '' set enable_nestloop = off as $$
  with c as (
    select row_number() over () cid, x.*,
           case x.condition when 'NM' then 0 when 'LP' then 1 when 'MP' then 2 when 'HP' then 3 else 4 end crank
      from unnest(p_copies) x where x.qty > 0
  ), w as (
    select * from unnest(p_wants) x where x.qty > 0
  ), a0 as (
    select c.cid, w.oracle_id wo, w.card_id wc, w.finish wf, w.max_usd,
           least(c.qty, greatest(0, w.qty - coalesce(sum(c.qty) over (
             partition by c.who, w.card_id, w.finish order by c.crank, c.usd nulls last, c.lang <> 'en', c.cid
             rows between unbounded preceding and 1 preceding), 0)))::int n
      from w join c on c.who = w.who and c.card_id = w.card_id and c.finish = w.finish
     where w.finish is not null
  ), r0 as (
    select c.*, c.qty - coalesce(a0.n, 0) rem from c left join a0 on a0.cid = c.cid
  ), a1 as (
    select r0.cid, w.oracle_id wo, w.card_id wc, w.finish wf, w.max_usd,
           least(r0.rem, greatest(0, w.qty - coalesce(sum(r0.rem) over (
             partition by r0.who, w.card_id order by r0.crank, r0.usd nulls last, r0.lang <> 'en', r0.cid
             rows between unbounded preceding and 1 preceding), 0)))::int n
      from w join r0 on r0.who = w.who and r0.card_id = w.card_id
     where w.card_id is not null and w.finish is null and r0.rem > 0
  ), r1 as (
    select r0.*, r0.rem - coalesce(a1.n, 0) rem1 from r0 left join a1 on a1.cid = r0.cid
  ), a2 as (
    select r1.cid, w.oracle_id wo, w.card_id wc, w.finish wf, w.max_usd,
           least(r1.rem1, greatest(0, w.qty - coalesce(sum(r1.rem1) over (
             partition by r1.who, w.oracle_id order by r1.crank, r1.usd nulls last, r1.lang <> 'en', r1.cid
             rows between unbounded preceding and 1 preceding), 0)))::int n
      from w join r1 on r1.who = w.who and r1.oracle_id = w.oracle_id
     where w.card_id is null and r1.rem1 > 0
  ), a as (
    select 0 tier, * from a0 union all select 1, * from a1 union all select 2, * from a2
  )
  select c.who, c.card_id, c.finish, c.condition, c.lang, c.binder_id, a.n, c.usd, a.tier, a.wo, a.wc, a.wf, a.max_usd
    from a join c on c.cid = a.cid
   where a.n > 0;
$$;

-- Who matching looks at: one account (p_one), or friends plus people shared an event with in the last 90 days.
-- Level per person as in share_level; demo, deleted and blocked accounts never.
create or replace function t1_private.match_people(p_me uuid, p_one uuid)
returns table(uid uuid, level integer, friend boolean)
language sql stable security definer set search_path = '' as $$
  with cand as (
    select p_one uid where p_one is not null
    union
    select case when f.user_lo = p_me then f.user_hi else f.user_lo end
      from public.friendships f where p_one is null and (f.user_lo = p_me or f.user_hi = p_me) and f.status = 'accepted'
    union
    select pw.user_id from t1_private.played_with(p_me, now() - interval '90 days') pw where p_one is null
  )
  select c.uid, l.level, l.level = 1
    from cand c
    join public.profiles pr on pr.id = c.uid and pr.deleted_at is null and not pr.is_demo
    cross join lateral (select t1_private.share_level(c.uid, p_me) level) l
   where c.uid <> p_me and l.level >= 0;
$$;

create or replace function t1_private.trade_matches_for(p_me uuid, p_one uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_people jsonb;
begin
  with people as (
    select * from t1_private.match_people(p_me, p_one)
  ), my_wants as (
    select w.oracle_id, w.card_id, w.finish, w.qty, w.max_usd from public.wants w where w.user_id = p_me and w.qty > 0
  ), their_tb as (
    select p.uid, tb.id from people p cross join lateral t1_private.trade_binders_for(p.uid, p.level) tb(id)
  ), their_copies as (
    select t.uid who, c.oracle_id, bi.card_id, bi.finish, bi.condition, bi.lang, sum(bi.qty)::int qty
      from their_tb t
      join public.binder_items bi on bi.binder_id = t.id and bi.qty > 0
      join public.cards c on c.id = bi.card_id
     where c.oracle_id in (select oracle_id from my_wants)
     group by 1, 2, 3, 4, 5, 6
  ), wants_seen as (
    select p.uid from people p, t1_private.share_of(p.uid) s
     where t1_private.vis_ok(p.level, s.profile, coalesce(s.wants, s.library))
  ), my_copies as (
    select c.oracle_id, bi.card_id, bi.finish, bi.condition, bi.lang,
           (array_agg(bi.binder_id order by bi.qty desc, bi.binder_id))[1] binder_id, sum(bi.qty)::int qty
      from public.binders b
      join public.binder_items bi on bi.binder_id = b.id and bi.qty > 0
      join public.cards c on c.id = bi.card_id
     where b.user_id = p_me and b.for_trade and b.deleted_at is null
     group by 1, 2, 3, 4, 5
  ), their_wants as (
    select w.user_id who, w.oracle_id, w.card_id, w.finish, w.qty
      from wants_seen ws join public.wants w on w.user_id = ws.uid and w.qty > 0
     where w.oracle_id in (select oracle_id from my_copies)
  ), have as (
    select m.* from t1_private.want_match(
      (select array_agg(row(o.who, w.oracle_id, w.card_id, w.finish, w.qty, w.max_usd)::t1_private.mwant)
         from my_wants w join (select distinct who, oracle_id from their_copies) o on o.oracle_id = w.oracle_id),
      (select array_agg(row(tc.who, tc.oracle_id, tc.card_id, tc.finish, tc.condition, tc.lang, null,
                            tc.qty, t1_private.unit_price(pr.usd, pr.usd_foil, pr.usd_etched, null, null, tc.finish, 'usd'))::t1_private.mcopy)
         from their_copies tc left join public.card_prices pr on pr.card_id = tc.card_id)) m
  ), want as (
    select m.* from t1_private.want_match(
      (select array_agg(row(tw.who, tw.oracle_id, tw.card_id, tw.finish, tw.qty, null)::t1_private.mwant) from their_wants tw),
      (select array_agg(row(o.who, mc.oracle_id, mc.card_id, mc.finish, mc.condition, mc.lang, mc.binder_id,
                            mc.qty, t1_private.unit_price(pr.usd, pr.usd_foil, pr.usd_etched, null, null, mc.finish, 'usd'))::t1_private.mcopy)
         from my_copies mc join (select distinct who, oracle_id from their_wants) o on o.oracle_id = mc.oracle_id
         left join public.card_prices pr on pr.card_id = mc.card_id)) m
  ), have_lines as (
    -- One line per copy (a copy split over two wants names the most specific one).
    select h.who, h.card_id, h.finish, h.condition, h.lang, sum(h.qty)::int qty, max(h.usd) usd,
           (array_agg(jsonb_build_object('oracle_id', h.w_oracle, 'card_id', h.w_card, 'finish', h.w_finish) order by h.tier))[1] want,
           coalesce(bool_or(h.max_usd is not null and h.usd > h.max_usd), false) over_max
      from have h group by 1, 2, 3, 4, 5
  ), want_lines as (
    select h.who, h.card_id, h.finish, h.condition, h.lang, h.binder_id, sum(h.qty)::int qty, max(h.usd) usd,
           (array_agg(jsonb_build_object('oracle_id', h.w_oracle, 'card_id', h.w_card, 'finish', h.w_finish) order by h.tier))[1] want
      from want h group by 1, 2, 3, 4, 5, 6
  ), per as (
    select p.uid, p.friend,
           coalesce((select sum(l.qty) from have_lines l where l.who = p.uid), 0) have_copies,
           coalesce((select sum(l.qty) from want_lines l where l.who = p.uid), 0) want_copies,
           coalesce((select sum(l.qty * l.usd) from have_lines l where l.who = p.uid and not l.over_max), 0) have_usd,
           coalesce((select sum(l.qty * l.usd) from want_lines l where l.who = p.uid), 0) want_usd
      from people p
  ), top as (
    select * from per where have_copies + want_copies > 0
     order by have_copies + want_copies desc, friend desc, uid limit 50
  )
  select coalesce(jsonb_agg(t1_private.person_json(t.uid) || jsonb_build_object(
           'friend', t.friend, 'have_copies', t.have_copies, 'want_copies', t.want_copies,
           'have_usd', round(t.have_usd, 2), 'want_usd', round(t.want_usd, 2),
           'they_have', coalesce((select jsonb_agg(jsonb_build_object('card_id', l.card_id, 'finish', l.finish,
                                    'condition', l.condition, 'lang', l.lang, 'qty', l.qty, 'want', l.want, 'usd', l.usd,
                                    'over_max', l.over_max) order by l.over_max, l.usd desc nulls last, l.card_id, l.finish)
                                  from (select * from have_lines l where l.who = t.uid
                                         order by l.over_max, l.usd desc nulls last, l.card_id, l.finish limit 200) l), '[]'::jsonb),
           'they_want', coalesce((select jsonb_agg(jsonb_build_object('card_id', l.card_id, 'finish', l.finish,
                                    'condition', l.condition, 'lang', l.lang, 'binder_id', l.binder_id, 'qty', l.qty,
                                    'want', l.want, 'usd', l.usd) order by l.usd desc nulls last, l.card_id, l.finish)
                                  from (select * from want_lines l where l.who = t.uid
                                         order by l.usd desc nulls last, l.card_id, l.finish limit 200) l), '[]'::jsonb))
         order by t.have_copies + t.want_copies desc, t.friend desc, t.uid), '[]'::jsonb)
    into v_people from top t;
  return jsonb_build_object('people', v_people, 'generated_at', now());
end $$;

create or replace function public.trade_matches(p_user_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  return t1_private.trade_matches_for(v_uid, p_user_id);
end $$;

-- A trade draft from the current match with one person: gives = what they want of your for-trade copies, gets =
-- what they have that you want. The key makes a retry return the same draft.
create or replace function public.trade_match_start(p_user_id uuid, p_idempotency_key uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid := coalesce(p_idempotency_key, gen_random_uuid());
  v public.trades;
  m jsonb;
  v_gives jsonb;
  v_gets jsonb;
begin
  if v_uid is null then raise exception 'Sign in to trade' using errcode = '28000'; end if;
  select * into v from public.trades where id = v_id;
  if v.id is not null then
    if v.user_id <> v_uid then raise exception 'Use a new key' using errcode = '22023'; end if;
    return to_jsonb(v) - 'user_id' || jsonb_build_object('duplicate', true);
  end if;
  if p_user_id is null or p_user_id = v_uid or t1_private.share_level(p_user_id, v_uid) < 0
     or not t1_private.live_account(p_user_id) then
    raise exception 'That''s private' using errcode = '42501';
  end if;
  m := (t1_private.trade_matches_for(v_uid, p_user_id))->'people'->0;
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('card_id', l->'card_id', 'finish', l->'finish',
           'condition', l->'condition', 'lang', l->'lang', 'qty', l->'qty', 'binder_id', l->'binder_id'))), '[]'::jsonb)
    into v_gives from jsonb_array_elements(coalesce(m->'they_want', '[]'::jsonb)) l;
  select coalesce(jsonb_agg(jsonb_build_object('card_id', l->'card_id', 'finish', l->'finish',
           'condition', l->'condition', 'lang', l->'lang', 'qty', l->'qty')), '[]'::jsonb)
    into v_gets from jsonb_array_elements(coalesce(m->'they_have', '[]'::jsonb)) l;
  if jsonb_array_length(v_gives) + jsonb_array_length(v_gets) = 0 then
    raise exception 'Nothing to trade with them right now' using errcode = '22023';
  end if;
  if (select count(*) from public.trades where user_id = v_uid and status = 'draft') >= 50 then
    raise exception 'Too many open trades; confirm or delete some first' using errcode = '53400';
  end if;
  insert into public.trades (id, user_id, partner, partner_id, gives, gets)
  values (v_id, v_uid, (select left(display_name, 80) from public.profiles where id = p_user_id), p_user_id,
          t1_private.trade_side(v_gives), t1_private.trade_side(v_gets))
  returning * into v;
  perform t1_private.account_audit(v_uid, 'trade.from_match', p_user_id, null,
    jsonb_build_object('trade_id', v.id, 'gives', jsonb_array_length(v.gives), 'gets', jsonb_array_length(v.gets)));
  return to_jsonb(v) - 'user_id' || jsonb_build_object('duplicate', false);
end $$;

-- ==================================================================== g_add_players
-- Add players: friends first (by name), then people you've played with (most shared first), as before.
drop function if exists public.suggested_players(uuid, text, integer, boolean);
create function public.suggested_players(
  p_event_id uuid, p_query text default null, p_limit integer default 30, p_include_demo boolean default false)
returns table(user_id uuid, display_name text, handle text, shared_events integer,
              last_shared_at timestamptz, invited boolean, friend boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_q text := nullif(regexp_replace(trim(coalesce(p_query, '')), '[%_\\]', '', 'g'), '');
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can add players' using errcode = '42501';
  end if;
  return query
  with mine as (
    select em.event_id from public.event_members em where em.user_id = v_uid
    union
    select p.event_id from public.participants p where p.user_id = v_uid
  ), co as (
    select p.user_id as uid, count(distinct p.event_id)::int as n,
           max(coalesce(e.starts_at, e.created_at)) as last_at
      from mine
      join public.events e on e.id = mine.event_id
      join public.participants p on p.event_id = mine.event_id
     where p.user_id is not null and p.user_id <> v_uid and mine.event_id <> p_event_id
       and e.status <> 'cancelled'
       and (p_include_demo or not e.is_demo)
     group by p.user_id
  ), fr as (
    select case when f.user_lo = v_uid then f.user_hi else f.user_lo end as uid
      from public.friendships f where (f.user_lo = v_uid or f.user_hi = v_uid) and f.status = 'accepted'
  ), cand as (
    select coalesce(co.uid, fr.uid) as uid, coalesce(co.n, 0) as n, co.last_at, fr.uid is not null as is_friend
      from co full join fr on fr.uid = co.uid
  )
  select cand.uid, pr.display_name, pr.handle, cand.n, cand.last_at,
         exists (select 1 from public.event_invites i
                  where i.event_id = p_event_id and i.user_id = cand.uid and i.status = 'pending'),
         cand.is_friend
    from cand
    join public.profiles pr on pr.id = cand.uid
   where pr.deleted_at is null
     and (p_include_demo or not pr.is_demo)
     and not exists (select 1 from public.participants x where x.event_id = p_event_id and x.user_id = cand.uid)
     and not exists (select 1 from public.user_blocks b
                      where (b.user_id = v_uid and b.blocked_id = cand.uid) or (b.user_id = cand.uid and b.blocked_id = v_uid))
     and (v_q is null or pr.display_name ilike '%' || v_q || '%' or coalesce(pr.handle, '') ilike '%' || v_q || '%')
   order by cand.is_friend desc, case when cand.is_friend then lower(pr.display_name) end,
            cand.n desc, cand.last_at desc nulls last, pr.display_name
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
end $$;

-- ==================================================================== h_delete_account
-- Account deletion also removes friendships, requests, blocks (both ways), sharing settings and account audit rows.
create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  perform public.demo_remove();
  update public.profiles
     set handle = null, display_name = 'Deleted player', avatar_url = null,
         deleted_at = now(), updated_at = now()
   where id = v_uid;
  update public.participants set display_name = 'Deleted player' where user_id = v_uid;
  delete from public.devices where user_id = v_uid;
  delete from public.notification_prefs where user_id = v_uid;
  delete from public.presence_cells where user_id = v_uid;
  delete from public.event_invites where user_id = v_uid and status = 'pending';
  delete from public.trades where user_id = v_uid;
  update public.trades set partner_id = null where partner_id = v_uid;
  delete from public.want_ledger where user_id = v_uid;
  delete from public.wants where user_id = v_uid;
  delete from public.binder_ledger where user_id = v_uid;
  delete from public.binder_items where user_id = v_uid;
  delete from public.binders where user_id = v_uid;
  delete from public.collection_ledger where user_id = v_uid;
  delete from public.collection_batches where user_id = v_uid;
  delete from public.collection_items where user_id = v_uid;
  delete from public.card_lists where user_id = v_uid;   -- versions and entries cascade
  delete from public.library_summary where user_id = v_uid;
  delete from public.friendships where user_lo = v_uid or user_hi = v_uid;
  delete from public.user_blocks where user_id = v_uid or blocked_id = v_uid;
  delete from public.share_settings where user_id = v_uid;
  delete from public.account_audit where actor = v_uid or target_user = v_uid;
  update public.scan_reports set user_id = null where user_id = v_uid;
end $$;

-- ==================================================================== i_grants
do $$
declare f text;
begin
  foreach f in array array[
    'share_level(uuid, uuid)', 'share_of(uuid)', 'relation(uuid, uuid)', 'person_json(uuid)', 'live_account(uuid)',
    'account_audit(uuid, text, uuid, jsonb, jsonb)', 'account_rate_limit(uuid, text, integer, interval)',
    'played_with(uuid, timestamptz)', 'trade_binders_for(uuid, integer)',
    'want_match(t1_private.mwant[], t1_private.mcopy[])', 'match_people(uuid, uuid)', 'trade_matches_for(uuid, uuid)',
    'vis_ok(integer, text, text)'] loop
    execute format('revoke execute on function t1_private.%s from public', f);
  end loop;
  foreach f in array array[
    'friend_request(uuid)', 'friend_request_by_email(text)', 'friend_respond(uuid, boolean)', 'friend_remove(uuid)',
    'user_block(uuid, boolean)', 'friends_list()', 'friend_search(text, integer)', 'sharing_get()', 'sharing_set(jsonb)',
    'profile_view(uuid)', 'profile_cards(uuid, text, uuid, integer, integer)', 'trade_matches(uuid)',
    'trade_match_start(uuid, uuid)', 'suggested_players(uuid, text, integer, boolean)', 'delete_account()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
