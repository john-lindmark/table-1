-- /event post lists open events only (John, 2026-10-29): a finished event has nothing to sign up for, so it has no
-- place in the picker. discord_my_events (from 20261029160000) without the "finished in the last 60 days" rows.
create or replace function public.discord_my_events(p_discord_id text, p_query text default null, p_limit integer default 25)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.discord_act(p_discord_id);
  v_q text := nullif(trim(coalesce(p_query, '')), '');
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('event_id', x.id, 'name', x.name, 'format_label', x.format_label, 'status', x.status,
                                        'starts_at', x.starts_at, 'role', x.role, 'players', t1_private.active_players(x.id))
                    order by x.starts_at asc nulls last, x.created_at desc)
      from (
        select e.id, e.name, e.format_label, e.status, e.starts_at, e.created_at,
               case when exists (select 1 from public.event_members m where m.event_id = e.id and m.user_id = v_uid) then 'organizer' else 'player' end role
          from public.events e
         where not e.is_demo and e.status in ('setup', 'seated', 'in_progress')
           and (exists (select 1 from public.event_members m where m.event_id = e.id and m.user_id = v_uid)
                or exists (select 1 from public.participants p where p.event_id = e.id and p.user_id = v_uid))
           and (v_q is null or e.name ilike '%' || replace(replace(v_q, '%', ''), '_', '') || '%')
         order by e.starts_at asc nulls last, e.created_at desc
         limit least(greatest(coalesce(p_limit, 25), 1), 25)) x), '[]'::jsonb);
end $$;
revoke execute on function public.discord_my_events(text, text, integer) from public, anon, authenticated;
grant execute on function public.discord_my_events(text, text, integer) to service_role;
