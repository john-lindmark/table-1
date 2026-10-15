-- Run by John in the Supabase SQL Editor on 2026-10-06 (the connector held it for approval).
create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
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
revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

drop index if exists public.audit_log_event_at_idx;
drop index if exists public.match_sides_match_side_uniq;
