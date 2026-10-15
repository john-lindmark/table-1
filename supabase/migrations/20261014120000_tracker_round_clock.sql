-- Life tracker shows the round clock (Figma 73:5420, Lifetracker Info).
-- tracker_state gains `clock`: the match's round timer columns, null when the match has no round.
-- Clients keep it live from postgres_changes UPDATE on public.rounds filtered id=eq.<clock.round_id>
-- (rounds is already in supabase_realtime and publicly readable), using the same column names.

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
                from public.matches m join public.rounds r on r.id = m.round_id where m.id = s.match_id),
    'games', (select coalesce(jsonb_agg(jsonb_build_object('game_no', g.game_no, 'winner_side', g.winner_side,
                 'is_draw', g.is_draw, 'recorded_at', g.recorded_at) order by g.game_no), '[]'::jsonb)
                from public.tracker_games g where g.session_id = s.id),
    'ops', (select coalesce(jsonb_agg(jsonb_build_object('client_op_id', o.client_op_id, 'game_no', o.game_no,
               'side', o.side, 'counter', o.counter, 'delta', o.delta, 'tapped_at', o.tapped_at,
               'mine', o.actor = v_uid) order by o.id), '[]'::jsonb)
              from (select * from public.tracker_ops where session_id = s.id order by id desc limit 5000) o));
end $$;

revoke execute on function public.tracker_state(uuid) from public, anon;
grant execute on function public.tracker_state(uuid) to authenticated;
