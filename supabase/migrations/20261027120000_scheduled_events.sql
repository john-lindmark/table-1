-- Scheduled events, the sign-up link, player caps with a waitlist, top 8, automatic rounds, names
-- (contract/scheduled-events-2026-10-27.md). Additive: older builds keep working (they send none of the new fields).
--   a_columns    events.top_cut / auto_rounds, rounds.stage, event_waitlist (RPC-only)
--   b_rounds     t1_private.swiss_rounds and the triggers that keep number_of_rounds in step while auto
--   c_playoffs   no draws in playoff matches (checked where results are scored)
--   d_waitlist   seating from the waitlist, the link guard that allows it, event_sign_up / event_leave / admit / remove
--   e_joins      _seat_account (cap only for QR and nearby), join_event (full → waitlist), remove_participant moves up
--   f_create     create_event_v2 and update_event_details with the new fields, set_event_schedule
--   g_reads      event_preview_json, event_public (every round's matchups), event_bundle, events_home
--   i_decklists  decklists for constructed events (off | optional | required), submitted as text or from a deck
--   h_grants

-- ==================================================================== a_columns
alter table public.events
  add column if not exists top_cut integer not null default 0 check (top_cut in (0, 8)),
  add column if not exists auto_rounds boolean not null default false,
  add column if not exists decklists text not null default 'off' check (decklists in ('off', 'optional', 'required'));

-- One list per player per event: the text as the player gave it (or as their deck exported it) and its card counts.
-- Read and written only through the functions in i_decklists: the player sees their own, organizers see all.
create table if not exists public.event_decklists (
  participant_id uuid primary key references public.participants(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 20000),
  main_count integer not null,
  side_count integer not null,
  list_id uuid references public.card_lists(id) on delete set null,
  list_name text,
  submitted_by uuid references auth.users(id) on delete set null,
  submitted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists event_decklists_event_idx on public.event_decklists (event_id);
alter table public.event_decklists enable row level security;
revoke all on public.event_decklists from anon, authenticated;

alter table public.rounds
  add column if not exists stage text not null default 'swiss'
    check (stage in ('swiss', 'quarterfinal', 'semifinal', 'final'));

-- People waiting for a place in a full event, first come first served. Written only by the functions below.
create table if not exists public.event_waitlist (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null,
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
create index if not exists event_waitlist_order_idx on public.event_waitlist (event_id, created_at, user_id);
create index if not exists event_waitlist_user_idx on public.event_waitlist (user_id);
alter table public.event_waitlist enable row level security;
revoke all on public.event_waitlist from anon, authenticated;

-- ==================================================================== b_rounds
-- Swiss rounds for a number of players: enough to leave one undefeated player, then the MTR Appendix E bands above
-- 128 (not yet confirmed against the document). Clients carry the same table (testdata/scheduled-events/cases.json).
create or replace function t1_private.swiss_rounds(p_players integer)
returns integer language sql immutable set search_path = '' as $$
  select case when coalesce(p_players, 0) <= 2 then 1
              when p_players <= 4 then 2 when p_players <= 8 then 3 when p_players <= 16 then 4
              when p_players <= 32 then 5 when p_players <= 64 then 6 when p_players <= 128 then 7
              when p_players <= 226 then 8 when p_players <= 409 then 9 else 10 end
$$;

-- While no round is paired, an auto-rounds event's number_of_rounds follows its active players.
create or replace function t1_private.events_auto_rounds() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.auto_rounds and new.status in ('setup', 'seated')
     and not exists (select 1 from public.rounds r where r.event_id = new.id) then
    new.number_of_rounds := t1_private.swiss_rounds(
      (select count(*)::int from public.participants p where p.event_id = new.id and p.status = 'active'));
  end if;
  return new;
end $$;
drop trigger if exists events_auto_rounds on public.events;
create trigger events_auto_rounds
  before insert or update of auto_rounds, number_of_rounds, status on public.events
  for each row execute function t1_private.events_auto_rounds();

create or replace function t1_private.participants_auto_rounds() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_event uuid := coalesce(new.event_id, old.event_id);
  v_n integer;
begin
  select t1_private.swiss_rounds(count(*)::int) into v_n
    from public.participants p where p.event_id = v_event and p.status = 'active';
  update public.events e set number_of_rounds = v_n
   where e.id = v_event and e.auto_rounds and e.status in ('setup', 'seated') and e.number_of_rounds <> v_n
     and not exists (select 1 from public.rounds r where r.event_id = e.id);
  return null;
end $$;
drop trigger if exists participants_auto_rounds on public.participants;
create trigger participants_auto_rounds
  after insert or delete or update of status on public.participants
  for each row execute function t1_private.participants_auto_rounds();

-- ==================================================================== c_playoffs
-- apply_match_outcomes (from 20261012120000_cancel_players_demo) runs after every scored result: report_match and
-- set_match_result call it once both sides are written, and the table triggers call it for any other write. A playoff
-- result with equal game wins is refused there, which rolls back the whole call.
create or replace function public.apply_match_outcomes(p_match_id uuid, p_reverse_only boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare
  m public.matches;
  r record;
  v_demo boolean;
begin
  if not p_reverse_only and exists (
      select 1 from public.matches x join public.rounds rd on rd.id = x.round_id
       where x.id = p_match_id and rd.stage <> 'swiss' and not x.is_bye and x.status in ('reported', 'confirmed')
         and (select s.game_wins from public.match_sides s where s.match_id = x.id and s.side = 0)
             = (select s.game_wins from public.match_sides s where s.match_id = x.id and s.side = 1)) then
    raise exception 'Playoff matches need a winner' using errcode = '22023';
  end if;

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

-- ==================================================================== d_waitlist
-- participants_link_guard (from 20261017120000_rpc_only_event_writes) plus one more legitimate link: seating an
-- account from the waitlist, which that account asked for when it signed up.
create or replace function public.participants_link_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.user_id is null or new.user_id is not distinct from auth.uid() then return new; end if;
  if tg_op = 'UPDATE' and new.user_id is not distinct from old.user_id then return new; end if;
  if coalesce(current_setting('role', true), 'none') not in ('anon', 'authenticated') then return new; end if;
  if exists (select 1 from public.events e where e.id = new.event_id and e.is_demo) then return new; end if;
  if tg_op = 'INSERT' and exists (select 1 from public.event_waitlist w
                                   where w.event_id = new.event_id and w.user_id = new.user_id) then
    return new;
  end if;
  raise exception 'Players link their own account (claim, join or accept an invite)' using errcode = '42501';
end $$;

-- Before round 1 only: sign-ups and moving up stop once the event is under way.
create or replace function t1_private.sign_up_open(e public.events)
returns boolean language sql stable security definer set search_path = '' as $$
  select e.status in ('setup', 'seated') and not exists (select 1 from public.rounds r where r.event_id = e.id)
$$;

create or replace function t1_private.active_players(p_event_id uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.participants p where p.event_id = p_event_id and p.status = 'active'
$$;

create or replace function t1_private.waitlist_position(p_event_id uuid, p_user_id uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select x.n from (select w.user_id, row_number() over (order by w.created_at, w.user_id)::int n
                     from public.event_waitlist w where w.event_id = p_event_id) x
   where x.user_id = p_user_id
$$;

-- Seats one account from the waitlist (at the end of the list; unseated in a seated draft) and tells them.
create or replace function t1_private.seat_waitlisted(p_event_id uuid, p_user_id uuid, p_actor uuid, p_via text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  w public.event_waitlist;
  v_slot record;
  v_id uuid;
begin
  select * into e from public.events where id = p_event_id;
  select * into w from public.event_waitlist where event_id = p_event_id and user_id = p_user_id;
  if w.user_id is null then return null; end if;
  select * into v_slot from t1_private.next_slot(p_event_id, e.status);
  insert into public.participants (event_id, pod_id, user_id, display_name, seat)
  values (p_event_id, v_slot.pod_id, p_user_id, w.display_name, v_slot.seat) returning id into v_id;
  delete from public.event_waitlist where event_id = p_event_id and user_id = p_user_id;
  insert into public.audit_log (event_id, actor_user, actor_label, action, target_type, target_id, after)
  values (p_event_id, p_actor, w.display_name, 'participant.joined', 'participant', v_id,
          jsonb_build_object('via', p_via, 'waitlisted_at', w.created_at));
  perform public.enqueue_notification('event.waitlist_in', p_event_id, array[p_user_id],
    jsonb_build_object('event_name', e.name, 'starts_at', e.starts_at, 'venue_name', e.venue_name));
  return v_id;
end $$;

-- Fills every free place from the front of the line. Returns how many moved up.
create or replace function t1_private.waitlist_move_up(p_event_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_free integer;
  v_user uuid;
  v_n integer := 0;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text, 0));
  select * into e from public.events where id = p_event_id;
  if e.id is null or not t1_private.sign_up_open(e) then return 0; end if;
  v_free := case when e.capacity is null then 1000000 else e.capacity - t1_private.active_players(e.id) end;
  for v_user in select w.user_id from public.event_waitlist w where w.event_id = e.id
                 order by w.created_at, w.user_id limit greatest(v_free, 0) loop
    perform t1_private.seat_waitlisted(e.id, v_user, auth.uid(), 'waitlist');
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- The share link's Sign up. Seats you, or puts you on the waitlist when the event is full.
create or replace function public.event_sign_up(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  v_pid uuid;
  v_name text;
  v_slot record;
begin
  if v_uid is null then raise exception 'Sign in to sign up' using errcode = '28000'; end if;
  perform t1_private.rate_hit('event.sign_up', 20, 200, interval '10 minutes');
  select * into e from public.events where id = p_event_id;
  if e.id is null or e.is_demo or t1_private.event_access(e.id) = 'none' then
    raise exception 'That event isn''t available' using errcode = '42501';
  end if;
  if e.status = 'cancelled' then raise exception 'That event was cancelled' using errcode = '22023'; end if;
  if e.status in ('completed', 'archived') then raise exception 'That event has already finished' using errcode = '22023'; end if;

  select p.id into v_pid from public.participants p where p.event_id = e.id and p.user_id = v_uid
   order by p.created_at limit 1;
  if v_pid is not null then
    return jsonb_build_object('event_id', e.id, 'status', 'already_joined', 'participant_id', v_pid);
  end if;
  if exists (select 1 from public.event_waitlist w where w.event_id = e.id and w.user_id = v_uid) then
    return jsonb_build_object('event_id', e.id, 'status', 'already_waitlisted',
                              'position', t1_private.waitlist_position(e.id, v_uid));
  end if;
  if not t1_private.sign_up_open(e) then
    raise exception 'Sign-ups are closed' using errcode = '55000';
  end if;

  select left(coalesce(nullif(trim(pr.display_name), ''), nullif(trim(pr.handle), ''), 'Player'), 40) into v_name
    from public.profiles pr where pr.id = v_uid;
  v_name := coalesce(v_name, 'Player');

  perform pg_advisory_xact_lock(hashtextextended(e.id::text, 0));
  if e.capacity is not null and t1_private.active_players(e.id) >= e.capacity then
    insert into public.event_waitlist (event_id, user_id, display_name) values (e.id, v_uid, v_name)
    on conflict do nothing;
    insert into public.audit_log (event_id, actor_user, actor_label, action, target_type, target_id, after)
    values (e.id, v_uid, v_name, 'waitlist.joined', 'event', e.id, jsonb_build_object('via', 'link'));
    return jsonb_build_object('event_id', e.id, 'status', 'waitlisted',
                              'position', t1_private.waitlist_position(e.id, v_uid));
  end if;

  select * into v_slot from t1_private.next_slot(e.id, e.status);
  insert into public.participants (event_id, pod_id, user_id, display_name, seat)
  values (e.id, v_slot.pod_id, v_uid, v_name, v_slot.seat) returning id into v_pid;
  update public.event_invites set status = 'accepted', responded_at = now()
   where event_id = e.id and user_id = v_uid and status = 'pending';
  insert into public.audit_log (event_id, actor_user, actor_label, action, target_type, target_id, after)
  values (e.id, v_uid, v_name, 'participant.joined', 'participant', v_pid, jsonb_build_object('via', 'link'));
  return jsonb_build_object('event_id', e.id, 'status', 'joined', 'participant_id', v_pid);
end $$;

-- Leave before round 1: your seat or your place on the waitlist. The next person moves up.
create or replace function public.event_leave(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  p public.participants;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into e from public.events where id = p_event_id for update;
  if e.id is null then raise exception 'That event isn''t available' using errcode = '42501'; end if;

  if exists (select 1 from public.event_waitlist w where w.event_id = e.id and w.user_id = v_uid) then
    delete from public.event_waitlist where event_id = e.id and user_id = v_uid;
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id)
    values (e.id, v_uid, 'waitlist.left', 'event', e.id);
    return jsonb_build_object('event_id', e.id, 'status', 'left_waitlist');
  end if;

  select * into p from public.participants where event_id = e.id and user_id = v_uid order by created_at limit 1;
  if p.id is null then return jsonb_build_object('event_id', e.id, 'status', 'not_in'); end if;
  if not t1_private.sign_up_open(e) then
    raise exception 'The event has started: ask the organizer to drop you' using errcode = '55000';
  end if;
  delete from public.participants where id = p.id;
  if p.seat is not null then
    update public.participants set seat = seat - 1
     where event_id = p.event_id and seat > p.seat and pod_id is not distinct from p.pod_id;
  end if;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before)
  values (e.id, v_uid, 'participant.left', 'participant', p.id,
          jsonb_build_object('name', p.display_name, 'seat', p.seat, 'pod_id', p.pod_id));
  perform t1_private.waitlist_move_up(e.id);
  return jsonb_build_object('event_id', e.id, 'status', 'left');
end $$;

-- Organizer: seat someone from the waitlist now, past the cap.
create or replace function public.waitlist_admit(p_event_id uuid, p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_pid uuid;
begin
  perform t1_private.assert_setup_organizer(p_event_id);
  v_pid := t1_private.seat_waitlisted(p_event_id, p_user_id, auth.uid(), 'admitted');
  if v_pid is null then
    select p.id into v_pid from public.participants p where p.event_id = p_event_id and p.user_id = p_user_id limit 1;
    if v_pid is null then raise exception 'They aren''t on the waitlist' using errcode = 'P0002'; end if;
  end if;
  return jsonb_build_object('event_id', p_event_id, 'participant_id', v_pid);
end $$;

create or replace function public.waitlist_remove(p_event_id uuid, p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  w public.event_waitlist;
begin
  perform t1_private.assert_setup_organizer(p_event_id);
  delete from public.event_waitlist where event_id = p_event_id and user_id = p_user_id returning * into w;
  if w.user_id is not null then
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before)
    values (p_event_id, auth.uid(), 'waitlist.removed', 'event', p_event_id,
            jsonb_build_object('user_id', w.user_id, 'name', w.display_name));
  end if;
  return jsonb_build_object('event_id', p_event_id, 'removed', w.user_id is not null);
end $$;

-- ==================================================================== e_joins
-- _seat_account (from 20261012120000_cancel_players_demo): the cap now applies only to the QR and nearby joins.
-- Accepted invites come from the organizer, who may seat people past the cap.
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
  if p_via in ('qr', 'nearby') and e.capacity is not null
     and t1_private.active_players(e.id) >= e.capacity then
    raise exception 'That event is full' using errcode = '53400';
  end if;
  select coalesce(nullif(handle, ''), display_name) into v_name from public.profiles where id = p_user_id;
  select id into v_pod from public.pods where event_id = e.id order by display_order limit 1;
  select coalesce(max(seat), 0) + 1 into v_seat from public.participants where event_id = e.id;

  insert into public.participants (event_id, pod_id, user_id, display_name, seat)
  values (e.id, v_pod, p_user_id, v_name, v_seat) returning id into v_pid;
  delete from public.event_waitlist where event_id = e.id and user_id = p_user_id;
  update public.event_invites set status = 'accepted', responded_at = now()
   where event_id = e.id and user_id = p_user_id and status = 'pending';
  insert into public.audit_log (event_id, actor_user, actor_label, action, target_type, target_id, after)
  values (e.id, p_user_id, v_name, 'participant.joined', 'participant', v_pid, jsonb_build_object('via', p_via));
  return jsonb_build_object('event_id', e.id, 'participant_id', v_pid, 'seat', v_seat, 'already_joined', false);
end $$;

-- join_event (from 20261018170000_privacy_lockdown) plus the cap: a full event puts a signed-in caller on the
-- waitlist and says so; signed-out guests are told it's full. Both are results, not errors, like the other refusals.
create or replace function public.join_event(p_code text, p_display_name text)
returns json language plpgsql security definer set search_path = 'public' as $$
declare
  v_event public.events;
  v_pod_id uuid;
  v_participant_id uuid;
  v_token text;
  v_seat int;
  v_refuse text;
  v_name text;
  v_pos int;
begin
  if length(trim(coalesce(p_display_name,''))) = 0 then
    raise exception 'A name is required';
  end if;
  perform t1_private.rate_hit('join.code', 20, 200, interval '10 minutes');
  if t1_private.rate_over('code.miss', 20, 60, interval '10 minutes') then
    raise exception 'Too many tries, wait a few minutes' using errcode = '53400';
  end if;
  select * into v_event from public.events where upper(short_code) = upper(trim(coalesce(p_code, '')));
  v_refuse := case
    when v_event.id is null then 'not_found'
    when v_event.status = 'cancelled' then 'cancelled'
    when v_event.status in ('completed','archived') then 'finished'
    when v_event.visibility = 'private'
         and t1_private.event_access(v_event.id) not in ('organizer', 'player', 'invited') then 'private'
    end;
  if v_refuse is not null then
    perform t1_private.rate_hit('code.miss', 1000000, 1000000, interval '10 minutes');
    return json_build_object('error', v_refuse, 'message', case v_refuse
      when 'cancelled' then 'That event was cancelled'
      when 'finished' then 'That event has already finished'
      when 'private' then 'Ask the organizer for an invite'
      else 'No event found with that code' end);
  end if;

  if auth.uid() is not null then
    select p.id, t.token into v_participant_id, v_token
      from public.participants p left join public.participant_tokens t on t.participant_id = p.id
     where p.event_id = v_event.id and p.user_id = auth.uid()
     order by p.created_at limit 1;
    if v_participant_id is not null then
      if v_token is null then
        insert into public.participant_tokens (participant_id) values (v_participant_id) returning token into v_token;
      end if;
      return json_build_object('event_id', v_event.id, 'short_code', v_event.short_code,
                               'participant_id', v_participant_id, 'token', v_token, 'already_joined', true);
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_event.id::text, 0));
  if v_event.capacity is not null and t1_private.active_players(v_event.id) >= v_event.capacity then
    if auth.uid() is null or not t1_private.sign_up_open(v_event) then
      return json_build_object('error', 'full', 'message', 'This event is full');
    end if;
    v_name := left(trim(p_display_name), 40);
    insert into public.event_waitlist (event_id, user_id, display_name) values (v_event.id, auth.uid(), v_name)
    on conflict do nothing;
    if found then
      insert into public.audit_log (event_id, actor_user, actor_label, action, target_type, target_id, after)
      values (v_event.id, auth.uid(), v_name, 'waitlist.joined', 'event', v_event.id, jsonb_build_object('via', 'code'));
    end if;
    v_pos := t1_private.waitlist_position(v_event.id, auth.uid());
    return json_build_object('error', 'full', 'waitlisted', true, 'position', v_pos, 'event_id', v_event.id,
      'message', 'This event is full. You''re number ' || v_pos || ' on the waitlist.');
  end if;

  select id into v_pod_id from public.pods where event_id = v_event.id order by display_order limit 1;
  select coalesce(max(seat), 0) + 1 into v_seat from public.participants where event_id = v_event.id;

  insert into public.participants (event_id, pod_id, user_id, display_name, seat)
  values (v_event.id, v_pod_id, auth.uid(), trim(p_display_name), v_seat)
  returning id into v_participant_id;
  if auth.uid() is not null then
    delete from public.event_waitlist where event_id = v_event.id and user_id = auth.uid();
  end if;

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

-- remove_participant (from 20261016130000_create_event_players_clock) plus: the freed place goes to the waitlist.
create or replace function public.remove_participant(p_participant_id uuid)
returns json language plpgsql security definer set search_path = '' as $$
declare
  p public.participants;
begin
  select * into p from public.participants where id = p_participant_id;
  if p.id is null then raise exception 'That player isn''t in the event' using errcode = 'P0002'; end if;
  perform t1_private.assert_setup_organizer(p.event_id);
  delete from public.participants where id = p.id;
  if p.seat is not null then
    update public.participants set seat = seat - 1
     where event_id = p.event_id and seat > p.seat and pod_id is not distinct from p.pod_id;
  end if;
  if p.user_id is not null then
    delete from public.event_invites where event_id = p.event_id and user_id = p.user_id and status = 'pending';
  end if;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before)
  values (p.event_id, auth.uid(), 'participant.removed', 'participant', p.id,
          jsonb_build_object('name', p.display_name, 'user_id', p.user_id, 'seat', p.seat, 'pod_id', p.pod_id));
  perform t1_private.waitlist_move_up(p.event_id);
  return json_build_object('event_id', p.event_id, 'participant_id', p.id);
end $$;

-- ==================================================================== f_create
-- Top cut and automatic rounds are for Swiss events of players (not team events or round robin).
create or replace function t1_private.check_cut_rounds(p_team boolean, p_pairing text, p_top_cut integer,
  p_auto_rounds boolean)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if coalesce(p_top_cut, 0) not in (0, 8) then
    raise exception 'Top cut is none or top 8' using errcode = '22023';
  end if;
  if coalesce(p_top_cut, 0) > 0 and (p_team or p_pairing <> 'swiss') then
    raise exception 'Top 8 is for Swiss events' using errcode = '22023';
  end if;
  if coalesce(p_auto_rounds, false) and (p_team or p_pairing <> 'swiss') then
    raise exception 'Automatic rounds are for Swiss events' using errcode = '22023';
  end if;
end $$;

create or replace function t1_private.check_schedule(p_starts_at timestamptz, p_venue_name text, p_capacity integer)
returns void language plpgsql stable set search_path = '' as $$
begin
  if p_starts_at is not null and (p_starts_at < now() - interval '1 day' or p_starts_at > now() + interval '366 days') then
    raise exception 'Pick a time within a year' using errcode = '22023';
  end if;
  if char_length(coalesce(trim(p_venue_name), '')) > 80 then
    raise exception 'Venue names are up to 80 characters' using errcode = '22023';
  end if;
  if p_capacity is not null and p_capacity not between 2 and 10000 then
    raise exception 'Caps are 2 to 10000 players' using errcode = '22023';
  end if;
end $$;

create or replace function t1_private.check_decklists(p_limited boolean, p_decklists text)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if coalesce(p_decklists, 'off') not in ('off', 'optional', 'required') then
    raise exception 'Decklists are off, optional or required' using errcode = '22023';
  end if;
  if p_limited and coalesce(p_decklists, 'off') <> 'off' then
    raise exception 'Decklists are for constructed events' using errcode = '22023';
  end if;
end $$;

-- create_event_v2 (from 20261016220000_roto) plus a typed name, schedule, venue, cap, top cut and auto rounds.
drop function if exists public.create_event_v2(text, text, integer, integer, text, text, text, text, integer, text, text[], boolean, boolean, date, text);
create or replace function public.create_event_v2(p_name text default null, p_format_name text default null,
  p_rounds integer default null, p_round_seconds integer default 3000, p_set_code text default null,
  p_set_name text default null, p_cube_name text default null, p_cube_url text default null,
  p_team_size integer default null, p_format_other text default null, p_player_names text[] default '{}',
  p_include_me boolean default true, p_show_clock boolean default true, p_local_date date default null,
  p_pairing text default null, p_starts_at timestamptz default null, p_venue_name text default null,
  p_capacity integer default null, p_top_cut integer default 0, p_auto_rounds boolean default false,
  p_decklists text default 'off')
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_team boolean := p_format_name in ('team_draft', 'team_sealed');
  v_limited boolean := p_format_name in ('draft', 'team_draft', 'sealed', 'team_sealed', 'roto');
  v_roto boolean := p_format_name = 'roto';
  v_pairing text := case when p_format_name = 'roto' then coalesce(p_pairing, 'round_robin') else 'swiss' end;
  v_name text := nullif(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), '');
  v_set_name text;
  v_res json;
  v_id uuid;
  v_pod uuid;
  v_me text;
begin
  if v_uid is null then raise exception 'Sign in required to create an event' using errcode = '28000'; end if;
  if p_format_name is null or p_format_name not in ('standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper',
      'premodern', 'canadian_highlander', 'other_constructed', 'draft', 'team_draft', 'sealed', 'team_sealed', 'roto') then
    raise exception 'Pick a format' using errcode = '22023';
  end if;
  if v_team and coalesce(p_team_size, 0) not in (3, 4) then
    raise exception 'Teams have 3 or 4 players' using errcode = '22023';
  end if;
  if not v_limited and (p_set_code is not null or p_cube_name is not null) then
    raise exception 'Sets and cubes are for limited events' using errcode = '22023';
  end if;
  if p_set_code is not null and p_cube_name is not null then
    raise exception 'Pick a set or a cube, not both' using errcode = '22023';
  end if;
  if v_roto and nullif(trim(p_cube_name), '') is null then
    raise exception 'A roto is drafted from a cube' using errcode = '22023';
  end if;
  if p_pairing is not null and p_pairing not in ('swiss', 'round_robin') then
    raise exception 'Pick Swiss or round robin' using errcode = '22023';
  end if;
  if p_pairing = 'round_robin' and not v_roto then
    raise exception 'Round robin is for roto events for now' using errcode = '22023';
  end if;
  if v_name is not null and char_length(v_name) > 80 then
    raise exception 'Name the event (up to 80 characters)' using errcode = '22023';
  end if;
  perform t1_private.check_cut_rounds(v_team, v_pairing, p_top_cut, p_auto_rounds);
  perform t1_private.check_schedule(p_starts_at, p_venue_name, p_capacity);
  perform t1_private.check_decklists(v_limited, p_decklists);
  if p_set_code is not null then
    select s.name into v_set_name from public.mtg_sets s where s.code = lower(p_set_code);
    v_set_name := coalesce(v_set_name, nullif(trim(p_set_name), ''), upper(p_set_code));
  elsif v_limited and p_cube_name is null then
    v_set_name := left(nullif(trim(p_set_name), ''), 80);
  end if;

  v_res := public.create_event(
    'New event',
    case when not v_limited then 'constructed' when p_format_name in ('sealed', 'team_sealed') then 'sealed'
         when p_cube_name is not null then 'cube' else 'draft' end,
    coalesce(p_rounds, 3), 3000, coalesce(p_player_names, '{}'));
  v_id := (v_res->>'event_id')::uuid;

  update public.events
     set format_name = p_format_name,
         format_other = case when p_format_name = 'other_constructed' then nullif(trim(p_format_other), '') end,
         set_code = lower(p_set_code), set_name = v_set_name,
         cube_name = nullif(trim(p_cube_name), ''), cube_url = nullif(trim(p_cube_url), ''),
         team_size = case when v_team then p_team_size end,
         show_clock = coalesce(p_show_clock, true),
         name_date = coalesce(p_local_date, (coalesce(p_starts_at, now()) at time zone 'utc')::date),
         auto_name = v_name is null,
         name = coalesce(v_name, name),
         starts_at = p_starts_at,
         venue_name = nullif(trim(p_venue_name), ''),
         capacity = p_capacity,
         top_cut = coalesce(p_top_cut, 0),
         auto_rounds = coalesce(p_auto_rounds, false),
         decklists = coalesce(p_decklists, 'off')
   where id = v_id;
  if v_roto then
    update public.events set pairing = v_pairing where id = v_id;
    insert into public.roto_drafts (event_id) values (v_id) on conflict do nothing;
  end if;

  if coalesce(p_include_me, true) then
    select coalesce(nullif(trim(pr.display_name), ''), nullif(trim(pr.handle), ''), 'Organizer') into v_me
      from public.profiles pr where pr.id = v_uid;
    select d.id into v_pod from public.pods d where d.event_id = v_id order by d.display_order limit 1;
    update public.participants set seat = seat + 1 where event_id = v_id and seat is not null;
    insert into public.participants (event_id, pod_id, user_id, display_name, seat)
    values (v_id, v_pod, v_uid, left(coalesce(v_me, 'Organizer'), 40), 1);
  end if;
  return v_res;
end $$;

-- update_event_details (from 20261016220000_roto) plus top cut, auto rounds and names on every event (p_auto_name;
-- calls without it keep the old rule, see the contract §1).
drop function if exists public.update_event_details(uuid, text, text, integer, integer, text, text, text, text, integer, text, boolean, text);
create or replace function public.update_event_details(p_event_id uuid, p_name text, p_format_name text,
  p_rounds integer, p_round_seconds integer default 3000, p_set_code text default null, p_set_name text default null,
  p_cube_name text default null, p_cube_url text default null, p_team_size integer default null,
  p_format_other text default null, p_show_clock boolean default null, p_pairing text default null,
  p_top_cut integer default null, p_auto_rounds boolean default null, p_auto_name boolean default null,
  p_decklists text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  v_team boolean := p_format_name in ('team_draft', 'team_sealed');
  v_limited boolean := p_format_name in ('draft', 'team_draft', 'sealed', 'team_sealed', 'roto');
  v_roto boolean := p_format_name = 'roto';
  v_set_name text;
  v_name text := nullif(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), '');
  v_auto boolean;
  v_pairing text;
  v_top_cut integer;
  v_auto_rounds boolean;
  v_decklists text;
  v_before jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into e from public.events where id = p_event_id for update;
  if e.id is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can change the event' using errcode = '42501';
  end if;
  if e.status not in ('setup', 'seated') or exists (select 1 from public.rounds r where r.event_id = p_event_id) then
    raise exception 'Details lock once round 1 is paired' using errcode = '55000';
  end if;
  if exists (select 1 from public.roto_drafts d where d.event_id = p_event_id and d.started_at is not null)
     and (not v_roto or nullif(trim(p_cube_name), '') is distinct from e.cube_name) then
    raise exception 'The format and cube lock once the draft starts' using errcode = '55000';
  end if;
  v_auto := case when p_auto_name is not null then p_auto_name else e.auto_name end;
  if not v_auto and (v_name is null or char_length(v_name) > 80) then
    raise exception 'Name the event (up to 80 characters)' using errcode = '22023';
  end if;
  if p_format_name is null or p_format_name not in ('standard', 'pioneer', 'modern', 'legacy', 'vintage', 'pauper',
      'premodern', 'canadian_highlander', 'other_constructed', 'draft', 'team_draft', 'sealed', 'team_sealed', 'roto') then
    raise exception 'Pick a format' using errcode = '22023';
  end if;
  if v_team and coalesce(p_team_size, 0) not in (3, 4) then
    raise exception 'Teams have 3 or 4 players' using errcode = '22023';
  end if;
  if not v_limited and (p_set_code is not null or p_cube_name is not null) then
    raise exception 'Sets and cubes are for limited events' using errcode = '22023';
  end if;
  if p_set_code is not null and p_cube_name is not null then
    raise exception 'Pick a set or a cube, not both' using errcode = '22023';
  end if;
  if v_roto and nullif(trim(p_cube_name), '') is null then
    raise exception 'A roto is drafted from a cube' using errcode = '22023';
  end if;
  if p_pairing is not null and p_pairing not in ('swiss', 'round_robin') then
    raise exception 'Pick Swiss or round robin' using errcode = '22023';
  end if;
  if p_pairing = 'round_robin' and not v_roto then
    raise exception 'Round robin is for roto events for now' using errcode = '22023';
  end if;
  if coalesce(p_rounds, 0) not between 1 and 15 then
    raise exception 'Rounds must be 1 to 15' using errcode = '22023';
  end if;
  v_pairing := case when v_roto then coalesce(p_pairing, case when e.format_name = 'roto' then e.pairing end, 'round_robin')
                    else 'swiss' end;
  -- Kept values that no longer fit the format (a roto or team event) quietly fall back; sent ones are checked.
  v_top_cut := coalesce(p_top_cut, case when v_team or v_pairing <> 'swiss' then 0 else e.top_cut end);
  v_auto_rounds := coalesce(p_auto_rounds, e.auto_rounds and not v_team and v_pairing = 'swiss');
  perform t1_private.check_cut_rounds(v_team, v_pairing, v_top_cut, v_auto_rounds);
  v_decklists := coalesce(p_decklists, case when v_limited then 'off' else e.decklists end);
  perform t1_private.check_decklists(v_limited, v_decklists);
  if p_set_code is not null then
    select s.name into v_set_name from public.mtg_sets s where s.code = lower(p_set_code);
    v_set_name := coalesce(v_set_name, nullif(trim(p_set_name), ''), upper(p_set_code));
  elsif v_limited and p_cube_name is null then
    v_set_name := left(nullif(trim(p_set_name), ''), 80);
  end if;

  v_before := jsonb_build_object('name', e.name, 'auto_name', e.auto_name, 'decklists', e.decklists, 'format_name', e.format_name,
    'rounds', e.number_of_rounds, 'show_clock', e.show_clock, 'set_code', e.set_code, 'cube_name', e.cube_name,
    'team_size', e.team_size, 'pairing', e.pairing, 'top_cut', e.top_cut, 'auto_rounds', e.auto_rounds);

  update public.events
     set name = case when v_auto then e.name else v_name end,
         auto_name = v_auto,
         format_name = p_format_name,
         format_other = case when p_format_name = 'other_constructed' then left(nullif(trim(p_format_other), ''), 40) end,
         set_code = lower(p_set_code),
         set_name = v_set_name,
         cube_name = case when v_limited then nullif(trim(p_cube_name), '') end,
         cube_url = case when v_limited and nullif(trim(p_cube_name), '') is not null then nullif(trim(p_cube_url), '') end,
         team_size = case when v_team then p_team_size end,
         number_of_rounds = p_rounds,
         round_length_seconds = 3000,
         show_clock = coalesce(p_show_clock, e.show_clock),
         pairing = v_pairing,
         top_cut = v_top_cut,
         auto_rounds = v_auto_rounds,
         decklists = v_decklists,
         updated_at = now()
   where id = p_event_id
  returning * into e;
  if v_roto then insert into public.roto_drafts (event_id) values (p_event_id) on conflict do nothing; end if;

  if not v_team then
    update public.participants set team_id = null, team_slot = null where event_id = p_event_id and team_id is not null;
    update public.event_teams set active = false where event_id = p_event_id and active;
  end if;

  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, reason, before, after)
  values (p_event_id, v_uid, 'event.details_updated', 'event', p_event_id, null, v_before,
          jsonb_build_object('name', e.name, 'auto_name', e.auto_name, 'decklists', e.decklists, 'format_name', e.format_name,
            'rounds', e.number_of_rounds, 'show_clock', e.show_clock, 'set_code', e.set_code, 'cube_name', e.cube_name,
            'team_size', e.team_size, 'pairing', e.pairing, 'top_cut', e.top_cut, 'auto_rounds', e.auto_rounds));

  return jsonb_build_object('event_id', e.id, 'name', e.name, 'format_name', e.format_name, 'format_label', e.format_label,
    'number_of_rounds', e.number_of_rounds, 'round_length_seconds', e.round_length_seconds, 'set_code', e.set_code,
    'set_name', e.set_name, 'cube_name', e.cube_name, 'cube_url', e.cube_url, 'team_size', e.team_size,
    'format_other', e.format_other, 'show_clock', e.show_clock, 'pairing', e.pairing, 'top_cut', e.top_cut,
    'auto_rounds', e.auto_rounds, 'auto_name', e.auto_name, 'decklists', e.decklists);
end $$;

-- When, where and how many: the full state every call (null = unscheduled / no venue / no cap). Raising or removing
-- the cap moves people up from the waitlist.
create or replace function public.set_event_schedule(p_event_id uuid, p_starts_at timestamptz, p_venue_name text,
  p_capacity integer, p_local_date date default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_before jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into e from public.events where id = p_event_id for update;
  if e.id is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can change the event' using errcode = '42501';
  end if;
  if not t1_private.sign_up_open(e) then
    raise exception 'Details lock once round 1 is paired' using errcode = '55000';
  end if;
  perform t1_private.check_schedule(p_starts_at, p_venue_name, p_capacity);
  v_before := jsonb_build_object('starts_at', e.starts_at, 'venue_name', e.venue_name, 'capacity', e.capacity);

  update public.events
     set starts_at = p_starts_at,
         venue_name = nullif(trim(p_venue_name), ''),
         capacity = p_capacity,
         name_date = coalesce(p_local_date, name_date),
         updated_at = now()
   where id = e.id returning * into e;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
  values (e.id, auth.uid(), 'event.schedule_updated', 'event', e.id, v_before,
          jsonb_build_object('starts_at', e.starts_at, 'venue_name', e.venue_name, 'capacity', e.capacity));
  perform t1_private.waitlist_move_up(e.id);

  return jsonb_build_object('event_id', e.id, 'starts_at', e.starts_at, 'venue_name', e.venue_name,
    'capacity', e.capacity, 'name', (select x.name from public.events x where x.id = e.id),
    'players', t1_private.active_players(e.id),
    'waitlist', (select count(*) from public.event_waitlist w where w.event_id = e.id));
end $$;

-- ==================================================================== g_reads
-- event_preview_json (from 20261018170000_privacy_lockdown) plus what the sign-up page needs.
create or replace function t1_private.event_preview_json(p_event_id uuid, p_access text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'event_id', e.id, 'access', p_access, 'short_code', e.short_code, 'name', e.name, 'format_label', e.format_label,
    'set_name', e.set_name, 'cube_name', e.cube_name, 'status', e.status, 'starts_at', e.starts_at,
    'venue_name', e.venue_name, 'capacity', e.capacity,
    'players', t1_private.active_players(e.id),
    'organizer_name', (select pr.display_name from public.profiles pr where pr.id = e.created_by and pr.deleted_at is null),
    'top_cut', e.top_cut, 'auto_rounds', e.auto_rounds, 'number_of_rounds', e.number_of_rounds,
    'decklists', e.decklists,
    'waitlist', (select count(*) from public.event_waitlist w where w.event_id = e.id),
    'sign_up', case when not t1_private.sign_up_open(e) or e.status = 'cancelled' then 'closed'
                    when e.capacity is not null and t1_private.active_players(e.id) >= e.capacity then 'full'
                    else 'open' end,
    'me', case when auth.uid() is null then null
               when exists (select 1 from public.event_members m where m.event_id = e.id and m.user_id = auth.uid()) then 'organizer'
               when exists (select 1 from public.participants p where p.event_id = e.id and p.user_id = auth.uid()) then 'player'
               when exists (select 1 from public.event_waitlist w where w.event_id = e.id and w.user_id = auth.uid()) then 'waitlisted'
               end,
    'position', case when auth.uid() is not null then t1_private.waitlist_position(e.id, auth.uid()) end)
    from public.events e where e.id = p_event_id;
$$;

-- event_public (from 20261018170000_privacy_lockdown) plus every round's matchups by name (`rounds`, newest first, with
-- the stage), so the public link shows the whole event, not just the round being played. Still no account ids.
create or replace function t1_private.public_pairings(p_round_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'match_id', m.id, 'table_number', m.table_number, 'is_bye', m.is_bye, 'status', m.status,
           'game_draws', m.game_draws, 'intentional_draw', m.intentional_draw,
           'sides', (select coalesce(jsonb_agg(jsonb_build_object(
                        'side', s.side, 'participant_id', s.participant_id, 'display_name', p.display_name,
                        'game_wins', s.game_wins) order by s.side), '[]'::jsonb)
                       from public.match_sides s left join public.participants p on p.id = s.participant_id
                      where s.match_id = m.id))
         order by m.table_number nulls last, m.id), '[]'::jsonb)
    from public.matches m where m.round_id = p_round_id
