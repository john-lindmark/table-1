-- "Round timer" off hides clocks for that event (rounds still run 50 minutes, auto-confirm unchanged).
-- events_home: rows carry show_clock, and the open round's ends_at / remaining_seconds are null when hidden.
-- tracker_state: clock is null when hidden (clients already treat a null clock as "no clock").

create or replace function public.events_home(p_include_demo boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_uid uuid := auth.uid();
  v_events jsonb;
  v_invites jsonb;
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
           'players', (select count(*) from public.participants p where p.event_id = x.id and p.status = 'active'),
           'my_status', (select p.status from public.participants p where p.event_id = x.id and p.user_id = v_uid),
           'round', case when (x.open_round).id is null then null else jsonb_build_object(
               'number', (x.open_round).number,
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

  return jsonb_build_object('events', v_events, 'invites', v_invites);
end $function$;

create or replace function public.tracker_state(p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s public.tracker_sessions;
  v_uid uuid := auth.uid();
begin
  select * into s from public.tracker_sessions where id = p_session_id;
  if s.id is null or not public.tracker_visible(p_session_id) then
    raise exception 'Tracker not found' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'session_id', s.id, 'match_id', s.match_id, 'event_id', s.event_id, 'starting_life', s.starting_life,
    'my_side', case when v_uid = s.user0 then 0 when v_uid = s.user1 then 1 end,
    'names', (select jsonb_agg(coalesce(p.display_name, 'Opponent') order by ms.side)
                from public.match_sides ms left join public.participants p on p.id = ms.participant_id
               where ms.match_id = s.match_id),
    'event_name', (select e.name from public.events e where e.id = s.event_id),
    'round', (select r.number from public.matches m join public.rounds r on r.id = m.round_id where m.id = s.match_id),
    'table', (select m.table_number from public.matches m where m.id = s.match_id),
    'clock', (select jsonb_build_object(
                'round_id', r.id,
                'timer_status', r.timer_status,
                'timer_last_started_at', r.timer_last_started_at,
                'timer_remaining_at_change', r.timer_remaining_at_change,
                'timer_duration_seconds', r.timer_duration_seconds)
                from public.matches m
                join public.rounds r on r.id = m.round_id
                join public.events e on e.id = m.event_id
               where m.id = s.match_id and e.show_clock),
    'games', (select coalesce(jsonb_agg(jsonb_build_object('game_no', g.game_no, 'winner_side', g.winner_side,
                 'is_draw', g.is_draw, 'recorded_at', g.recorded_at) order by g.game_no), '[]'::jsonb)
                from public.tracker_games g where g.session_id = s.id),
    'ops', (select coalesce(jsonb_agg(jsonb_build_object('client_op_id', o.client_op_id, 'game_no', o.game_no,
               'side', o.side, 'counter', o.counter, 'delta', o.delta, 'tapped_at', o.tapped_at,
               'mine', o.actor = v_uid) order by o.id), '[]'::jsonb)
              from (select * from public.tracker_ops where session_id = s.id order by id desc limit 5000) o));
end $$;
