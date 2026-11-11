-- A player's life tracker follows them into the next round (contract/life-tracker-options-2026-10-20.md § Next round).
-- The tracker opens on one match and only listened to that match, so once the next round was paired a tracker left
-- open (or reopened from a stale screen) kept showing the old match. tracker_next answers, for the signed-in player
-- of a match, their match in the event's newest later round: the clients ask it once the tracker opens, every 15 s
-- while it is up and on returning to the app, and move to the new match.
--
-- Answers null when there is nothing newer, or when the caller isn't one of the match's players (an organizer
-- watching, or keeping score for guests, stays put). A match that is gone (its round was re-paired) is looked up
-- by the event instead: the caller's match in the event's newest round.
--   {round, match_id, bye}: match_id null and bye false while the round's matches are still being written, or when
--   the caller has no match in it (dropped).

create or replace function public.tracker_next(p_match_id uuid, p_event_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_event uuid;
  v_number integer;
  v_pid uuid;
  r public.rounds;
  m public.matches;
begin
  if v_uid is null then
    raise exception 'Sign in first' using errcode = '42501';
  end if;

  select m0.event_id, r0.number, p.id into v_event, v_number, v_pid
    from public.matches m0
    join public.rounds r0 on r0.id = m0.round_id
    join public.match_sides ms on ms.match_id = m0.id
    join public.participants p on p.id = ms.participant_id
   where m0.id = p_match_id and p.user_id = v_uid
   limit 1;

  if v_event is null then
    -- Not a player in this match (or the match is gone): only a gone match is looked up by its event.
    if p_event_id is null or exists (select 1 from public.matches where id = p_match_id) then return null; end if;
    select p.id into v_pid from public.participants p where p.event_id = p_event_id and p.user_id = v_uid;
    if v_pid is null then return null; end if;
    v_event := p_event_id;
    v_number := 0;
  end if;

  select * into r from public.rounds
   where event_id = v_event and number > v_number
   order by number desc limit 1;
  if r.id is null then return null; end if;

  select m1.* into m
    from public.matches m1
    join public.match_sides ms on ms.match_id = m1.id
   where m1.round_id = r.id and ms.participant_id = v_pid
   limit 1;

  return jsonb_build_object(
    'round', r.number,
    'match_id', case when m.id is not null and not m.is_bye then m.id end,
    'bye', coalesce(m.is_bye, false));
end $$;

revoke execute on function public.tracker_next(uuid, uuid) from public, anon;
grant execute on function public.tracker_next(uuid, uuid) to authenticated;