$$;

create or replace function public.event_public(p_event_id uuid, p_token text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_access text := t1_private.event_access(p_event_id, p_token);
  v_round public.rounds;
begin
  if v_access = 'none' then
    raise exception 'That event isn''t available' using errcode = '42501';
  end if;
  select * into v_round from public.rounds r where r.event_id = p_event_id and r.status = 'active'
   order by r.number desc limit 1;
  return t1_private.event_preview_json(p_event_id, v_access) || (
    select jsonb_build_object(
      'current_round', e.current_round, 'number_of_rounds', e.number_of_rounds, 'show_clock', e.show_clock,
      'format_name', e.format_name, 'team_size', e.team_size,
      'round', case when v_round.id is null then null else jsonb_build_object(
        'id', v_round.id, 'number', v_round.number, 'status', v_round.status, 'stage', v_round.stage,
        'timer_duration_seconds', v_round.timer_duration_seconds,
        'timer_remaining_at_change', v_round.timer_remaining_at_change, 'timer_status', v_round.timer_status,
        'timer_last_started_at', v_round.timer_last_started_at, 'timer_ends_at', v_round.timer_ends_at) end,
      'pairings', case when v_round.id is null then '[]'::jsonb else t1_private.public_pairings(v_round.id) end,
      'rounds', coalesce((select jsonb_agg(jsonb_build_object('number', r.number, 'stage', r.stage, 'status', r.status,
                                                              'matches', t1_private.public_pairings(r.id))
                                   order by r.number desc)
                            from public.rounds r where r.event_id = p_event_id), '[]'::jsonb))
      from public.events e where e.id = p_event_id);
end $$;

-- event_bundle (from 20261018170000_privacy_lockdown) plus the waitlist for organizers.
create or replace function public.event_bundle(p_event_id uuid, p_token text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_access text := t1_private.event_access(p_event_id, p_token);
begin
  if v_access not in ('organizer', 'player', 'guest') then
    raise exception 'That event isn''t available' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'event', (select to_jsonb(e) from public.events e where e.id = p_event_id),
    'participants', coalesce((select jsonb_agg(to_jsonb(p) order by p.seat nulls last, p.created_at, p.id)
                                from public.participants p where p.event_id = p_event_id), '[]'::jsonb),
    'rounds', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('matches', coalesce((
                  select jsonb_agg(to_jsonb(m) || jsonb_build_object('match_sides', coalesce((
                             select jsonb_agg(to_jsonb(s) order by s.side, s.id) from public.match_sides s where s.match_id = m.id),
                           '[]'::jsonb))
                         order by m.table_number nulls last, m.id)
                    from public.matches m where m.round_id = r.id), '[]'::jsonb))
                order by r.number)
                from public.rounds r where r.event_id = p_event_id), '[]'::jsonb),
    'teams', t1_private.event_teams_json(p_event_id),
    'waitlist', case when v_access = 'organizer' then coalesce((
                  select jsonb_agg(jsonb_build_object('user_id', w.user_id, 'display_name', w.display_name,
                                                      'position', w.n, 'created_at', w.created_at) order by w.n)
                    from (select x.*, row_number() over (order by x.created_at, x.user_id)::int n
                            from public.event_waitlist x where x.event_id = p_event_id) w), '[]'::jsonb)
                  else '[]'::jsonb end,
    'decklists', coalesce((
      select jsonb_agg(jsonb_build_object('participant_id', d.participant_id, 'main_count', d.main_count,
                                          'side_count', d.side_count, 'list_name', d.list_name,
                                          'source', case when d.list_id is null and d.list_name is null then 'text' else 'deck' end,
                                          'submitted_at', d.submitted_at) order by d.submitted_at)
        from public.event_decklists d join public.participants p on p.id = d.participant_id
       where d.event_id = p_event_id
         and (v_access = 'organizer'
              or (auth.uid() is not null and p.user_id = auth.uid())
              or (v_access = 'guest' and exists (select 1 from public.participant_tokens t
                                                  where t.participant_id = p.id and t.token = p_token)))), '[]'::jsonb),
    'is_organizer', v_access = 'organizer',
    'access', v_access);
