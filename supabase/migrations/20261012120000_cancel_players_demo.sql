-- Table 1 — cancel events, add players, TestFlight demo data, Events/Account summaries (2026-10-12)
-- Applied live as migrations p_cancel_demo_schema … u_demo_data (one section each).

-- =====================================================================================
-- p_cancel_demo_schema
-- =====================================================================================
alter table public.events drop constraint events_status_check;
alter table public.events add constraint events_status_check
  check (status = any (array['setup', 'seated', 'in_progress', 'completed', 'archived', 'cancelled']));

alter table public.events
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references auth.users(id) on delete set null,
  add column if not exists cancel_reason text,
  add column if not exists is_demo boolean not null default false,
  add column if not exists demo_owner uuid;          -- no FK: delete_account clears demo data first
alter table public.events add constraint events_cancel_reason_len
  check (cancel_reason is null or char_length(cancel_reason) <= 200);

alter table public.profiles
  add column if not exists is_demo boolean not null default false,
  add column if not exists demo_owner uuid;

-- Demo results are kept per match like real ones, but never reach the lifetime caches.
alter table public.match_outcomes add column if not exists is_demo boolean not null default false;

create index if not exists events_cancelled_by_idx on public.events (cancelled_by) where cancelled_by is not null;
create index if not exists events_demo_owner_idx on public.events (demo_owner) where is_demo;
create index if not exists profiles_demo_owner_idx on public.profiles (demo_owner) where is_demo;

-- Only cancel_event moves an event to cancelled, and nothing moves it back.
create or replace function public.events_status_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.status = 'cancelled' and new.status is distinct from 'cancelled' then
    raise exception 'That event was cancelled' using errcode = '22023';
  end if;
  if new.status = 'cancelled' and old.status is distinct from 'cancelled'
     and coalesce(current_setting('t1.cancel', true), '') <> 'on' then
    raise exception 'Use cancel_event to cancel an event' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger events_status_guard before update of status on public.events
  for each row execute function public.events_status_guard();

-- No new rounds once an event is over or cancelled (covers every client, including web-side pairing).
create or replace function public.rounds_event_open_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if exists (select 1 from public.events e
              where e.id = new.event_id and e.status in ('completed', 'archived', 'cancelled')) then
    raise exception 'That event is not running' using errcode = '22023';
  end if;
  return new;
end $$;

create trigger rounds_event_open_guard before insert on public.rounds
  for each row execute function public.rounds_event_open_guard();

