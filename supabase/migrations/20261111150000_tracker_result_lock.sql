-- The life tracker records no more games once the match's result is in (John, 2026-11-11: "restrict the ability
-- to record additional wins in the tracker if the match results have already been submitted").
-- contract/life-tracker-options-2026-10-20.md § After the result is in.
--
-- A result is in once the match leaves 'pending' (reported, confirmed, disputed, or an organizer's entry). A retry
-- of a game already recorded still returns the state, so a slow phone's resend isn't an error. Clearing the result
-- (re-pair a round) puts the match back to 'pending' and the tracker opens up again.

create or replace function public.tracker_result_in(p_match_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select m.is_bye or m.status <> 'pending' from public.matches m where m.id = p_match_id), false);
$$;
revoke all on function public.tracker_result_in(uuid) from public, anon, authenticated;

create or replace function public.tracker_state(p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s public.tracker_sessions;
  v_uid uuid := auth.uid();
  v_keeper boolean;
begin
  select * into s from public.tracker_sessions where id = p_session_id;
  if s.id is null or not public.tracker_visible(p_session_id) then
    raise exception 'Tracker not found' using errcode = 'P0002';
  end if;
  v_keeper := public.tracker_keeper(s);
  return jsonb_build_object(
    'session_id', s.id, 'match_id', s.match_id, 'event_id', s.event_id, 'starting_life', s.starting_life,
    'my_side', case when v_uid = s.user0 then 0 when v_uid = s.user1 then 1 when v_keeper then 0 end,
    'keeper', v_keeper,
    'result_in', public.tracker_result_in(s.match_id),
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

create or replace function public.tracker_record_game(p_session_id uuid, p_game_no integer, p_winner_side integer,
                                                      p_draw boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  s public.tracker_sessions;
  v_uid uuid := auth.uid();
  g public.tracker_games;
  v_next integer;
begin
  select * into s from public.tracker_sessions where id = p_session_id for update;
  if s.id is null or v_uid is null or (v_uid not in (coalesce(s.user0, '00000000-0000-0000-0000-000000000000'),
                                                    coalesce(s.user1, '00000000-0000-0000-0000-000000000000'))
                                       and not public.tracker_keeper(s)) then
    raise exception 'Only the players in this match can record games' using errcode = '42501';
  end if;
  if not coalesce(p_draw, false) and p_winner_side not in (0, 1) then
    raise exception 'Pick who won' using errcode = '22023';
  end if;
  select * into g from public.tracker_games where session_id = s.id and game_no = p_game_no;
  if g.session_id is not null then
    if g.is_draw = coalesce(p_draw, false) and g.winner_side is not distinct from
         (case when coalesce(p_draw, false) then null else p_winner_side end) then
      return public.tracker_state(s.id);
    end if;
    raise exception 'Game % was already recorded', p_game_no using errcode = '23505';
  end if;
  -- Once the match's result is in (reported, confirmed or disputed), its games are settled: change the
  -- result from the event instead (report again, or the organizer's correction).
  if public.tracker_result_in(s.match_id) then
    raise exception 'The result for this match is already in' using errcode = 'PT409';
  end if;
  select coalesce(max(game_no), 0) + 1 into v_next from public.tracker_games where session_id = s.id;
  if p_game_no <> v_next then raise exception 'Record game % first', v_next using errcode = '22023'; end if;
  if v_next > 5 then raise exception 'A match has at most 5 games' using errcode = '22023'; end if;
  insert into public.tracker_games (session_id, game_no, winner_side, is_draw, recorded_by)
  values (s.id, p_game_no, case when coalesce(p_draw, false) then null else p_winner_side end, coalesce(p_draw, false), v_uid);
  return public.tracker_state(s.id);
end $$;
