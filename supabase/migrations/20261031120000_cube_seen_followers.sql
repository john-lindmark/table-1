-- Following a cube through a live share link lets you rank it (contract/owned-by-card-2026-10-31.md § 3).
-- cube_seen counted only the owner's profile, so a cube shared by link could be followed but not ranked; clients hid
-- Rankings on a link. Now a follow whose link still reaches the cube (t1_private.follow_reach: live link, not
-- unshared by moderation, no block) counts as seeing it. Replaces 20261021120000's cube_seen.
create or replace function t1_private.cube_seen(p_list_id uuid, p_viewer uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_viewer is not null and (
    exists (
      select 1 from public.card_lists l, t1_private.share_of(l.user_id) s
       where l.id = p_list_id and l.kind = 'cube' and l.deleted_at is null
         and (l.user_id = p_viewer
              or (t1_private.live_account(l.user_id)
                  and t1_private.vis_ok(t1_private.share_level(l.user_id, p_viewer), s.profile,
                                        coalesce(l.visibility, s.cubes, s.library)))))
    or exists (
      select 1 from public.follows f
       where f.user_id = p_viewer and f.item_id = p_list_id and f.kind = 'cube' and f.link_id is not null
         and t1_private.follow_reach(p_viewer, 'cube', p_list_id, f.link_id) = 'link'
         and exists (select 1 from public.card_lists l where l.id = p_list_id and t1_private.live_account(l.user_id))));
$$;
revoke execute on function t1_private.cube_seen(uuid, uuid) from public;
