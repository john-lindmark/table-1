-- Friends privacy fixes from the 2026-10-18 review (contract/friends-sharing-2026-10-18.md § Privacy fixes).
-- 1. Asking by email no longer tells the asker whose address it was. Every email asked is kept as an email ask
--    (friend_email_asks) whether or not it has an account, and Sent lists it as {email, at} until that person
--    accepts. A request it makes is marked friendships.via = 'email' (with the address) and reads `none`, not
--    `requested`, everywhere the asker can see a relation. friend_remove / friend_respond by id don't touch it;
--    friend_cancel_email cancels by address.
-- 2. A decline is remembered for 90 days (friend_declines): asking someone who declined you writes a request that
--    reads `requested` but sits declined (no push, nothing in their Requests). And at most 3 friend.request pushes
--    to the same person in 30 days; further requests are written without one.
-- 3. Blocks either way are skipped by invite_players / invite_by_email (the usual answer) and the event.new alert.
-- 4. profile_view's all_cards.value_usd is for yourself only.

-- ==================================================================== a_tables
alter table public.friendships add column if not exists via text check (via in ('email'));
alter table public.friendships add column if not exists email text;

-- Every address an account asked by email that isn't a friend yet (one row per address).
create table if not exists public.friend_email_asks (
  user_id uuid not null,
  email text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, email)
);

-- user_id declined asker_id's request at declined_at.
create table if not exists public.friend_declines (
  user_id uuid not null,
  asker_id uuid not null,
  declined_at timestamptz not null default now(),
  primary key (user_id, asker_id)
);
create index if not exists friend_declines_asker_idx on public.friend_declines (asker_id, user_id);
insert into public.friend_declines (user_id, asker_id, declined_at)
select case when f.requested_by = f.user_lo then f.user_hi else f.user_lo end, f.requested_by,
       coalesce(f.responded_at, f.created_at)
  from public.friendships f where f.status = 'declined'
on conflict do nothing;

create index if not exists account_audit_pair_idx on public.account_audit (actor, target_user, action, at desc)
  where target_user is not null;

