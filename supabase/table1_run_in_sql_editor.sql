-- Table 1: run once in Supabase → SQL Editor. These are the statements the AI connector can't run (they drop or delete).

alter table public.events add constraint events_cancelled_by_fkey
  foreign key (cancelled_by) references auth.users(id) on delete set null;

alter table public.events drop constraint events_status_check;
alter table public.events add constraint events_status_check
  check (status = any (array['setup', 'seated', 'in_progress', 'completed', 'archived', 'cancelled']));


create or replace function public.apply_match_outcomes(p_match_id uuid, p_reverse_only boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare
  m public.matches;
  r record;
  v_demo boolean;
begin
  for r in delete from public.match_outcomes where match_id = p_match_id returning * loop
    if not r.is_demo then
      perform public._add_outcome(r.user_id, r.opponent_id, -r.mw, -r.ml, -r.md, -r.bye, -r.gw, -r.gl, -r.gd, null);
    end if;
  end loop;

  if p_reverse_only then return; end if;
  select * into m from public.matches where id = p_match_id;
  if m.id is null or not (m.is_bye or m.status in ('reported', 'confirmed')) then return; end if;
  select coalesce(e.is_demo, false) into v_demo from public.events e where e.id = m.event_id;
  v_demo := coalesce(v_demo, false);

  for r in
    select s.user_id,
           (select o.user_id from public.match_sides o
             where o.match_id = s.match_id and o.side <> s.side and o.user_id is not null
             order by o.side limit 1) as opponent_id,
           s.game_wins as gw,
           coalesce((select sum(o.game_wins) from public.match_sides o
                      where o.match_id = s.match_id and o.side <> s.side), 0)::int as gl
      from public.match_sides s
     where s.match_id = p_match_id and s.user_id is not null
  loop
    if m.is_bye then
      insert into public.match_outcomes (match_id, user_id, opponent_id, event_id, bye, played_at, is_demo)
      values (m.id, r.user_id, null, m.event_id, 1, coalesce(m.reported_at, m.created_at), v_demo);
      if not v_demo then
        perform public._add_outcome(r.user_id, null, 0, 0, 0, 1, 0, 0, 0, coalesce(m.reported_at, m.created_at));
      end if;
    else
      insert into public.match_outcomes (match_id, user_id, opponent_id, event_id, mw, ml, md, gw, gl, gd, played_at, is_demo)
      values (m.id, r.user_id, r.opponent_id, m.event_id,
              (r.gw > r.gl)::int, (r.gw < r.gl)::int, (r.gw = r.gl)::int,
              r.gw, r.gl, m.game_draws, coalesce(m.reported_at, m.created_at), v_demo);
      if not v_demo then
        perform public._add_outcome(r.user_id, r.opponent_id,
                (r.gw > r.gl)::int, (r.gw < r.gl)::int, (r.gw = r.gl)::int, 0,
                r.gw, r.gl, m.game_draws, coalesce(m.reported_at, m.created_at));
      end if;
    end if;
  end loop;
end $$;


-- Remove the caller's demo data (also run by delete_account).
create or replace function public.demo_remove()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_events integer;
  v_people integer;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  delete from public.events where is_demo and demo_owner = v_uid;
  get diagnostics v_events = row_count;
  delete from public.event_invites where invited_by in (select id from public.profiles where is_demo and demo_owner = v_uid);
  delete from public.head_to_head
   where opponent_id in (select id from public.profiles where is_demo and demo_owner = v_uid)
      or user_id in (select id from public.profiles where is_demo and demo_owner = v_uid);
  delete from public.player_records where user_id in (select id from public.profiles where is_demo and demo_owner = v_uid);
  delete from public.profiles where is_demo and demo_owner = v_uid;
  get diagnostics v_people = row_count;
  return jsonb_build_object('ok', true, 'events_removed', v_events, 'people_removed', v_people);
end $$;


-- delete_account also clears the caller's demo data.
create or replace function public.delete_account()
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  perform public.demo_remove();
  update public.profiles
     set handle = null, display_name = 'Deleted player', avatar_url = null,
         deleted_at = now(), updated_at = now()
   where id = v_uid;
  update public.participants set display_name = 'Deleted player' where user_id = v_uid;
  delete from public.devices where user_id = v_uid;
  delete from public.notification_prefs where user_id = v_uid;
  delete from public.presence_cells where user_id = v_uid;
  delete from public.event_invites where user_id = v_uid and status = 'pending';
end $$;


grant execute on function public.demo_remove() to authenticated;
revoke execute on function public.demo_remove() from anon, public;

-- Demo loading was held until the records swap above is in place; this re-enables it.
grant execute on function public.demo_seed() to authenticated;
