-- Search finds decks, cubes and binders (contract/library-search-2026-10-18.md § Collection search).
-- The Collection home's Search found cards only. Clients match your own decks, cubes and binders on the device;
-- library_search finds everyone else's you can see: what you follow (on their profile or through the link you
-- followed with), and what their sharing settings show you (friends', and anyone's set to Anyone on a public
-- profile). Every word of the query must be in the item's name, its owner's name or its format.
-- Order: followed, friends', people you've played with, then everyone else's; names starting with the first word
-- first, then by name. Never your own, a deleted or demo owner's, or across a block.

create or replace function public.library_search(p_query text, p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_words text[];
  v_friends uuid[];
  v_blocked uuid[];
  v_played uuid[];
  v_follows uuid[];
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 50);
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  v_words := array(select w from regexp_split_to_table(lower(coalesce(p_query, '')), '\s+') w where w <> '' limit 6);
  if coalesce(length(array_to_string(v_words, '')), 0) < 2 then return jsonb_build_object('items', '[]'::jsonb); end if;
  -- Who the caller is to everyone, once (share_level per row was most of the time on 20k lists).
  v_friends := array(select case when f.user_lo = v_uid then f.user_hi else f.user_lo end from public.friendships f
                      where f.status = 'accepted' and (f.user_lo = v_uid or f.user_hi = v_uid));
  v_blocked := array(select b.blocked_id from public.user_blocks b where b.user_id = v_uid
                     union select b.user_id from public.user_blocks b where b.blocked_id = v_uid);
  v_played := array(select pw.user_id from t1_private.played_with(v_uid) pw);
  v_follows := array(select f.item_id from public.follows f where f.user_id = v_uid);

  return jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'kind', r.kind, 'id', r.id, 'name', r.name, 'format', r.format, 'for_trade', r.for_trade,
             'cards', case when r.kind = 'binder'
                        then (select coalesce(sum(bi.qty), 0)::int from public.binder_items bi where bi.binder_id = r.id and bi.qty > 0)
                        else (select coalesce(sum(e.qty), 0)::int from public.card_list_entries e where e.list_id = r.id and e.board <> 'maybe') end,
             'owner', jsonb_strip_nulls(jsonb_build_object('display_name', r.owner_name, 'avatar_url', r.avatar_url)),
             'user_id', case when r.via_profile then r.owner end,
             'token', case when not r.via_profile then r.token end,
             'following', r.followed))
           order by r.ord)
      from (
        select x.*, row_number() over (order by not x.followed, x.rel, not starts_with(lower(x.name), v_words[1]),
                                                lower(x.name), x.id) ord
          from (
            select c.*, lk.token
              from (
                select c.*,
                       t1_private.vis_ok(case when c.owner = any(v_friends) then 1 else 0 end, coalesce(ss.profile, 'friends'),
                         coalesce(c.visibility, case c.kind when 'binder' then ss.binders when 'deck' then ss.decks else ss.cubes end,
                                  ss.library, 'private')) via_profile,
                       c.id = any(v_follows) followed,
                       case when c.owner = any(v_friends) then 1 when c.owner = any(v_played) then 2 else 3 end rel
                  from (
                    select l.kind, l.id, l.name, l.format, null::boolean for_trade, l.visibility, l.user_id owner,
                           pr.display_name owner_name, pr.avatar_url
                      from public.card_lists l
                      join public.profiles pr on pr.id = l.user_id and pr.deleted_at is null and not pr.is_demo
                     where l.kind in ('deck', 'cube') and l.deleted_at is null and l.user_id <> v_uid
                       and (select bool_and(strpos(lower(l.name || ' ' || coalesce(pr.display_name, '') || ' ' || coalesce(l.format, '')), w) > 0)
                              from unnest(v_words) w)
                    union all
                    select 'binder', b.id, b.name, null, b.for_trade, b.visibility, b.user_id, pr.display_name, pr.avatar_url
                      from public.binders b
                      join public.profiles pr on pr.id = b.user_id and pr.deleted_at is null and not pr.is_demo
                     where b.deleted_at is null and b.user_id <> v_uid
                       and (select bool_and(strpos(lower(b.name || ' ' || coalesce(pr.display_name, '')), w) > 0)
                              from unnest(v_words) w)
                  ) c
                  left join public.share_settings ss on ss.user_id = c.owner
                 where not c.owner = any(v_blocked)
              ) c
              -- A link is looked at only for what you follow and can't see on the profile.
              left join lateral (
                select k.token from public.follows f join public.share_links k on k.id = f.link_id
                 where not c.via_profile and c.followed
                   and f.user_id = v_uid and f.item_id = c.id and f.link_id is not null
                   and t1_private.follow_reach(v_uid, c.kind, c.id, f.link_id) = 'link'
                 limit 1) lk on true
          ) x
         where x.via_profile or x.token is not null
         order by ord
         limit v_limit) r), '[]'::jsonb));
end $$;

revoke execute on function public.library_search(text, integer) from public;
grant execute on function public.library_search(text, integer) to authenticated;
