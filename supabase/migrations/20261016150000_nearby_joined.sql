-- nearby_events: says whether the caller is already in each event (an active player or its organizer),
-- so clients show "Joined" and open the event instead of offering Join again.
drop function if exists public.nearby_events(double precision, double precision, int, int);

create function public.nearby_events(
  p_lat double precision, p_lng double precision, p_accuracy_m int default 50, p_limit int default 20)
returns table (event_id uuid, name text, venue_name text, format text, status text,
               players int, capacity int, distance_m int, starts_at timestamptz, joined boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  pt extensions.geography;
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in to find nearby events' using errcode = '28000'; end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Invalid coordinates' using errcode = '22023';
  end if;
  pt := extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography;
  return query
  select e.id, e.name, e.venue_name, e.format, e.status,
         (select count(*) from public.participants p where p.event_id = e.id and p.status = 'active')::int,
         e.capacity,
         (round(extensions.st_distance(l.location, pt) / 50.0) * 50)::int,
         e.starts_at,
         (e.created_by = me or exists (select 1 from public.participants p
                                        where p.event_id = e.id and p.user_id = me and p.status = 'active'))
    from public.event_locations l
    join public.events e on e.id = l.event_id
   where e.visibility = 'nearby' and e.status in ('setup', 'seated', 'in_progress')
     and (e.discoverable_until is null or e.discoverable_until > now())
     and extensions.st_dwithin(l.location, pt, 2100)        -- constant radius: index-assisted
     and extensions.st_distance(l.location, pt) <= e.join_radius_m + least(greatest(p_accuracy_m, 0), 100)
   order by l.location operator(extensions.<->) pt
   limit least(greatest(p_limit, 1), 50);
end $$;

revoke all on function public.nearby_events(double precision, double precision, int, int) from public, anon;
grant execute on function public.nearby_events(double precision, double precision, int, int) to authenticated, service_role;