do $$
declare t text;
begin
  foreach t in array array['friend_email_asks', 'friend_declines'] loop
    execute format('alter table public.%I enable row level security', t);
    -- No policy: read and written only through the RPCs.
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ==================================================================== b_helpers
-- Email requests read `none` to the asker: they never learn whose address it was until that person accepts.
create or replace function t1_private.relation(p_me uuid, p_other uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when p_me = p_other then 'self'
    when exists (select 1 from public.user_blocks b where b.user_id = p_me and b.blocked_id = p_other) then 'blocked'
    when exists (select 1 from public.user_blocks b where b.user_id = p_other and b.blocked_id = p_me) then 'none'
    else coalesce((select case
                     when f.status = 'accepted' then 'friend'
                     when f.requested_by = p_me then case when f.via = 'email' then 'none' else 'requested' end
                     when f.status = 'pending' then 'incoming'
                     else 'none' end
                     from public.friendships f
                    where f.user_lo = least(p_me, p_other) and f.user_hi = greatest(p_me, p_other)), 'none') end;
$$;

-- Makes a pair friends (the row exists and isn't accepted yet): forgets declines and the asker's email ask.
create or replace function t1_private.friend_accept(p_me uuid, p_other uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare f public.friendships;
begin
  update public.friendships set status = 'accepted', responded_at = now()
   where user_lo = least(p_me, p_other) and user_hi = greatest(p_me, p_other)
  returning * into f;
  delete from public.friend_declines
   where (user_id = p_me and asker_id = p_other) or (user_id = p_other and asker_id = p_me);
  if f.email is not null then
    delete from public.friend_email_asks where user_id = f.requested_by and email = f.email;
  end if;
  perform t1_private.account_audit(p_me, 'friend.accepted', p_other);
  perform public.enqueue_notification('friend.accepted', null, array[p_other],
    jsonb_build_object('from_name', (select display_name from public.profiles where id = p_me), 'user_id', p_me));
end $$;

-- One request from p_me to p_other (a live account, not blocked by p_me). p_email set = asked by that address:
-- quiet, so nothing it does depends on whether or whose the account is (limits skip instead of raising, a request
-- they sent you is left alone). Returns 'requested' / 'friends', or null when the email ask did nothing.
create or replace function t1_private.friend_ask(p_me uuid, p_other uuid, p_email text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare
  f public.friendships;
  v_lo uuid := least(p_me, p_other);
  v_hi uuid := greatest(p_me, p_other);
  v_quiet boolean := p_email is not null;
  v_declined boolean;
  v_push boolean;
begin
  -- They blocked you: the same answer as a sent request, nothing written.
  if exists (select 1 from public.user_blocks b where b.user_id = p_other and b.blocked_id = p_me) then
    return 'requested';
  end if;

  select * into f from public.friendships where user_lo = v_lo and user_hi = v_hi for update;
  if f.status = 'accepted' then return 'friends'; end if;
  if f.requested_by = p_me and (v_quiet or f.via is distinct from 'email') then return 'requested'; end if;

  if (select count(*) from public.friendships x
       where (x.user_lo = p_me or x.user_hi = p_me) and x.status = 'accepted') >= 1000 then
    if v_quiet then return null; end if;
    raise exception 'You have 1000 friends, the most there can be' using errcode = '53400';
  end if;

  if f.user_lo is not null and f.requested_by <> p_me then
    -- They asked you (pending, or you declined it earlier): asking back makes you friends. Not by email, which
    -- would tell you whose address it is.
    if v_quiet then return null; end if;
    perform t1_private.friend_accept(p_me, p_other);
    return 'friends';
  end if;

  -- 30 asks an hour, and none while a moderator has restricted the account (t1_private.account_rate_limit, which
  -- 20261018190000_moderation.sql extends). Quiet asks (by email) say nothing either way.
  begin
    perform t1_private.account_rate_limit(p_me, 'friend.request', 30, interval '1 hour');
  exception when others then
    if v_quiet then return null; end if;
    raise;
  end;

  if f.user_lo is not null then
    -- Your email request, now asked by id (e.g. from their profile): it reads `requested` from here on. No new push.
    update public.friendships set via = null where user_lo = v_lo and user_hi = v_hi;
    perform t1_private.account_audit(p_me, 'friend.request', p_other, null,
      jsonb_build_object('via', null, 'pushed', false, 'was', 'email'));
    return 'requested';
  end if;

  -- Declined you in the last 90 days: the request sits declined (no push, nothing in their Requests).
  v_declined := exists (select 1 from public.friend_declines d
                         where d.user_id = p_other and d.asker_id = p_me and d.declined_at > now() - interval '90 days');
  -- At most 3 request pushes to one person in 30 days.
  v_push := not v_declined and (select count(*) from public.account_audit a
                                 where a.actor = p_me and a.target_user = p_other and a.action = 'friend.request'
                                   and a.at > now() - interval '30 days' and (a.after->>'pushed')::boolean) < 3;
  insert into public.friendships (user_lo, user_hi, requested_by, status, responded_at, via, email)
  values (v_lo, v_hi, p_me, case when v_declined then 'declined' else 'pending' end,
          case when v_declined then now() end, case when v_quiet then 'email' end, p_email);
  perform t1_private.account_audit(p_me, 'friend.request', p_other, null,
    jsonb_build_object('via', case when v_quiet then 'email' end, 'pushed', v_push));
  if v_push then
    perform public.enqueue_notification('friend.request', null, array[p_other],
      jsonb_build_object('from_name', (select display_name from public.profiles where id = p_me), 'user_id', p_me));
  end if;
  return 'requested';
end $$;

-- ==================================================================== c_friends
create or replace function public.friend_request(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
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
  return jsonb_build_object('status', t1_private.friend_ask(v_uid, p_user_id));
end $$;

-- By email: existing accounts only. The answer, and what Sent shows ({email, at}), never say whether the address
-- has an account or whose it is.
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
  if not exists (select 1 from public.friend_email_asks where user_id = v_uid and email = v_email)
     and (select count(*) from public.friend_email_asks where user_id = v_uid) >= 100 then
    raise exception 'Too many email requests waiting; cancel some first' using errcode = '53400';
  end if;
  perform t1_private.account_audit(v_uid, 'friend.email_lookup', null);
  insert into public.friend_email_asks (user_id, email) values (v_uid, v_email) on conflict do nothing;
  select u.id into v_target from auth.users u where lower(u.email) = v_email and u.deleted_at is null limit 1;
  if v_target is not null and v_target <> v_uid and t1_private.live_account(v_target)
     and not exists (select 1 from public.user_blocks b where b.user_id = v_uid and b.blocked_id = v_target) then
    perform t1_private.friend_ask(v_uid, v_target, v_email);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Cancels an email ask and the request it made, if any. {removed} says only whether you had asked that address.
create or replace function public.friend_cancel_email(p_email text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(trim(coalesce(p_email, '')));
  v_n integer;
  f public.friendships;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  delete from public.friend_email_asks where user_id = v_uid and email = v_email;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('removed', false); end if;
  delete from public.friendships
   where requested_by = v_uid and via = 'email' and email = v_email and status <> 'accepted'
  returning * into f;
  perform t1_private.account_audit(v_uid, 'friend.cancelled',
    case when f.user_lo = v_uid then f.user_hi else f.user_lo end,
    case when f.user_lo is not null then to_jsonb(f) end, jsonb_build_object('email', true));
  return jsonb_build_object('removed', true);
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
    perform t1_private.friend_accept(v_uid, p_user_id);
    return jsonb_build_object('status', 'friends');
  end if;
  if f.status = 'pending' then
    update public.friendships set status = 'declined', responded_at = now()
     where user_lo = f.user_lo and user_hi = f.user_hi;
    insert into public.friend_declines (user_id, asker_id) values (v_uid, p_user_id)
    on conflict (user_id, asker_id) do update set declined_at = now();
    perform t1_private.account_audit(v_uid, 'friend.declined', p_user_id);
  end if;
  return jsonb_build_object('status', 'declined');
end $$;

-- Cancels your request (pending or declined) or unfriends. A request someone else sent you is declined instead.
-- A request you made by email reads as nothing here (you cancel it by address, friend_cancel_email).
-- Cancelling keeps the decline (friend_declines), so asking again doesn't reach them.
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
  if f.status <> 'accepted' and f.requested_by = v_uid and f.via = 'email' then
    return jsonb_build_object('removed', false);
  end if;
  if f.status <> 'accepted' and f.requested_by <> v_uid then
    perform public.friend_respond(p_user_id, false);
    return jsonb_build_object('removed', false);
  end if;
  delete from public.friendships where user_lo = f.user_lo and user_hi = f.user_hi;
  perform t1_private.account_audit(v_uid, case when f.status = 'accepted' then 'friend.removed' else 'friend.cancelled' end,
                                   p_user_id, to_jsonb(f), null);
  return jsonb_build_object('removed', true);
end $$;

-- outgoing: requests by id as Person + at; every email ask as {email, at} (account or not), newest first.
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
  ), sent as (
    select p.person || jsonb_build_object('at', p.created_at) j, p.created_at at
      from p where p.status <> 'accepted' and p.requested_by = v_uid and p.via is distinct from 'email'
    union all
    select jsonb_build_object('email', a.email, 'at', a.created_at), a.created_at
      from public.friend_email_asks a where a.user_id = v_uid
  )
  select jsonb_build_object(
    'friends', coalesce((select jsonb_agg(p.person || jsonb_build_object('since', coalesce(p.responded_at, p.created_at))
                                          order by lower(p.display_name), p.other)
                           from p where p.status = 'accepted'), '[]'::jsonb),
    'incoming', coalesce((select jsonb_agg(p.person || jsonb_build_object('at', p.created_at) order by p.created_at desc)
                            from p where p.status = 'pending' and p.requested_by <> v_uid), '[]'::jsonb),
    'outgoing', coalesce((select jsonb_agg(s.j order by s.at desc, s.j->>'email', s.j->>'user_id') from sent s), '[]'::jsonb),
    'blocked', coalesce((select jsonb_agg(t1_private.person_json(b.blocked_id) order by b.created_at desc)
                           from public.user_blocks b where b.user_id = v_uid), '[]'::jsonb))
    into v;
  return v;
end $$;

-- ==================================================================== d_profile_value
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
      -- The collection's value is yours alone.
      v_sections := v_sections || jsonb_build_object('all_cards', coalesce(
        (select jsonb_build_object('cards', ls.total_qty, 'printings', ls.unique_printings)
                || case when v_level >= 3 then jsonb_build_object('value_usd', ls.value_usd) else '{}'::jsonb end
           from public.library_summary ls where ls.user_id = p_user_id),
        jsonb_build_object('cards', 0, 'printings', 0)
          || case when v_level >= 3 then jsonb_build_object('value_usd', 0) else '{}'::jsonb end));
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

-- ==================================================================== e_invites
-- Blocks either way (with the inviter or the event's creator) skip that person quietly: counted as invited, nothing
-- written, no push.
create or replace function public.invite_players(p_event_id uuid, p_user_ids uuid[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  v_id uuid;
  v_ids uuid[];
  v_sent uuid[] := '{}';
  v_quiet integer := 0;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can invite players' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id;
  if e.status not in ('setup', 'seated') then
    raise exception 'Players can only be added before play starts' using errcode = '22023';
  end if;
  select array_agg(distinct x) into v_ids from unnest(coalesce(p_user_ids, '{}')) x where x is not null and x <> v_uid;
  if coalesce(cardinality(v_ids), 0) = 0 then return jsonb_build_object('ok', true, 'invited', 0); end if;
  if cardinality(v_ids) > 50 then raise exception 'Invite up to 50 players at a time' using errcode = '22023'; end if;
  if (select count(*) from public.audit_log
       where actor_user = v_uid and action = 'event.invited' and at > now() - interval '1 hour')
     + cardinality(v_ids) > 100 then
    raise exception 'Too many invitations this hour, try again later' using errcode = '53400';
  end if;

  foreach v_id in array v_ids loop
    continue when not exists (select 1 from public.profiles pr
                               where pr.id = v_id and pr.deleted_at is null and (e.is_demo or not pr.is_demo));
    continue when exists (select 1 from public.participants p where p.event_id = e.id and p.user_id = v_id);
    if exists (select 1 from public.user_blocks b
                where (b.user_id = v_id and b.blocked_id in (v_uid, e.created_by))
                   or (b.blocked_id = v_id and b.user_id in (v_uid, e.created_by))) then
      v_quiet := v_quiet + 1;
      continue;
    end if;
    insert into public.event_invites as i (event_id, user_id, source, invited_by)
    values (e.id, v_id, 'owner_invite', v_uid)
    on conflict (event_id, user_id) do update
      set status = 'pending', source = 'owner_invite', invited_by = v_uid, created_at = now(), responded_at = null
      where i.status <> 'accepted';
    if found then
      v_sent := v_sent || v_id;
      insert into public.audit_log (event_id, actor_user, action, target_type, target_id)
      values (e.id, v_uid, 'event.invited', 'user', v_id);
    end if;
  end loop;

  if cardinality(v_sent) > 0 and not e.is_demo then
    perform public.enqueue_notification('event.invite', e.id, v_sent,
      jsonb_build_object('event_name', e.name, 'venue_name', e.venue_name, 'actions', jsonb_build_array('join', 'decline')));
  end if;
  return jsonb_build_object('ok', true, 'invited', cardinality(v_sent) + v_quiet);
end $$;

-- invite_by_email goes through invite_players, so it skips blocks the same way and still answers {ok: true}.

-- New events skip regulars with a block either way with the organizer.
create or replace function public._send_regulars_alert(p_event_id uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_users uuid[];
begin
  select * into e from public.events where id = p_event_id;
  if e.id is null or e.is_demo or e.visibility = 'private' or e.status not in ('setup', 'seated') then return 0; end if;
  select array_agg(distinct p.user_id) into v_users
    from public.participants p
    join public.events pe on pe.id = p.event_id
   where pe.created_by = e.created_by and pe.id <> e.id and not pe.is_demo
     and pe.created_at > now() - interval '90 days'
     and p.user_id is not null and p.user_id <> e.created_by
     and not exists (select 1 from public.participants x where x.event_id = e.id and x.user_id = p.user_id)
     and not exists (select 1 from public.event_invites i where i.event_id = e.id and i.user_id = p.user_id)
     and not exists (select 1 from public.notification_prefs np
                      where np.user_id = p.user_id and 'event.new' = any (np.muted_kinds))
     and not exists (select 1 from public.user_blocks b
                      where (b.user_id = p.user_id and b.blocked_id = e.created_by)
                         or (b.user_id = e.created_by and b.blocked_id = p.user_id));
  perform public.enqueue_notification('event.new', e.id, v_users,
    jsonb_build_object('event_name', e.name, 'venue_name', e.venue_name, 'format_label', e.format_label,
                       'starts_at', e.starts_at,
                       'organizer', (select pr.display_name from public.profiles pr where pr.id = e.created_by)));
  return coalesce(cardinality(v_users), 0);
end $$;
revoke execute on function public._send_regulars_alert(uuid) from public, anon, authenticated;

-- ==================================================================== f_delete_account
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
  delete from public.friend_email_asks where user_id = v_uid;
  delete from public.friend_declines where user_id = v_uid or asker_id = v_uid;
  delete from public.user_blocks where user_id = v_uid or blocked_id = v_uid;
  delete from public.share_settings where user_id = v_uid;
  delete from public.account_audit where actor = v_uid or target_user = v_uid;
  update public.scan_reports set user_id = null where user_id = v_uid;
end $$;

-- ==================================================================== g_grants
revoke execute on function t1_private.friend_ask(uuid, uuid, text) from public;
revoke execute on function t1_private.friend_accept(uuid, uuid) from public;
revoke execute on function public.friend_cancel_email(text) from public, anon;
grant execute on function public.friend_cancel_email(text) to authenticated;
