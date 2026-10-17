-- Life tracker for guest matches: when neither side of a match has an account, the organizer's phone keeps
-- score for it (my_side 0, `keeper` true) and the organizer reports the result. Matches with an account on
-- either side are unchanged: only those players write; the organizer watches.

create or replace function public.tracker_keeper(s public.tracker_sessions)
returns boolean language sql stable security definer set search_path = '' as $$
  select s.user0 is null and s.user1 is null and public.is_event_organizer(s.event_id);
$$;
revoke execute on function public.tracker_keeper(public.tracker_sessions) from public, anon;

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

create or replace function public.tracker_push(p_session_id uuid, p_ops jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  s public.tracker_sessions;
  v_uid uuid := auth.uid();
  v_current integer;
  v_n integer;
begin
  select * into s from public.tracker_sessions where id = p_session_id;
  if s.id is null or v_uid is null or (v_uid not in (coalesce(s.user0, '00000000-0000-0000-0000-000000000000'),
                                                    coalesce(s.user1, '00000000-0000-0000-0000-000000000000'))
                                       and not public.tracker_keeper(s)) then
    raise exception 'Only the players in this match can change life totals' using errcode = '42501';
  end if;
  if jsonb_typeof(p_ops) <> 'array' or jsonb_array_length(p_ops) > 200 then
    raise exception 'Send up to 200 changes at a time' using errcode = '22023';
  end if;
  select coalesce(max(game_no), 0) + 1 into v_current from public.tracker_games where session_id = s.id;
  insert into public.tracker_ops (session_id, client_op_id, actor, game_no, side, counter, delta, tapped_at)
  select s.id, o.client_op_id, v_uid, o.game_no, o.side, o.counter, o.delta,
         least(greatest(coalesce(o.tapped_at, now()), now() - interval '1 day'), now() + interval '1 minute')
    from jsonb_to_recordset(p_ops) as o(client_op_id uuid, game_no integer, side smallint, counter text,
                                        delta integer, tapped_at timestamptz)
   where o.game_no = v_current and o.delta <> 0
  on conflict (session_id, client_op_id) do nothing;
  get diagnostics v_n = row_count;
  return jsonb_build_object('inserted', v_n, 'game_no', v_current);
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
  select coalesce(max(game_no), 0) + 1 into v_next from public.tracker_games where session_id = s.id;
  if p_game_no <> v_next then raise exception 'Record game % first', v_next using errcode = '22023'; end if;
  if v_next > 5 then raise exception 'A match has at most 5 games' using errcode = '22023'; end if;
  insert into public.tracker_games (session_id, game_no, winner_side, is_draw, recorded_by)
  values (s.id, p_game_no, case when coalesce(p_draw, false) then null else p_winner_side end, coalesce(p_draw, false), v_uid);
  return public.tracker_state(s.id);
end $$;
