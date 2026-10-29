-- Join the Table 1 Discord server (contract/discord-2026-10-29.md §7 "The Table 1 server"): the web offers the server's
-- invite until you're in it. The `discord-community` edge function asks Discord whether the caller's Discord account is
-- a member, so it needs that account's id: the /link one first, else the Discord sign-in identity (as
-- t1_private.discord_user reads them the other way). Your own id only; signed in only.
create or replace function public.discord_my_id()
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  return coalesce(
    (select l.discord_user_id from t1_private.discord_links l where l.user_id = v_uid),
    (select i.provider_id from auth.identities i
      where i.user_id = v_uid and i.provider = 'discord' order by i.created_at limit 1));
end $$;

revoke execute on function public.discord_my_id() from public, anon;
grant execute on function public.discord_my_id() to authenticated, service_role;
