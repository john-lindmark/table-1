-- Event tables are written only through security definer RPCs (review 2026-10-17, finding S1).
--
-- Before this, every event table had an organizer `FOR ALL` policy and client roles held write grants,
-- so an organizer could PATCH results through PostgREST with no report/dispute flow and no audit row,
-- forge audit rows, and seat any account in their event so fake results reached that player's
-- lifetime records. Now:
--   * record_round and set_participant_status replace the last direct client writes (each is atomic
--     and writes its own audit row; record_round also completes the event, replacing the client's
--     separate events update and audit insert);
--   * the organizer write policies go, and anon/authenticated lose INSERT/UPDATE/DELETE on event tables;
--   * a participant can only be linked to the caller's own account from a client request (claim, join,
--     QR, nearby, accepted invite, organizer who plays), so records only ever count real links.
-- events-engine uses the service role and is unaffected.

-- record_round -------------------------------------------------------------------------------------
-- Marks a round recorded (rounds_confirm_on_end confirms its undisputed reports) and, when p_final,
-- completes the event in the same transaction. p_round_id may be null only when p_final (finishing an
-- event that has no open round). Retry-safe: repeating it changes nothing and writes no second audit row.
create or replace function public.record_round(p_event_id uuid, p_round_id uuid, p_final boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  e public.events;
  r public.rounds;
begin
  if v_uid is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  select * into e from public.events where id = p_event_id for update;
  if e.id is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from public.event_members em where em.event_id = e.id and em.user_id = v_uid) then
    raise exception 'Only organizers can record rounds' using errcode = '42501';
  end if;
  if e.status = 'cancelled' then raise exception 'That event was cancelled' using errcode = '22023'; end if;
  if p_round_id is null and not coalesce(p_final, false) then
    raise exception 'Which round?' using errcode = '22023';
  end if;

  if p_round_id is not null then
    select * into r from public.rounds where id = p_round_id and event_id = e.id for update;
    if r.id is null then raise exception 'Round not found' using errcode = 'P0002'; end if;
    if r.status is distinct from 'recorded' then
      update public.rounds set status = 'recorded', recorded_at = now() where id = r.id returning * into r;
      insert into public.audit_log (event_id, actor_user, action, target_type, target_id)
      values (e.id, v_uid, 'round.recorded', 'round', r.id);
    end if;
  end if;

  if coalesce(p_final, false) and e.status not in ('completed', 'archived') then
    if exists (select 1 from public.matches m where m.event_id = e.id and m.disputed and m.status <> 'confirmed') then
      raise exception 'Resolve the disputed results first' using errcode = '22023';
    end if;
    update public.events set status = 'completed', updated_at = now() where id = e.id returning * into e;
    insert into public.audit_log (event_id, actor_user, action, target_type, target_id)
    values (e.id, v_uid, 'event.completed', 'event', e.id);
  end if;

  return jsonb_build_object('event_id', e.id, 'event_status', e.status,
                            'round_id', r.id, 'round_status', r.status);
end $$;

-- set_participant_status --------------------------------------------------------------------------
-- Drop ('dropped', after round p_dropped_in_round, default the current round) or reinstate ('active').
-- Retry-safe: no change means no update and no audit row.
create or replace function public.set_participant_status(
  p_participant_id uuid, p_status text, p_dropped_in_round int default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  p public.participants;
  e public.events;
  v_round int;
  v_before jsonb;
begin
  if v_uid is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  if p_status is null or p_status not in ('active', 'dropped') then
    raise exception 'Status is active or dropped' using errcode = '22023';
  end if;
  select * into p from public.participants where id = p_participant_id for update;
  if p.id is null then raise exception 'Player not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from public.event_members em where em.event_id = p.event_id and em.user_id = v_uid) then
    raise exception 'Only organizers can drop or reinstate players' using errcode = '42501';
  end if;
  select * into e from public.events where id = p.event_id;
  if e.status in ('completed', 'archived', 'cancelled') then
    raise exception 'That event is not running' using errcode = '22023';
  end if;

  v_round := case when p_status = 'dropped' then coalesce(p_dropped_in_round, nullif(e.current_round, 0)) end;
  if p.status = p_status and p.dropped_in_round is not distinct from v_round then
    return jsonb_build_object('participant_id', p.id, 'status', p.status, 'dropped_in_round', p.dropped_in_round);
  end if;

  v_before := jsonb_build_object('status', p.status, 'dropped_in_round', p.dropped_in_round);
  update public.participants set status = p_status, dropped_in_round = v_round where id = p.id returning * into p;
  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, before, after)
  values (p.event_id, v_uid, case when p_status = 'dropped' then 'participant.dropped' else 'participant.reinstated' end,
          'participant', p.id, v_before, jsonb_build_object('status', p.status, 'dropped_in_round', p.dropped_in_round));
  return jsonb_build_object('participant_id', p.id, 'status', p.status, 'dropped_in_round', p.dropped_in_round);
end $$;

revoke execute on function public.record_round(uuid, uuid, boolean) from public, anon;
revoke execute on function public.set_participant_status(uuid, text, int) from public, anon;
grant execute on function public.record_round(uuid, uuid, boolean) to authenticated;
grant execute on function public.set_participant_status(uuid, text, int) to authenticated;

-- Account links -------------------------------------------------------------------------------------
-- From a client request (role anon/authenticated, including inside definer RPCs) a participant may only
-- be linked to the caller's own account. Every real path does exactly that: claim_participant,
-- join_event, join_event_qr / join_event_nearby / respond_to_invite (via _seat_account), add_self_to_event,
-- create_event_v2 (organizer plays). Demo events are seeded with demo profiles and never count in records.
-- The service role (events-engine), cron and migrations are trusted.
create or replace function public.participants_link_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.user_id is null or new.user_id is not distinct from auth.uid() then return new; end if;
  if tg_op = 'UPDATE' and new.user_id is not distinct from old.user_id then return new; end if;
  if coalesce(current_setting('role', true), 'none') not in ('anon', 'authenticated') then return new; end if;
  if exists (select 1 from public.events e where e.id = new.event_id and e.is_demo) then return new; end if;
  raise exception 'Players link their own account (claim, join or accept an invite)' using errcode = '42501';
end $$;
drop trigger if exists participants_link_guard on public.participants;
create trigger participants_link_guard
  before insert or update of user_id on public.participants
  for each row execute function public.participants_link_guard();

-- A side's account always comes from its participant, even if user_id alone is written.
drop trigger if exists match_sides_fill on public.match_sides;
create trigger match_sides_fill
  before insert or update of match_id, participant_id, user_id on public.match_sides
  for each row execute function public.match_sides_fill();

-- Policies and grants -------------------------------------------------------------------------------
drop policy if exists events_organizer_write on public.events;
drop policy if exists events_insert_authenticated on public.events;
drop policy if exists event_members_owner_write on public.event_members;
drop policy if exists pods_organizer_write on public.pods;
drop policy if exists participants_organizer_write on public.participants;
drop policy if exists rounds_organizer_write on public.rounds;
drop policy if exists matches_organizer_write on public.matches;
drop policy if exists match_sides_organizer_write on public.match_sides;
drop policy if exists audit_log_organizer_write on public.audit_log;

revoke insert, update, delete, truncate on public.events, public.event_members, public.event_teams, public.pods,
  public.participants, public.rounds, public.matches, public.match_sides, public.audit_log from anon, authenticated;
