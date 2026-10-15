-- Draft seating in one transaction (2026-10-14).
--
-- Re-seat used to go through events-engine: an organizer check, a full event load, one UPDATE per player,
-- then a second full load, ~20 sequential round trips. seat_event does the same work in Postgres:
-- same rules as events-engine/seating.ts (pods of up to 8 split near-equal, 10 → 5+5, 17 → 6+6+5;
-- team draft is one pod alternating A1 B1 A2 B2 by team slot), one bulk update, and it returns the
-- seating view clients already parse: {event_id, pods: [{pod_id, name, seats: [{seat, participant_id,
-- display_name, team}]}]}.
--
-- Callers: organizers (is_event_organizer) and events-engine with the service role (pair_round seats
-- automatically when nobody is seated yet).

create or replace function public.seat_event(p_event_id uuid)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_event public.events%rowtype;
  v_ids uuid[];
  v_n int;
  v_pod_count int;
  v_base int;
  v_extra int;
  v_pod_ids uuid[];
  v_team_ids uuid[];
  v_loose int;
  v_id uuid;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_event_organizer(p_event_id) then
    raise exception 'Only organizers can do that' using errcode = '42501';
  end if;

  -- Row lock: two quick re-seats run one after the other, never interleaved.
  select * into v_event from public.events where id = p_event_id for update;
  if not found then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if coalesce(v_event.format_name, '') not in ('draft', 'team_draft') then
    raise exception 'Seating is for draft events' using errcode = '55000';
  end if;
  if exists (select 1 from public.rounds r where r.event_id = p_event_id) then
    raise exception 'Seats are locked once round 1 is paired' using errcode = '55000';
  end if;
  if v_event.status not in ('setup', 'seated') then
    raise exception 'That event can''t be seated now' using errcode = '55000';
  end if;

  if v_event.format_name = 'team_draft' then
    select array_agg(t.id order by t.display_order) into v_team_ids
      from public.event_teams t where t.event_id = p_event_id and t.active;
    if coalesce(cardinality(v_team_ids), 0) <> 2 then
      raise exception 'A team draft needs exactly two teams before seating' using errcode = '55000';
    end if;
    select count(*) into v_loose from public.participants p
     where p.event_id = p_event_id and p.status = 'active'
       and (p.team_id is null or p.team_id <> all (v_team_ids));
    if v_loose > 0 then
      raise exception '% player%', v_loose, case when v_loose = 1 then ' isn''t on a team yet' else 's aren''t on a team yet' end
        using errcode = '55000';
    end if;
    -- A1 B1 A2 B2 …: rank within each team by slot (then name), interleave by rank, team A first.
    select array_agg(x.id order by x.rn, x.team_order) into v_ids from (
      select p.id,
             row_number() over (partition by p.team_id order by p.team_slot nulls last, p.display_name) as rn,
             array_position(v_team_ids, p.team_id) as team_order
        from public.participants p
       where p.event_id = p_event_id and p.status = 'active'
    ) x;
    v_n := coalesce(cardinality(v_ids), 0);
    v_pod_count := 1;
  else
    select array_agg(p.id order by random()) into v_ids
      from public.participants p where p.event_id = p_event_id and p.status = 'active';
    v_n := coalesce(cardinality(v_ids), 0);
    v_pod_count := greatest(1, ceil(v_n / 8.0)::int);
  end if;

  if v_n = 0 then
    raise exception 'Add players before seating' using errcode = '22023';
  end if;
  v_base := v_n / v_pod_count;
  v_extra := v_n % v_pod_count;

  -- Enough pods (existing ones keep their ids and names).
  select array_agg(d.id order by d.display_order) into v_pod_ids from public.pods d where d.event_id = p_event_id;
  for i in coalesce(cardinality(v_pod_ids), 0) + 1 .. v_pod_count loop
    insert into public.pods (event_id, name, display_order) values (p_event_id, 'Pod ' || i, i - 1)
    returning id into v_id;
    v_pod_ids := array_append(v_pod_ids, v_id);
  end loop;

  -- Position k (0-based) in the shuffled order → pod and seat. The first v_extra pods hold v_base + 1.
  -- Everyone not in the plan (dropped players) loses their seat, as before.
  update public.participants p
     set seat = s.seat, pod_id = coalesce(s.pod_id, p.pod_id)
    from (
      select pp.id, plan.seat, plan.pod_id
        from public.participants pp
        left join (
          select u.id,
                 case when u.k < v_extra * (v_base + 1) then u.k % (v_base + 1)
                      else (u.k - v_extra * (v_base + 1)) % v_base end + 1 as seat,
                 v_pod_ids[1 + case when u.k < v_extra * (v_base + 1) then u.k / (v_base + 1)
                                    else v_extra + (u.k - v_extra * (v_base + 1)) / v_base end] as pod_id
            from (select o.id, (o.ord - 1)::int as k from unnest(v_ids) with ordinality as o(id, ord)) u
        ) plan on plan.id = pp.id
       where pp.event_id = p_event_id
    ) s
   where s.id = p.id;

  if v_event.status = 'setup' then
    update public.events set status = 'seated', updated_at = now() where id = p_event_id;
  end if;

  insert into public.audit_log (event_id, actor_user, action, target_type, target_id, after)
  values (p_event_id, auth.uid(), 'event.seated', 'event', p_event_id,
          jsonb_build_object('players', v_n, 'pods', v_pod_count));

  return json_build_object('event_id', p_event_id, 'pods', coalesce((
    select json_agg(json_build_object('pod_id', d.id, 'name', d.name, 'seats', d.seats) order by d.display_order)
      from (
        select pd.id, pd.name, pd.display_order,
               (select json_agg(json_build_object('seat', p.seat, 'participant_id', p.id,
                                                  'display_name', p.display_name, 'team', t.name) order by p.seat)
                  from public.participants p
                  left join public.event_teams t on t.id = p.team_id
                 where p.pod_id = pd.id and p.status = 'active' and p.seat is not null) as seats
          from public.pods pd where pd.event_id = p_event_id
      ) d
     where d.seats is not null), '[]'::json));
end $$;

revoke execute on function public.seat_event(uuid) from public, anon;
grant execute on function public.seat_event(uuid) to authenticated, service_role;
