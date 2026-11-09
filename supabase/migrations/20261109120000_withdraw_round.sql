-- Re-pair a round (contract/repair-round-2026-11-09.md). A result in an earlier round was entered wrong and the
-- organizer has corrected it (set_match_result); the round that was paired from the wrong standings can be taken
-- back and paired again. events-engine `repair_round` works out the new pairings first, then calls this to take
-- the old ones back in one transaction, then pairs the round again as usual.
--
-- Only the latest round, only while it is active, only while the event is running. Results already entered in it
-- are cleared only when the organizer said so (p_clear_results); otherwise PT409 (HTTP 409). Unresolved disputes
-- in earlier rounds block it, like pairing the next round. Audited as round.withdrawn with the old pairings.
create or replace function public.withdraw_round(
  p_round_id uuid, p_clear_results boolean default false, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  r public.rounds;
  e public.events;
  v_results int;
  v_matches uuid[];
  v_before jsonb;
begin
  if v_uid is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  select * into r from public.rounds where id = p_round_id;
  if r.id is null then raise exception 'Round not found' using errcode = 'P0002'; end if;
  select * into e from public.events where id = r.event_id for update;
  if not exists (select 1 from public.event_members em where em.event_id = e.id and em.user_id = v_uid) then
    raise exception 'Only organizers can re-pair rounds' using errcode = '42501';
  end if;
  if e.status = 'cancelled' then raise exception 'That event was cancelled' using errcode = '22023'; end if;
  if e.status in ('completed', 'archived') then raise exception 'That event has finished' using errcode = '22023'; end if;
  select * into r from public.rounds where id = p_round_id for update;
  if exists (select 1 from public.rounds x where x.event_id = e.id and x.number > r.number) then
    raise exception 'Only the latest round can be re-paired' using errcode = '22023';
  end if;
  if r.status <> 'active' then
    raise exception 'Round % is already recorded', r.number using errcode = '22023';
  end if;
  if exists (select 1 from public.matches m join public.rounds x on x.id = m.round_id
              where m.event_id = e.id and x.number < r.number and m.disputed and m.status <> 'confirmed') then
    raise exception 'Resolve the disputed results first' using errcode = '22023';
  end if;

  select count(*) filter (where not m.is_bye and m.status in ('reported', 'confirmed')), array_agg(m.id),
         coalesce(jsonb_agg(jsonb_build_object('table', m.table_number, 'bye', m.is_bye, 'status', m.status,
                                               'draws', m.game_draws, 'sides', public._match_sides_json(m.id))
                            order by m.table_number), '[]'::jsonb)
    into v_results, v_matches, v_before
    from public.matches m where m.round_id = r.id;
  if v_results > 0 and not coalesce(p_clear_results, false) then
    raise exception 'Round % has % % in. Clear them to re-pair.', r.number, v_results,
      case when v_results = 1 then 'result' else 'results' end using errcode = 'PT409';
  end if;

  -- Life trackers belong to the old matches (t1_private.match_times is a view over them); the matches' delete
  -- reverses lifetime records (matches_records_sync) and cascades to their sides and outcomes.
  if v_matches is not null then
    delete from public.tracker_ops o using public.tracker_sessions s
     where o.session_id = s.id and s.match_id = any(v_matches);
    delete from public.tracker_games g using public.tracker_sessions s
     where g.session_id = s.id and s.match_id = any(v_matches);
    delete from public.tracker_sessions where match_id = any(v_matches);
  end if;
  delete from public.rounds where id = r.id;
  update public.events set current_round = r.number - 1, updated_at = now() where id = e.id;

  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, reason, before, after)
  values (e.id, v_uid, 'round.withdrawn', 'round', r.id, p_reason,
          jsonb_build_object('round', r.number, 'stage', r.stage, 'matches', v_before),
          jsonb_build_object('cleared_results', v_results));

  return jsonb_build_object('event_id', e.id, 'round_number', r.number, 'stage', r.stage,
                            'cleared_results', v_results);
end $$;

revoke execute on function public.withdraw_round(uuid, boolean, text) from public, anon;
grant execute on function public.withdraw_round(uuid, boolean, text) to authenticated;
