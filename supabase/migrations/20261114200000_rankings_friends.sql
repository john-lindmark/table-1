-- Insights → Rankings (contract/main-nav-2026-11-14.md § Rankings): your friends' rankings, every subject, newest first.
-- Only rankings the viewer may open (t1_private.ranking_seen: shared ones, a cube ranking only when its cube reaches
-- them), only accepted friends (blocks end a friendship), never your own (cube_rankings() lists those), never a ranking
-- of a deleted cube. Each row as cube_rankings() writes it with its subject under `cube`.
create or replace function public.rankings_friends(p_limit integer default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select coalesce(jsonb_agg(t1_private.ranking_json(r, v_uid)
                              || jsonb_build_object('cube', t1_private.ranking_subject_json(r, v_uid))
                            order by r.updated_at desc, r.id), '[]'::jsonb)
    into v
    from (select r.*
            from public.cube_rankings r
            join public.friendships f
              on f.user_lo = least(r.user_id, v_uid) and f.user_hi = greatest(r.user_id, v_uid) and f.status = 'accepted'
           where r.user_id <> v_uid
             and t1_private.ranking_seen(r, v_uid)
             and (r.set_key is not null
                  or exists (select 1 from public.card_lists l where l.id = r.list_id and l.deleted_at is null))
           order by r.updated_at desc, r.id
           limit greatest(1, least(coalesce(p_limit, 200), 500))) r;
  return v;
end $$;
revoke execute on function public.rankings_friends(integer) from public, anon;
grant execute on function public.rankings_friends(integer) to authenticated;