-- =====================================================================================
-- q_records_demo_aware
-- =====================================================================================
create or replace function public.apply_match_outcomes(p_match_id uuid, p_reverse_only boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare
  m public.matches;
  r record;
  v_demo boolean;
begin
  for r in delete from public.match_outcomes where match_id = p_match_id returning * loop
    if not r.is_demo then
      perform public._add_outcome(r.user_id, r.opponent_id, -r.mw, -r.ml, -r.md, -r.bye, -r.gw, -r.gl, -r.gd, null);
    end if;
  end loop;

  if p_reverse_only then return; end if;
  select * into m from public.matches where id = p_match_id;
  if m.id is null or not (m.is_bye or m.status in ('reported', 'confirmed')) then return; end if;
  select coalesce(e.is_demo, false) into v_demo from public.events e where e.id = m.event_id;
  v_demo := coalesce(v_demo, false);

  for r in
    select s.user_id,
           (select o.user_id from public.match_sides o
             where o.match_id = s.match_id and o.side <> s.side and o.user_id is not null
             order by o.side limit 1) as opponent_id,
           s.game_wins as gw,
           coalesce((select sum(o.game_wins) from public.match_sides o
                      where o.match_id = s.match_id and o.side <> s.side), 0)::int as gl
      from public.match_sides s
     where s.match_id = p_match_id and s.user_id is not null
  loop
    if m.is_bye then
      insert into public.match_outcomes (match_id, user_id, opponent_id, event_id, bye, played_at, is_demo)
      values (m.id, r.user_id, null, m.event_id, 1, coalesce(m.reported_at, m.created_at), v_demo);
      if not v_demo then
        perform public._add_outcome(r.user_id, null, 0, 0, 0, 1, 0, 0, 0, coalesce(m.reported_at, m.created_at));
      end if;
    else
      insert into public.match_outcomes (match_id, user_id, opponent_id, event_id, mw, ml, md, gw, gl, gd, played_at, is_demo)
      values (m.id, r.user_id, r.opponent_id, m.event_id,
              (r.gw > r.gl)::int, (r.gw < r.gl)::int, (r.gw = r.gl)::int,
              r.gw, r.gl, m.game_draws, coalesce(m.reported_at, m.created_at), v_demo);
      if not v_demo then
        perform public._add_outcome(r.user_id, r.opponent_id,
                (r.gw > r.gl)::int, (r.gw < r.gl)::int, (r.gw = r.gl)::int, 0,
                r.gw, r.gl, m.game_draws, coalesce(m.reported_at, m.created_at));
      end if;
    end if;
  end loop;
end $$;

create or replace function public.records_drift()
returns table(user_id uuid, cached jsonb, derived jsonb)
language sql stable security definer set search_path = '' as $$
  with d as (
    select o.user_id, sum(o.mw)::int mw, sum(o.ml)::int ml, sum(o.md)::int md, sum(o.bye)::int bye,
           sum(o.gw)::int gw, sum(o.gl)::int gl, sum(o.gd)::int gd
      from public.match_outcomes o where not o.is_demo group by o.user_id)
  select coalesce(p.user_id, d.user_id),
         jsonb_build_array(p.match_wins, p.match_losses, p.match_draws, p.byes, p.game_wins, p.game_losses, p.game_draws),
         jsonb_build_array(d.mw, d.ml, d.md, d.bye, d.gw, d.gl, d.gd)
    from public.player_records p
    full join d on d.user_id = p.user_id
   where (coalesce(p.match_wins, 0), coalesce(p.match_losses, 0), coalesce(p.match_draws, 0), coalesce(p.byes, 0),
          coalesce(p.game_wins, 0), coalesce(p.game_losses, 0), coalesce(p.game_draws, 0))
         is distinct from
         (coalesce(d.mw, 0), coalesce(d.ml, 0), coalesce(d.md, 0), coalesce(d.bye, 0),
          coalesce(d.gw, 0), coalesce(d.gl, 0), coalesce(d.gd, 0));
$$;

-- =====================================================================================
-- r_cancel_event
-- =====================================================================================
create or replace function public.cancel_event(p_event_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  v_reason text := nullif(left(trim(coalesce(p_reason, '')), 200), '');
  v_players uuid[];
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can cancel this event' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id for update;
  if e.id is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if e.status = 'cancelled' then return jsonb_build_object('ok', true, 'already_cancelled', true); end if;
  if e.status not in ('setup', 'seated', 'in_progress') then
    raise exception 'That event has already finished' using errcode = '22023';
  end if;

  -- Close the open round and stop its clock. Recording it confirms results players already
  -- reported (the round-end rule); matches nobody reported stay unplayed and never count.
  update public.rounds
     set status = 'recorded', recorded_at = now(), timer_status = 'paused', timer_ends_at = null,
         timer_remaining_at_change = case
           when timer_status = 'running' and timer_last_started_at is not null
             then greatest(0, timer_remaining_at_change - extract(epoch from now() - timer_last_started_at)::int)
           else timer_remaining_at_change end
   where event_id = e.id and status = 'active';

  perform set_config('t1.cancel', 'on', true);
  update public.events
     set status = 'cancelled', cancelled_at = now(), cancelled_by = v_uid, cancel_reason = v_reason,
         discoverable_until = now(), updated_at = now()
   where id = e.id;
  perform set_config('t1.cancel', '', true);

  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, reason, before)
  values (e.id, v_uid, 'event.cancelled', 'event', e.id, v_reason, jsonb_build_object('status', e.status));

  if not e.is_demo then
    select array_agg(p.user_id) into v_players
      from public.participants p where p.event_id = e.id and p.user_id is not null and p.user_id <> v_uid;
    perform public.enqueue_notification('event.cancelled', e.id, v_players,
      jsonb_build_object('event_name', e.name, 'reason', v_reason));
  end if;
  return jsonb_build_object('ok', true, 'status', 'cancelled');
end $$;

-- Live Activities end when an event is cancelled, just as when it completes.
create or replace function public.live_on_events()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status in ('completed', 'archived', 'cancelled') and old.status is distinct from new.status then
    perform t1_private.live_dispatch('event_ended', new.id);
  elsif new.current_round is distinct from old.current_round and new.status = 'in_progress' then
    perform t1_private.live_dispatch('round_started', new.id);
  end if;
  return null;
end $$;

-- Demo events never push (TestFlight shows them from the app itself).
create or replace function t1_private.live_dispatch(p_kind text, p_event_id uuid, p_extra jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  if not exists (
    select 1 from public.participants p
      join public.live_activity_tokens t on t.user_id = p.user_id and t.revoked_at is null
     where p.event_id = p_event_id) then
    return;
  end if;
  if exists (select 1 from public.events e where e.id = p_event_id and e.is_demo) then return; end if;
  select value into v_secret from t1_private.settings where name = 'live_push_secret';
  perform net.http_post(
    url := 'https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/live-activity',
    body := jsonb_build_object('action', 'dispatch', 'kind', p_kind, 'event_id', p_event_id) || coalesce(p_extra, '{}'::jsonb),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-t1-secret', v_secret),
    timeout_milliseconds := 10000);
exception when others then
  raise warning 'live_dispatch skipped: %', sqlerrm;
end $$;

-- Joining a cancelled event is refused everywhere.
create or replace function public._seat_account(p_event_id uuid, p_user_id uuid, p_via text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_pid uuid;
  v_name text;
  v_pod uuid;
  v_seat int;
begin
  select * into e from public.events where id = p_event_id;
  if e.id is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if e.status = 'cancelled' then raise exception 'That event was cancelled' using errcode = '22023'; end if;
  if e.status in ('completed', 'archived') then raise exception 'That event has already finished' using errcode = '22023'; end if;

  select id into v_pid from public.participants where event_id = e.id and user_id = p_user_id;
  if v_pid is not null then
    return jsonb_build_object('event_id', e.id, 'participant_id', v_pid, 'already_joined', true);
  end if;

  perform pg_advisory_xact_lock(hashtextextended(e.id::text, 0));
  if e.capacity is not null and
     (select count(*) from public.participants p where p.event_id = e.id and p.status = 'active') >= e.capacity then
    raise exception 'That event is full' using errcode = '53400';
  end if;
  select coalesce(nullif(handle, ''), display_name) into v_name from public.profiles where id = p_user_id;
  select id into v_pod from public.pods where event_id = e.id order by display_order limit 1;
  select coalesce(max(seat), 0) + 1 into v_seat from public.participants where event_id = e.id;

  insert into public.participants (event_id, pod_id, user_id, display_name, seat)
  values (e.id, v_pod, p_user_id, v_name, v_seat) returning id into v_pid;
  update public.event_invites set status = 'accepted', responded_at = now()
   where event_id = e.id and user_id = p_user_id and status = 'pending';
  insert into public.audit_log (event_id, actor_user, actor_label, action, target_type, target_id, after)
  values (e.id, p_user_id, v_name, 'participant.joined', 'participant', v_pid, jsonb_build_object('via', p_via));
  return jsonb_build_object('event_id', e.id, 'participant_id', v_pid, 'seat', v_seat, 'already_joined', false);
end $$;

create or replace function public.join_event(p_code text, p_display_name text)
returns json language plpgsql security definer set search_path = 'public' as $$
declare
  v_event public.events;
  v_pod_id uuid;
  v_participant_id uuid;
  v_token text;
  v_seat int;
begin
  select * into v_event from public.events where upper(short_code) = upper(trim(p_code));
  if v_event.id is null then
    raise exception 'No event found with that code';
  end if;
  if v_event.status = 'cancelled' then
    raise exception 'That event was cancelled';
  end if;
  if v_event.status in ('completed','archived') then
    raise exception 'That event has already finished';
  end if;
  if length(trim(coalesce(p_display_name,''))) = 0 then
    raise exception 'A name is required';
  end if;

  select id into v_pod_id from public.pods where event_id = v_event.id order by display_order limit 1;
  select coalesce(max(seat), 0) + 1 into v_seat from public.participants where event_id = v_event.id;

  insert into public.participants (event_id, pod_id, user_id, display_name, seat)
  values (v_event.id, v_pod_id, auth.uid(), trim(p_display_name), v_seat)
  returning id into v_participant_id;

  insert into public.participant_tokens (participant_id) values (v_participant_id)
  returning token into v_token;

  insert into public.audit_log (event_id, actor_label, action, target_type, target_id)
  values (v_event.id, trim(p_display_name), 'participant.joined', 'participant', v_participant_id);

  return json_build_object(
    'event_id', v_event.id,
    'short_code', v_event.short_code,
    'participant_id', v_participant_id,
    'token', v_token
  );
end $$;

grant execute on function public.cancel_event(uuid, text) to authenticated;
revoke execute on function public.cancel_event(uuid, text) from anon, public;

-- =====================================================================================
-- s_add_players
-- =====================================================================================

-- People who've shared your events, most-shared first. Scoped to co-participants: the app
-- never browses all users. Already-seated players are left out; pending invites are flagged.
create or replace function public.suggested_players(
  p_event_id uuid, p_query text default null, p_limit integer default 30, p_include_demo boolean default false)
returns table(user_id uuid, display_name text, handle text, shared_events integer,
              last_shared_at timestamptz, invited boolean)
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
  )
  select co.uid, pr.display_name, pr.handle, co.n, co.last_at,
         exists (select 1 from public.event_invites i
                  where i.event_id = p_event_id and i.user_id = co.uid and i.status = 'pending')
    from co
    join public.profiles pr on pr.id = co.uid
   where pr.deleted_at is null
     and (p_include_demo or not pr.is_demo)
     and not exists (select 1 from public.participants x where x.event_id = p_event_id and x.user_id = co.uid)
     and (v_q is null or pr.display_name ilike '%' || v_q || '%' or coalesce(pr.handle, '') ilike '%' || v_q || '%')
   order by co.n desc, co.last_at desc nulls last, pr.display_name
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
end $$;

-- Invite several people at once. Invitations only: they accept from Events → Invitations.
create or replace function public.invite_players(p_event_id uuid, p_user_ids uuid[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  v_id uuid;
  v_ids uuid[];
  v_sent uuid[] := '{}';
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
  return jsonb_build_object('ok', true, 'invited', cardinality(v_sent));
end $$;

-- Single invite keeps working for older clients; same rules as invite_players.
create or replace function public.invite_to_event(p_event_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.invite_players(p_event_id, array[p_user_id]);
end $$;

-- Invite by email: existing accounts only, no email is sent. The answer is the same whether or
-- not the address has an account, so this can't be used to find out who's on Table 1.
create or replace function public.invite_by_email(p_event_id uuid, p_email text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(trim(coalesce(p_email, '')));
  v_target uuid;
  v_status text;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can invite players' using errcode = '42501';
  end if;
  select status into v_status from public.events where id = p_event_id;
  if v_status not in ('setup', 'seated') then
    raise exception 'Players can only be added before play starts' using errcode = '22023';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or length(v_email) > 254 then
    raise exception 'Enter a valid email address' using errcode = '22023';
  end if;
  perform public._rate_limit('invite.email_lookup', 20, interval '1 hour');
  insert into public.audit_log (event_id, actor_user, action, target_type)
  values (p_event_id, v_uid, 'invite.email_lookup', 'email');

  select u.id into v_target from auth.users u
   where lower(u.email) = v_email and u.deleted_at is null limit 1;
  if v_target is not null and v_target <> v_uid then
    perform public.invite_players(p_event_id, array[v_target]);
  end if;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function public.suggested_players(uuid, text, integer, boolean) to authenticated;
grant execute on function public.invite_players(uuid, uuid[]) to authenticated;
grant execute on function public.invite_by_email(uuid, text) to authenticated;
revoke execute on function public.suggested_players(uuid, text, integer, boolean) from anon, public;
revoke execute on function public.invite_players(uuid, uuid[]) from anon, public;
revoke execute on function public.invite_by_email(uuid, text) from anon, public;

-- =====================================================================================
-- t_home_account
-- =====================================================================================

-- Everything the Events tab needs in one call: your events bucketed live / upcoming / past,
-- the open round's clock and results progress, and pending invitations.
create or replace function public.events_home(p_include_demo boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_events jsonb;
  v_invites jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;

  with links as (
    select em.event_id, true as org, false as play from public.event_members em where em.user_id = v_uid
    union all
    select p.event_id, false, true from public.participants p where p.user_id = v_uid
  ), mine as (
    select l.event_id, bool_or(l.org) as organizing, bool_or(l.play) as playing
      from links l group by l.event_id
  ), evs as (
    select e.*, mine.organizing, mine.playing,
           case when e.status in ('seated', 'in_progress') then 'live'
                when e.status = 'setup' then 'upcoming' else 'past' end as bucket,
           (select r from public.rounds r where r.event_id = e.id and r.status = 'active'
             order by r.number desc limit 1) as open_round
      from mine join public.events e on e.id = mine.event_id
     where p_include_demo or not e.is_demo
  ), ranked as (
    select evs.*, row_number() over (partition by bucket
             order by case when bucket = 'past' then coalesce(cancelled_at, updated_at) end desc nulls last,
                      case when bucket <> 'past' then coalesce(starts_at, created_at) end asc nulls last) as n
      from evs
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'name', x.name, 'short_code', x.short_code, 'format', x.format, 'status', x.status,
           'bucket', x.bucket, 'organizing', x.organizing, 'playing', x.playing,
           'venue_name', x.venue_name, 'starts_at', x.starts_at, 'created_at', x.created_at,
           'number_of_rounds', x.number_of_rounds, 'current_round', x.current_round,
           'round_length_seconds', x.round_length_seconds, 'is_demo', x.is_demo,
           'cancelled_at', x.cancelled_at, 'cancel_reason', x.cancel_reason,
           'players', (select count(*) from public.participants p where p.event_id = x.id and p.status = 'active'),
           'my_status', (select p.status from public.participants p where p.event_id = x.id and p.user_id = v_uid),
           'round', case when (x.open_round).id is null then null else jsonb_build_object(
               'number', (x.open_round).number,
               'timer_status', (x.open_round).timer_status,
               'duration_seconds', (x.open_round).timer_duration_seconds,
               'ends_at', case when (x.open_round).timer_status = 'running' and (x.open_round).timer_last_started_at is not null
                               then (x.open_round).timer_last_started_at
                                    + make_interval(secs => (x.open_round).timer_remaining_at_change) end,
               'remaining_seconds', case when (x.open_round).timer_status = 'paused'
                                         then (x.open_round).timer_remaining_at_change end,
               'results_in', (select count(*) from public.matches m
                               where m.round_id = (x.open_round).id and not m.is_bye and m.status <> 'pending'),
               'matches', (select count(*) from public.matches m
                            where m.round_id = (x.open_round).id and not m.is_bye),
               'disputed', (select count(*) from public.matches m
                             where m.round_id = (x.open_round).id and m.disputed and m.status = 'reported')) end
         ) order by case x.bucket when 'live' then 0 when 'upcoming' then 1 else 2 end, x.n), '[]'::jsonb)
    into v_events
    from ranked x
   where x.bucket <> 'past' or x.n <= 50;

  select coalesce(jsonb_agg(jsonb_build_object(
           'event_id', e.id, 'name', e.name, 'format', e.format, 'status', e.status,
           'venue_name', e.venue_name, 'starts_at', e.starts_at, 'source', i.source,
           'invited_by', (select coalesce(nullif(pr.handle, ''), pr.display_name) from public.profiles pr where pr.id = i.invited_by),
           'players', (select count(*) from public.participants p where p.event_id = e.id and p.status = 'active'),
           'is_demo', e.is_demo, 'created_at', i.created_at
         ) order by i.created_at desc), '[]'::jsonb)
    into v_invites
    from public.event_invites i join public.events e on e.id = i.event_id
   where i.user_id = v_uid and i.status = 'pending'
     and e.status in ('setup', 'seated', 'in_progress')
     and (p_include_demo or not e.is_demo);

  return jsonb_build_object('events', v_events, 'invites', v_invites);
end $$;

-- The Account tab: profile, lifetime record and head-to-head, computed from per-match results so
-- the TestFlight view (with demo) and the real view (without) come from the same source.
create or replace function public.account_overview(p_include_demo boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_profile jsonb;
  v_record jsonb;
  v_h2h jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select jsonb_build_object('id', pr.id, 'display_name', pr.display_name, 'handle', pr.handle)
    into v_profile from public.profiles pr where pr.id = v_uid;

  select jsonb_build_object(
           'match_wins', coalesce(sum(o.mw), 0), 'match_losses', coalesce(sum(o.ml), 0),
           'match_draws', coalesce(sum(o.md), 0), 'byes', coalesce(sum(o.bye), 0),
           'game_wins', coalesce(sum(o.gw), 0), 'game_losses', coalesce(sum(o.gl), 0),
           'game_draws', coalesce(sum(o.gd), 0), 'events_played', count(distinct o.event_id),
           'last_played_at', max(o.played_at))
    into v_record
    from public.match_outcomes o
   where o.user_id = v_uid and (p_include_demo or not o.is_demo);

  select coalesce(jsonb_agg(h order by h.played desc, h.last_played_at desc nulls last), '[]'::jsonb)
    into v_h2h
    from (
      select o.opponent_id,
             coalesce(case when pr.deleted_at is null then coalesce(nullif(pr.handle, ''), pr.display_name) end,
                      'Deleted player') as name,
             sum(o.mw)::int as match_wins, sum(o.ml)::int as match_losses, sum(o.md)::int as match_draws,
             sum(o.gw)::int as game_wins, sum(o.gl)::int as game_losses,
             (sum(o.mw) + sum(o.ml) + sum(o.md))::int as played,
             max(o.played_at) as last_played_at
        from public.match_outcomes o
        left join public.profiles pr on pr.id = o.opponent_id
       where o.user_id = v_uid and o.opponent_id is not null and (p_include_demo or not o.is_demo)
       group by o.opponent_id, pr.deleted_at, pr.handle, pr.display_name
       order by played desc, last_played_at desc nulls last
       limit 50
    ) h;

  return jsonb_build_object('profile', v_profile, 'record', v_record, 'head_to_head', v_h2h);
end $$;

grant execute on function public.events_home(boolean) to authenticated;
grant execute on function public.account_overview(boolean) to authenticated;
revoke execute on function public.events_home(boolean) from anon, public;
revoke execute on function public.account_overview(boolean) from anon, public;

-- =====================================================================================
-- u_demo_data — TestFlight-only sample data on the caller's own account
-- =====================================================================================

-- One demo event shell: private, flagged, optionally organized by the owner, seated in order.
create or replace function t1_private.demo_event(
  p_owner uuid, p_name text, p_format text, p_rounds integer, p_minutes integer,
  p_organizer uuid, p_created timestamptz, p_starts timestamptz, p_players uuid[])
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_event uuid;
  v_pod uuid;
  i integer;
begin
  insert into public.events (short_code, name, format, status, number_of_rounds, round_length_seconds,
                             created_by, visibility, is_demo, demo_owner, created_at, updated_at, starts_at)
  values (public.generate_short_code(), p_name, p_format, 'setup', p_rounds, p_minutes * 60,
          p_organizer, 'private', true, p_owner, p_created, p_created, p_starts)
  returning id into v_event;
  if p_organizer is not null then
    insert into public.event_members (event_id, user_id, role) values (v_event, p_organizer, 'owner');
  end if;
  insert into public.pods (event_id, name, display_order) values (v_event, 'Pod 1', 0) returning id into v_pod;
  for i in 1 .. coalesce(cardinality(p_players), 0) loop
    insert into public.participants (event_id, pod_id, user_id, display_name, seat, created_at)
    select v_event, v_pod, pr.id, coalesce(nullif(pr.handle, ''), pr.display_name), i, p_created
      from public.profiles pr where pr.id = p_players[i];
  end loop;
  return v_event;
end $$;

-- One round: round-robin (circle method) pairings, results for everyone. The owner's own result
-- comes from p_my_result ("2-1", "1-1-1"…); on an active round the owner's match is left to report.
create or replace function t1_private.demo_round(
  p_event uuid, p_owner uuid, p_number integer, p_active boolean, p_my_result text,
  p_my_table integer, p_started timestamptz, p_others_reported integer)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_round uuid;
  v_pod uuid;
  v_ids uuid[];
  v_rot uuid[];
  v_me uuid;
  v_n integer;
  k integer;
  a uuid;
  b uuid;
  v_tmp uuid;
  v_match uuid;
  v_table integer;
  v_next integer := 1;
  v_res text;
  v_mine boolean;
  v_status text;
  v_done integer := 0;
  v_w integer;
  v_l integer;
  v_d integer;
  v_pool text[] := array['2-0', '2-1', '1-2', '0-2', '2-1', '2-0', '1-2', '1-1-1'];
  v_dur integer;
begin
  select * into e from public.events where id = p_event;
  v_dur := e.round_length_seconds;
  select id into v_pod from public.pods where event_id = p_event order by display_order limit 1;
  select array_agg(id order by seat) into v_ids from public.participants where event_id = p_event and status = 'active';
  select id into v_me from public.participants where event_id = p_event and user_id = p_owner;
  v_n := cardinality(v_ids);
  v_rot := array[v_ids[1]] ||
           (select array_agg(v_ids[2 + ((g + p_number - 1) % (v_n - 1))] order by g) from generate_series(0, v_n - 2) g);

  insert into public.rounds (event_id, number, status, timer_duration_seconds, timer_remaining_at_change,
                             timer_status, timer_last_started_at, started_at, recorded_at,
                             pairings_published_at, timer_ends_at)
  values (p_event, p_number, case when p_active then 'active' else 'recorded' end, v_dur,
          case when p_active then v_dur else (v_dur * 0.2)::int end,
          case when p_active then 'running' else 'paused' end,
          case when p_active then p_started end, p_started,
          case when p_active then null else p_started + make_interval(secs => (v_dur * 0.8)::int) end,
          p_started,
          case when p_active then p_started + make_interval(secs => v_dur) end)
  returning id into v_round;

  for k in 0 .. (v_n / 2) - 1 loop
    a := v_rot[k + 1];
    b := v_rot[v_n - k];
    v_mine := v_me is not null and v_me in (a, b);
    if v_mine and b = v_me then v_tmp := a; a := b; b := v_tmp; end if;   -- owner is always side 0
    if v_mine and p_my_table is not null then
      v_table := p_my_table;
    else
      if v_next = p_my_table then v_next := v_next + 1; end if;
      v_table := v_next;
      v_next := v_next + 1;
    end if;

    v_res := case when v_mine then p_my_result
                  else v_pool[1 + abs(hashtext(v_round::text || k::text)) % cardinality(v_pool)] end;
    if not p_active then
      v_status := 'confirmed';
    elsif v_mine then
      v_status := 'pending';
    elsif v_done < p_others_reported then
      v_status := 'confirmed';
      v_done := v_done + 1;
    else
      v_status := 'pending';
    end if;
    if v_status = 'pending' or v_res is null then
      v_w := 0; v_l := 0; v_d := 0;
    else
      v_w := split_part(v_res, '-', 1)::int;
      v_l := split_part(v_res, '-', 2)::int;
      v_d := coalesce(nullif(split_part(v_res, '-', 3), '')::int, 0);
    end if;

    insert into public.matches (event_id, round_id, pod_id, table_number, status, game_draws,
                                reported_at, result_source, created_at)
    values (p_event, v_round, v_pod, v_table, v_status, v_d,
            case when v_status <> 'pending' then p_started + make_interval(mins => 30 + k * 3) end,
            case when v_status <> 'pending' then 'player' end, p_started)
    returning id into v_match;
    insert into public.match_sides (match_id, participant_id, side, game_wins, event_id)
    values (v_match, a, 0, v_w, p_event), (v_match, b, 1, v_l, p_event);
  end loop;
  return v_round;
end $$;

-- Remove the caller's demo data (also run by delete_account).
create or replace function public.demo_remove()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_events integer;
  v_people integer;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  delete from public.events where is_demo and demo_owner = v_uid;
  get diagnostics v_events = row_count;
  delete from public.event_invites where invited_by in (select id from public.profiles where is_demo and demo_owner = v_uid);
  delete from public.head_to_head
   where opponent_id in (select id from public.profiles where is_demo and demo_owner = v_uid)
      or user_id in (select id from public.profiles where is_demo and demo_owner = v_uid);
  delete from public.player_records where user_id in (select id from public.profiles where is_demo and demo_owner = v_uid);
  delete from public.profiles where is_demo and demo_owner = v_uid;
  get diagnostics v_people = row_count;
  return jsonb_build_object('ok', true, 'events_removed', v_events, 'people_removed', v_people);
end $$;

-- (Re)build the caller's demo data: 12 sample opponents and 9 events covering every state.
-- Running it again replaces the old set, which also restarts the live round clocks.
create or replace function public.demo_seed()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_names text[] := array['Ava Chen', 'Marcus Reed', 'Priya Nair', 'Leo Park', 'Sofia Alvarez', 'Jonah Brooks',
                          'Mei Tanaka', 'Omar Haddad', 'Grace Kim', 'Theo Walsh', 'Nina Petrov', 'Sam Okafor'];
  p uuid[] := '{}';
  v_id uuid;
  v_ev uuid;
  i integer;
  v_now timestamptz := now();
  v_day timestamptz;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = v_uid and deleted_at is null) then
    raise exception 'Profile not found' using errcode = 'P0002';
  end if;
  perform public.demo_remove();

  for i in 1 .. cardinality(v_names) loop
    v_id := gen_random_uuid();
    insert into public.profiles (id, display_name, is_demo, demo_owner, created_at, updated_at)
    values (v_id, v_names[i], true, v_uid, v_now - interval '60 days', v_now - interval '60 days');
    p := p || v_id;
  end loop;

  -- Completed: Pauper Night (6 players, 3 rounds), 30 days ago.
  v_day := date_trunc('day', v_now) - interval '30 days' + interval '19 hours';
  v_ev := t1_private.demo_event(v_uid, 'Pauper Night', 'constructed', 3, 50, null, v_day - interval '5 days', v_day,
                                array[v_uid, p[1], p[2], p[5], p[9], p[12]]);
  perform t1_private.demo_round(v_ev, v_uid, 1, false, '1-1-1', null, v_day, 0);
  perform t1_private.demo_round(v_ev, v_uid, 2, false, '2-0', null, v_day + interval '55 minutes', 0);
  perform t1_private.demo_round(v_ev, v_uid, 3, false, '0-2', null, v_day + interval '110 minutes', 0);
  update public.events set status = 'completed', current_round = 3, updated_at = v_day + interval '3 hours' where id = v_ev;

  -- Completed: Prerelease Sealed (8 players, 4 rounds), 21 days ago.
  v_day := date_trunc('day', v_now) - interval '21 days' + interval '13 hours';
  v_ev := t1_private.demo_event(v_uid, 'Prerelease Sealed', 'sealed', 4, 50, null, v_day - interval '7 days', v_day,
                                array[v_uid, p[3], p[5], p[7], p[8], p[10], p[11], p[12]]);
  perform t1_private.demo_round(v_ev, v_uid, 1, false, '2-1', null, v_day, 0);
  perform t1_private.demo_round(v_ev, v_uid, 2, false, '0-2', null, v_day + interval '55 minutes', 0);
  perform t1_private.demo_round(v_ev, v_uid, 3, false, '1-2', null, v_day + interval '110 minutes', 0);
  perform t1_private.demo_round(v_ev, v_uid, 4, false, '2-0', null, v_day + interval '165 minutes', 0);
  update public.events set status = 'completed', current_round = 4, updated_at = v_day + interval '4 hours' where id = v_ev;

  -- Completed: Vintage Cube Night, you organized and won it, 14 days ago.
  v_day := date_trunc('day', v_now) - interval '14 days' + interval '18 hours';
  v_ev := t1_private.demo_event(v_uid, 'Vintage Cube Night', 'cube', 3, 50, v_uid, v_day - interval '6 days', v_day,
                                array[v_uid, p[1], p[2], p[4], p[6], p[8], p[9], p[11]]);
  perform t1_private.demo_round(v_ev, v_uid, 1, false, '2-0', null, v_day, 0);
  perform t1_private.demo_round(v_ev, v_uid, 2, false, '2-1', null, v_day + interval '55 minutes', 0);
  perform t1_private.demo_round(v_ev, v_uid, 3, false, '2-0', null, v_day + interval '110 minutes', 0);
  update public.events set status = 'completed', current_round = 3, updated_at = v_day + interval '3 hours' where id = v_ev;

  -- Completed: last week's league night.
  v_day := date_trunc('day', v_now) - interval '7 days' + interval '19 hours';
  v_ev := t1_private.demo_event(v_uid, 'Friday Cube League — Wk 6', 'cube', 3, 50, null, v_day - interval '6 days', v_day,
                                array[v_uid, p[1], p[2], p[3], p[4], p[5], p[6], p[7]]);
  perform t1_private.demo_round(v_ev, v_uid, 1, false, '2-0', null, v_day, 0);
  perform t1_private.demo_round(v_ev, v_uid, 2, false, '1-2', null, v_day + interval '55 minutes', 0);
  perform t1_private.demo_round(v_ev, v_uid, 3, false, '2-1', null, v_day + interval '110 minutes', 0);
  update public.events set status = 'completed', current_round = 3, updated_at = v_day + interval '3 hours' where id = v_ev;

  -- Cancelled: you called off a draft 3 days ago.
  v_day := v_now - interval '3 days';
  v_ev := t1_private.demo_event(v_uid, 'Rainy Day Draft', 'draft', 3, 50, v_uid, v_day - interval '4 days', v_day,
                                array[p[4], p[6]]);
  perform set_config('t1.cancel', 'on', true);
  update public.events set status = 'cancelled', cancelled_at = v_day - interval '2 hours', cancelled_by = v_uid,
         cancel_reason = 'Not enough players', updated_at = v_day - interval '2 hours' where id = v_ev;
  perform set_config('t1.cancel', '', true);

  -- Live, you're playing: round 3 of 4 running (started 12 minutes ago), your match at table 4 is unreported.
  v_day := v_now - interval '2 hours 2 minutes';
  v_ev := t1_private.demo_event(v_uid, 'Friday Cube League — Wk 7', 'cube', 4, 50, null, v_now - interval '6 days', v_day,
                                array[v_uid, p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9], p[10], p[11]]);
  perform t1_private.demo_round(v_ev, v_uid, 1, false, '2-1', null, v_day, 0);
  perform t1_private.demo_round(v_ev, v_uid, 2, false, '2-0', null, v_day + interval '55 minutes', 0);
  perform t1_private.demo_round(v_ev, v_uid, 3, true, null, 4, v_now - interval '12 minutes', 3);
  update public.events set status = 'in_progress', current_round = 3, updated_at = v_now - interval '12 minutes' where id = v_ev;

  -- Live, you're organizing: round 2 of 3, two of four results in.
  v_day := v_now - interval '1 hour 26 minutes';
  v_ev := t1_private.demo_event(v_uid, 'Thursday Draft', 'draft', 3, 50, v_uid, v_now - interval '3 days', v_day,
                                array[p[5], p[6], p[7], p[8], p[9], p[10], p[11], p[12]]);
  perform t1_private.demo_round(v_ev, v_uid, 1, false, null, null, v_day, 0);
  perform t1_private.demo_round(v_ev, v_uid, 2, true, null, null, v_now - interval '31 minutes', 2);
  update public.events set status = 'in_progress', current_round = 2, updated_at = v_now - interval '31 minutes' where id = v_ev;

  -- Upcoming, you're organizing: Sunday Sealed in two days, five signed up.
  v_day := date_trunc('day', v_now) + interval '2 days' + interval '13 hours';
  perform t1_private.demo_event(v_uid, 'Sunday Sealed', 'sealed', 4, 50, v_uid, v_now - interval '1 day', v_day,
                                array[p[1], p[3], p[4], p[8], p[10]]);

  -- Invitation: Marcus invited you to Modern Monthly tomorrow.
  v_day := date_trunc('day', v_now) + interval '1 day' + interval '18 hours 30 minutes';
  v_ev := t1_private.demo_event(v_uid, 'Modern Monthly', 'constructed', 3, 50, null, v_now - interval '2 days', v_day,
                                array[p[2], p[6], p[7], p[9]]);
  insert into public.event_invites (event_id, user_id, source, invited_by, created_at)
  values (v_ev, v_uid, 'owner_invite', p[2], v_now - interval '5 hours');

  return jsonb_build_object('ok', true, 'events', 9, 'people', cardinality(p));
end $$;

-- delete_account also clears the caller's demo data.
create or replace function public.delete_account()
returns void language plpgsql security definer set search_path = '' as $$
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
end $$;

revoke execute on function t1_private.demo_event(uuid, text, text, integer, integer, uuid, timestamptz, timestamptz, uuid[]) from anon, authenticated, public;
revoke execute on function t1_private.demo_round(uuid, uuid, integer, boolean, text, integer, timestamptz, integer) from anon, authenticated, public;
grant execute on function public.demo_seed() to authenticated;
grant execute on function public.demo_remove() to authenticated;
revoke execute on function public.demo_seed() from anon, public;
revoke execute on function public.demo_remove() from anon, public;
