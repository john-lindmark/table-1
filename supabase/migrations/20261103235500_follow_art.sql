-- A picture for followed decks, cubes and binders (contract/follows-2026-10-25.md § Follow art): follows_list
-- items gain `art`, one printing (Scryfall card id) to draw the item's tile with, picked as the owner's own tiles
-- pick theirs (contract/collection-home-2026-10-27.md § Art): the owner's first hero card, in the printing the item
-- holds most of (else its earliest English printing with an image), else the item's first non-basic card by copies
-- (decks and cubes: main and commander; binders: every copy), then by name. Absent when the item holds nothing.
-- Replaces public.follows_list from 20261026050000_follows.sql, adding only that field.

create or replace function t1_private.follow_art(p_kind text, p_id uuid, p_owner uuid)
returns uuid language sql stable set search_path = '' as $$
  with held as (
    select e.card_id, sum(e.qty)::int qty from public.card_list_entries e
     where p_kind <> 'binder' and e.list_id = p_id and e.board in ('main', 'commander') group by e.card_id
    union all
    select bi.card_id, sum(bi.qty)::int from public.binder_items bi
     where p_kind = 'binder' and bi.binder_id = p_id and bi.qty > 0 group by bi.card_id
  ), hero as (
    select u.oracle_id from public.library_heroes h, unnest(h.oracle_ids) with ordinality u(oracle_id, n)
     where h.user_id = p_owner and h.scope = case when p_kind = 'binder' then 'binder' else 'list' end and h.target_id = p_id
     order by u.n limit 1
  )
  select coalesce(
    (select coalesce(
       (select hd.card_id from held hd join public.cards c on c.id = hd.card_id
         where c.oracle_id = hero.oracle_id order by hd.qty desc, c.released_at nulls last, c.id limit 1),
       (select c.id from public.cards c
         where c.oracle_id = hero.oracle_id and c.lang = 'en' and c.image_faces > 0 order by c.released_at nulls last, c.id limit 1))
       from hero),
    (select hd.card_id from held hd join public.cards c on c.id = hd.card_id join public.card_oracles o on o.oracle_id = c.oracle_id
      where coalesce(o.type_line, '') not like 'Basic%' order by hd.qty desc, o.name, hd.card_id limit 1));
$$;
revoke execute on function t1_private.follow_art(text, uuid, uuid) from public;

-- Everything you follow, updated first. Items you can no longer see say only that.
create or replace function public.follows_list()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  return jsonb_build_object('items', coalesce((
    select jsonb_agg(x.j order by x.unseen > 0 desc, x.last_at desc nulls last, x.name nulls last, x.item_id)
      from (
        select f.item_id, f.unseen, f.last_at, it.name,
               case when f.reach is null then
                 jsonb_build_object('kind', f.kind, 'id', f.item_id, 'available', false, 'push', f.push,
                                    'followed_at', f.followed_at, 'unseen', 0)
               else jsonb_strip_nulls(jsonb_build_object(
                 'kind', f.kind, 'id', f.item_id, 'available', true, 'push', f.push, 'followed_at', f.followed_at,
                 'unseen', f.unseen, 'name', it.name, 'format', it.format, 'for_trade', it.for_trade, 'cards', it.cards,
                 'art', t1_private.follow_art(f.kind, f.item_id, it.owner),
                 'owner', (select jsonb_strip_nulls(jsonb_build_object('display_name', pr.display_name, 'avatar_url', pr.avatar_url))
                             from public.profiles pr where pr.id = it.owner),
                 'user_id', case when f.reach = 'profile' then it.owner end,
                 'token', case when f.reach = 'link' then (select k.token from public.share_links k where k.id = f.link_id) end,
                 'last_update', (select jsonb_build_object('at', u.at, 'added', u.added, 'removed', u.removed)
                                   from t1_private.follow_updates u
                                  where u.item_id = f.item_id and u.at > f.followed_at order by u.at desc limit 1)))
               end j
          from (select fo.*, r.reach,
                       case when r.reach is null then 0 else
                         (select count(*) from t1_private.follow_updates u
                           where u.item_id = fo.item_id and u.at > fo.followed_at and u.at > fo.seen_at) end unseen,
                       case when r.reach is null then null else
                         (select max(u.at) from t1_private.follow_updates u where u.item_id = fo.item_id and u.at > fo.followed_at) end last_at
                  from public.follows fo
                  cross join lateral (select t1_private.follow_reach(v_uid, fo.kind, fo.item_id, fo.link_id) reach) r
                 where fo.user_id = v_uid) f
          left join lateral (
            select b.user_id owner, b.name, null::text format, b.for_trade,
                   (select coalesce(sum(bi.qty), 0)::int from public.binder_items bi where bi.binder_id = b.id and bi.qty > 0) cards
              from public.binders b where f.reach is not null and f.kind = 'binder' and b.id = f.item_id
            union all
            select l.user_id, l.name, l.format, null::boolean,
                   (select coalesce(sum(e.qty), 0)::int from public.card_list_entries e where e.list_id = l.id and e.board <> 'maybe')
              from public.card_lists l where f.reach is not null and f.kind <> 'binder' and l.id = f.item_id
          ) it on true
      ) x), '[]'::jsonb));
end $$;
