-- "You in friends' lists" defaults to friends of friends (John, 2026-11-09: "can we make the default setting for folks
-- to be able to be seen by friends of friends?"; contract/friends-sharing-2026-10-18.md § Friends on profiles).
-- `listed` keeps its wire values so every build still reads it; what they mean in a friend's list changes:
--   private  only you (and that friend, whose list it is)
--   friends  friends of friends: your friends, and that friend's friends (the default)
--   public   anyone who can see that friend's list
-- and only a Private profile caps it (name and photo already show to every signed-in account; a Friends profile no
-- longer narrows Anyone to friends here). Blocks either way, deleted, demo and restricted accounts still never show.
-- Nobody had changed `listed` on live when this was written, so every account gets the new default meaning.
--
-- And the friends list itself shows to friends by default (John, the same day: "and that the friends list is default
-- viewable by friends for profiles"): `friends` defaults to friends, and accounts still on the old Private default
-- move to Friends. Anyone who picked Private on purpose (an audited sharing.set to private) keeps it.

alter table public.share_settings alter column friends set default 'friends';
update public.share_settings s set friends = 'friends', updated_at = now()
 where s.friends = 'private'
   and not exists (select 1 from public.account_audit a
                    where a.actor = s.user_id and a.action = 'sharing.set' and a.after->>'friends' = 'private'
                      and (a.before->>'friends') is distinct from 'private');

-- share_of's defaults for an account with no row (restricted accounts still share nothing).
create or replace function t1_private.share_of(p_owner uuid)
returns public.share_settings language sql stable security definer set search_path = '' as $$
  select case when t1_private.is_restricted(p_owner) then
      row(p_owner, 'private', 'private', null, null, null, null, null, null, 'private', now(), 'private', 'private')::public.share_settings
    else coalesce(
      (select s from public.share_settings s where s.user_id = p_owner),
      row(p_owner, 'friends', 'private', null, null, null, null, null, null, 'private', now(), 'friends', 'friends')::public.share_settings) end;
$$;

create or replace function t1_private.friends_shown(p_owner uuid, p_viewer uuid)
returns table (user_id uuid, mutual boolean) language sql stable security definer set search_path = '' as $$
  with fr as (
    select f.user_hi as uid from public.friendships f where f.user_lo = p_owner and f.status = 'accepted'
    union all
    select f.user_lo from public.friendships f where f.user_hi = p_owner and f.status = 'accepted')
  select fr.uid,
         fr.uid <> p_viewer and p_owner <> p_viewer and exists (
           select 1 from public.friendships m
            where m.user_lo = least(fr.uid, p_viewer) and m.user_hi = greatest(fr.uid, p_viewer) and m.status = 'accepted')
    from fr
    join public.profiles pr on pr.id = fr.uid and pr.deleted_at is null and not pr.is_demo
   where p_owner = p_viewer or fr.uid = p_viewer
      or (select s.profile <> 'private' and lv.level >= 0
                 and case s.listed
                       when 'public' then true
                       when 'friends' then lv.level >= 1 or t1_private.share_level(p_owner, p_viewer) >= 1
                       else false end
            from t1_private.share_of(fr.uid) s, (select t1_private.share_level(fr.uid, p_viewer) as level) lv);
$$;

revoke execute on function t1_private.friends_shown(uuid, uuid) from public, anon, authenticated;