end $$;

-- events_home (from 20261016140000_show_clock_reads) plus capacity, top cut, waitlist counts, the round's stage and
-- the events you're waiting for.
create or replace function public.events_home(p_include_demo boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_uid uuid := auth.uid();
  v_events jsonb;
  v_invites jsonb;
  v_waitlist jsonb;
begin
  p_include_demo := coalesce(p_include_demo, false) or t1_private.is_demo_tester();
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
           'format_name', x.format_name, 'format_label', x.format_label, 'event_type', x.event_type,
           'team_size', x.team_size, 'show_clock', x.show_clock,
           'bucket', x.bucket, 'organizing', x.organizing, 'playing', x.playing,
           'venue_name', x.venue_name, 'starts_at', x.starts_at, 'created_at', x.created_at,
           'number_of_rounds', x.number_of_rounds, 'current_round', x.current_round,
           'round_length_seconds', x.round_length_seconds, 'is_demo', x.is_demo,
           'cancelled_at', x.cancelled_at, 'cancel_reason', x.cancel_reason,
           'capacity', x.capacity, 'top_cut', x.top_cut, 'decklists', x.decklists,
           'my_decklist', exists (select 1 from public.event_decklists d join public.participants p on p.id = d.participant_id
                                   where d.event_id = x.id and p.user_id = v_uid),
           'waitlist', (select count(*) from public.event_waitlist w where w.event_id = x.id),
           'players', (select count(*) from public.participants p where p.event_id = x.id and p.status = 'active'),
           'my_status', (select p.status from public.participants p where p.event_id = x.id and p.user_id = v_uid),
           'round', case when (x.open_round).id is null then null else jsonb_build_object(
               'number', (x.open_round).number,
               'stage', (x.open_round).stage,
               'timer_status', (x.open_round).timer_status,
               'duration_seconds', (x.open_round).timer_duration_seconds,
               'ends_at', case when x.show_clock and (x.open_round).timer_status = 'running'
                                    and (x.open_round).timer_last_started_at is not null
                               then (x.open_round).timer_last_started_at
                                    + make_interval(secs => (x.open_round).timer_remaining_at_change) end,
               'remaining_seconds', case when x.show_clock and (x.open_round).timer_status = 'paused'
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
           'event_id', e.id, 'name', e.name, 'format', e.format, 'format_label', e.format_label, 'status', e.status,
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

  select coalesce(jsonb_agg(jsonb_build_object(
           'event_id', e.id, 'name', e.name, 'format_label', e.format_label, 'starts_at', e.starts_at,
           'venue_name', e.venue_name, 'position', t1_private.waitlist_position(e.id, v_uid),
           'players', t1_private.active_players(e.id), 'capacity', e.capacity
         ) order by coalesce(e.starts_at, w.created_at)), '[]'::jsonb)
    into v_waitlist
    from public.event_waitlist w join public.events e on e.id = w.event_id
   where w.user_id = v_uid and e.status in ('setup', 'seated')
     and not exists (select 1 from public.rounds r where r.event_id = e.id);

  return jsonb_build_object('events', v_events, 'invites', v_invites, 'waitlist', v_waitlist);
end $function$;

-- ==================================================================== i_decklists
-- Card counts in a pasted list (shared cases testdata/scheduled-events/cases.json `decklist`): "4 Lightning Bolt" or
-- "4x Lightning Bolt" lines; headers Deck / Main / Mainboard / Commander count as main, Sideboard as side, Considering /
-- Maybeboard / Tokens / Companion-less headers not listed are skipped; "SB: 2 Name" is a sideboard line; in a list with no
-- headers, a blank line after the main deck starts the sideboard (MTGO and Arena exports).
create or replace function t1_private.decklist_counts(p_body text, out main integer, out side integer)
language plpgsql immutable set search_path = '' as $$
declare
  v_line text;
  v_section text := 'main';
  v_headers boolean := false;
  v_seen boolean := false;
  v_head text;
  v_n integer;
  m text[];
begin
  main := 0; side := 0;
  foreach v_line in array regexp_split_to_array(replace(coalesce(p_body, ''), E'\r', ''), E'\n') loop
    v_line := trim(v_line);
    if v_line = '' then
      if not v_headers and v_seen and v_section = 'main' then v_section := 'side'; end if;
      continue;
    end if;
    v_head := lower(regexp_replace(v_line, '[:\s]*(\(\d+\))?[:\s]*$', ''));
    if v_head in ('deck', 'main', 'mainboard', 'main deck', 'commander') then
      v_section := 'main'; v_headers := true; continue;
    elsif v_head in ('sideboard', 'side', 'side board') then
      v_section := 'side'; v_headers := true; continue;
    elsif v_head in ('considering', 'maybeboard', 'maybe', 'tokens', 'about', 'companion') then
      v_section := 'skip'; v_headers := true; continue;
    end if;
    m := regexp_match(v_line, '^(sb:\s*)?(\d{1,3})\s*x?\s+\S', 'i');
    if m is null then continue; end if;
    v_n := m[2]::integer;
    if m[1] is not null then side := side + v_n;
    elsif v_section = 'main' then main := main + v_n; v_seen := true;
    elsif v_section = 'side' then side := side + v_n;
    end if;
  end loop;
end $$;

-- 'player' (the participant's own account), 'organizer', or null.
create or replace function t1_private.decklist_rights(p_participant_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when exists (select 1 from public.event_members m where m.event_id = p.event_id and m.user_id = auth.uid()) then 'organizer'
    when p.user_id is not null and p.user_id = auth.uid() then 'player' end
    from public.participants p where p.id = p_participant_id
$$;

-- A player sends (or replaces) their list until round 1 is paired; organizers can enter or fix anyone's at any time
-- before the event finishes. p_list_id names the caller's own deck it came from.
create or replace function public.decklist_submit(p_participant_id uuid, p_body text, p_list_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_rights text := t1_private.decklist_rights(p_participant_id);
  p public.participants;
  e public.events;
  c record;
  v_list_name text;
  v_body text := trim(both E'\n ' from replace(coalesce(p_body, ''), E'\r', ''));
  d public.event_decklists;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into p from public.participants where id = p_participant_id;
  if p.id is null or v_rights is null then raise exception 'That isn''t your list to change' using errcode = '42501'; end if;
  select * into e from public.events where id = p.event_id;
  if e.decklists = 'off' then raise exception 'This event doesn''t take decklists' using errcode = '22023'; end if;
  if e.status in ('completed', 'archived', 'cancelled') then
    raise exception 'That event is over' using errcode = '55000';
  end if;
  if v_rights = 'player' and not t1_private.sign_up_open(e) then
    raise exception 'Decklists lock when round 1 is paired: ask the organizer' using errcode = '55000';
  end if;
  if char_length(v_body) > 20000 then raise exception 'That list is too long' using errcode = '22023'; end if;
  select * into c from t1_private.decklist_counts(v_body);
  if c.main = 0 then raise exception 'That list has no cards ("4 Lightning Bolt" a line)' using errcode = '22023'; end if;
  if p_list_id is not null then
    select l.name into v_list_name from public.card_lists l
     where l.id = p_list_id and l.user_id = v_uid and l.kind = 'deck';
    if v_list_name is null then raise exception 'That deck isn''t yours' using errcode = '42501'; end if;
  end if;

  insert into public.event_decklists as x (participant_id, event_id, body, main_count, side_count, list_id, list_name, submitted_by)
  values (p.id, p.event_id, v_body, c.main, c.side, p_list_id, left(v_list_name, 80), v_uid)
  on conflict (participant_id) do update
    set body = excluded.body, main_count = excluded.main_count, side_count = excluded.side_count,
        list_id = excluded.list_id, list_name = excluded.list_name, submitted_by = excluded.submitted_by,
        updated_at = now()
  returning * into d;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p.event_id, v_uid, 'decklist.submitted', 'participant', p.id,
          jsonb_build_object('main', c.main, 'side', c.side, 'from_deck', p_list_id is not null, 'by', v_rights));
  return jsonb_build_object('participant_id', p.id, 'main_count', d.main_count, 'side_count', d.side_count,
                            'list_name', d.list_name, 'submitted_at', d.submitted_at, 'updated_at', d.updated_at);
end $$;

create or replace function public.decklist_remove(p_participant_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_rights text := t1_private.decklist_rights(p_participant_id);
  p public.participants;
  e public.events;
  d public.event_decklists;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into p from public.participants where id = p_participant_id;
  if p.id is null or v_rights is null then raise exception 'That isn''t your list to change' using errcode = '42501'; end if;
  select * into e from public.events where id = p.event_id;
  if v_rights = 'player' and not t1_private.sign_up_open(e) then
    raise exception 'Decklists lock when round 1 is paired: ask the organizer' using errcode = '55000';
  end if;
  delete from public.event_decklists where participant_id = p.id returning * into d;
  if d.participant_id is not null then
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id)
    values (p.event_id, auth.uid(), 'decklist.removed', 'participant', p.id);
  end if;
  return jsonb_build_object('participant_id', p.id, 'removed', d.participant_id is not null);
end $$;

-- The list itself: the player's own, or anyone's for organizers. null when none was sent.
create or replace function public.decklist_get(p_participant_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if t1_private.decklist_rights(p_participant_id) is null then
    raise exception 'That list isn''t available' using errcode = '42501';
  end if;
  return (select jsonb_build_object('participant_id', d.participant_id, 'display_name', p.display_name, 'body', d.body,
                                    'main_count', d.main_count, 'side_count', d.side_count, 'list_id', d.list_id,
                                    'list_name', d.list_name, 'submitted_at', d.submitted_at, 'updated_at', d.updated_at)
            from public.event_decklists d join public.participants p on p.id = d.participant_id
           where d.participant_id = p_participant_id);
end $$;

-- ==================================================================== h_grants
do $$
declare f text;
begin
  foreach f in array array[
    'swiss_rounds(integer)', 'events_auto_rounds()', 'participants_auto_rounds()', 'sign_up_open(public.events)',
    'active_players(uuid)', 'waitlist_position(uuid, uuid)', 'seat_waitlisted(uuid, uuid, uuid, text)',
    'waitlist_move_up(uuid)', 'check_cut_rounds(boolean, text, integer, boolean)',
    'check_schedule(timestamptz, text, integer)', 'check_decklists(boolean, text)', 'event_preview_json(uuid, text)',
    'decklist_counts(text)', 'decklist_rights(uuid)', 'public_pairings(uuid)'] loop
    execute format('revoke execute on function t1_private.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'event_sign_up(uuid)', 'event_leave(uuid)', 'waitlist_admit(uuid, uuid)', 'waitlist_remove(uuid, uuid)',
    'set_event_schedule(uuid, timestamptz, text, integer, date)',
    'create_event_v2(text, text, integer, integer, text, text, text, text, integer, text, text[], boolean, boolean, date, text, timestamptz, text, integer, integer, boolean, text)',
    'update_event_details(uuid, text, text, integer, integer, text, text, text, text, integer, text, boolean, text, integer, boolean, boolean, text)',
    'decklist_submit(uuid, text, uuid)', 'decklist_remove(uuid)', 'decklist_get(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  execute 'revoke execute on function public.event_bundle(uuid, text) from public';
  execute 'grant execute on function public.event_bundle(uuid, text) to anon, authenticated';
  execute 'revoke execute on function public.event_public(uuid, text) from public';
  execute 'grant execute on function public.event_public(uuid, text) to anon, authenticated';
  execute 'revoke execute on function public.join_event(text, text) from public';
  execute 'grant execute on function public.join_event(text, text) to anon, authenticated';
end $$;
