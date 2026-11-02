-- Search: a card named exactly is the only card looked for (contract/library-search-2026-10-18.md § Collection search).
-- On live, "lightning bolt" also found John's trade binder for its Emeritus of Conflict // Lightning Bolt. When one of
-- the closest five cards' names is the query itself, only that card counts. Otherwise as 20261102140000.

create or replace function public.library_search(p_query text, p_limit integer default 20, p_all boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_words text[];
  v_query text;
  v_friends uuid[];
  v_blocked uuid[];
  v_played uuid[];
  v_follows uuid[];
  v_restricted uuid[];
  v_oracles uuid[] := '{}';
  v_prints uuid[] := '{}';
  v_has_lists uuid[] := '{}';
  v_has_binders uuid[] := '{}';
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_all boolean := coalesce(p_all, false);
  v_lists jsonb;
  v_archetypes jsonb := '[]';
  v_rankings jsonb := '[]';
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  v_words := array(select w from regexp_split_to_table(lower(coalesce(p_query, '')), '\s+') w where w <> '' limit 6);
  if coalesce(length(array_to_string(v_words, '')), 0) < 2 then return jsonb_build_object('items', '[]'::jsonb); end if;
  v_query := array_to_string(v_words, ' ');
  -- Who the caller is to everyone, once (share_level per row was most of the time on 20k lists).
  v_friends := array(select case when f.user_lo = v_uid then f.user_hi else f.user_lo end from public.friendships f
                      where f.status = 'accepted' and (f.user_lo = v_uid or f.user_hi = v_uid));
  v_blocked := array(select b.blocked_id from public.user_blocks b where b.user_id = v_uid
                     union select b.user_id from public.user_blocks b where b.blocked_id = v_uid);
  v_played := array(select pw.user_id from t1_private.played_with(v_uid) pw);
  v_follows := array(select f.item_id from public.follows f where f.user_id = v_uid);
  v_restricted := array(select r.user_id from public.moderation_restrictions r where r.until > now());

  -- The cards the query names: every word in the name, basics left out, the closest five.
  if v_all and length(array_to_string(v_words, '')) >= 3 then
    v_oracles := array(
      select o.oracle_id from public.card_oracles o
       where (select bool_and(strpos(lower(o.name), w) > 0) from unnest(v_words) w)
         and coalesce(o.type_line, '') not like 'Basic Land%'
       order by lower(o.name) = v_query desc, starts_with(lower(o.name), v_words[1]) desc, length(o.name), o.name
       limit 5);
    -- A card named exactly is the one meant: "lightning bolt" isn't also Emeritus of Conflict // Lightning Bolt.
    if exists (select 1 from public.card_oracles o where o.oracle_id = v_oracles[1] and lower(o.name) = v_query) then
      v_oracles := v_oracles[1:1];
    end if;
    v_prints := array(select c.id from public.cards c where c.oracle_id = any(v_oracles));
    v_has_lists := array(select distinct e.list_id from public.card_list_entries e
                          where e.card_id = any(v_prints) and e.board <> 'maybe' and e.qty > 0);
    v_has_binders := array(select distinct bi.binder_id from public.binder_items bi where bi.card_id = any(v_prints) and bi.qty > 0);
  end if;

  v_lists := coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'kind', r.kind, 'id', r.id, 'name', r.name, 'format', r.format, 'for_trade', r.for_trade,
             'cards', case when r.kind = 'binder'
                        then (select coalesce(sum(bi.qty), 0)::int from public.binder_items bi where bi.binder_id = r.id and bi.qty > 0)
                        else (select coalesce(sum(e.qty), 0)::int from public.card_list_entries e where e.list_id = r.id and e.board <> 'maybe') end,
             'owner', case when not r.mine then jsonb_strip_nulls(jsonb_build_object('display_name', r.owner_name, 'avatar_url', r.avatar_url)) end,
             'user_id', case when r.via_profile and not r.mine then r.owner end,
             'token', case when not r.via_profile and not r.mine then r.token end,
             'following', r.followed,
             'mine', case when r.mine then true end,
             'has', case when not r.named and r.has_oracle is not null then
                      jsonb_build_object('name', (select o.name from public.card_oracles o where o.oracle_id = r.has_oracle), 'qty', r.has_qty) end))
           order by r.ord)
      from (
        select x.*, row_number() over (order by not x.mine, not x.followed, x.rel, not x.named,
                                                not starts_with(lower(x.name), v_words[1]), lower(x.name), x.id) ord,
               row_number() over (partition by x.kind order by not x.mine, not x.followed, x.rel, not x.named,
                                                not starts_with(lower(x.name), v_words[1]), lower(x.name), x.id) n
          from (
            select c.*, lk.token
              from (
                select c.*,
                       c.mine or (not c.owner = any(v_restricted)
                         and t1_private.vis_ok(case when c.owner = any(v_friends) then 1 else 0 end, coalesce(ss.profile, 'friends'),
                               coalesce(c.visibility, case c.kind when 'binder' then ss.binders when 'deck' then ss.decks else ss.cubes end,
                                        ss.library, 'private'))) via_profile,
                       c.id = any(v_follows) followed,
                       case when c.mine then 0 when c.owner = any(v_friends) then 1 when c.owner = any(v_played) then 2 else 3 end rel
                  from (
                    select l.kind, l.id, l.name, l.format, null::boolean for_trade, l.visibility, l.user_id owner,
                           pr.display_name owner_name, pr.avatar_url, l.user_id = v_uid mine, nm.named, h.oracle_id has_oracle, h.qty has_qty
                      from public.card_lists l
                      join public.profiles pr on pr.id = l.user_id and pr.deleted_at is null and not pr.is_demo
                      cross join lateral (
                        select coalesce(bool_and(strpos(lower(l.name || ' ' || coalesce(pr.display_name, '') || ' ' || coalesce(l.format, '')), w) > 0), false) named
                          from unnest(v_words) w) nm
                      left join lateral (
                        select c.oracle_id, sum(e.qty)::int qty
                          from public.card_list_entries e join public.cards c on c.id = e.card_id
                         where l.id = any(v_has_lists) and e.list_id = l.id and e.card_id = any(v_prints)
                           and e.board <> 'maybe' and e.qty > 0
                         group by c.oracle_id order by 2 desc, 1 limit 1) h on true
                     where l.kind in ('deck', 'cube') and l.deleted_at is null
                       -- everyone else's by name or card; your own only by card (the device has them by name)
                       and case when l.user_id = v_uid then not nm.named and h.oracle_id is not null
                                else nm.named or h.oracle_id is not null end
                    union all
                    select 'binder', b.id, b.name, null, b.for_trade, b.visibility, b.user_id, pr.display_name, pr.avatar_url,
                           b.user_id = v_uid, nm.named, h.oracle_id, h.qty
                      from public.binders b
                      join public.profiles pr on pr.id = b.user_id and pr.deleted_at is null and not pr.is_demo
                      cross join lateral (
                        select coalesce(bool_and(strpos(lower(b.name || ' ' || coalesce(pr.display_name, '')), w) > 0), false) named
                          from unnest(v_words) w) nm
                      left join lateral (
                        select c.oracle_id, sum(bi.qty)::int qty
                          from public.binder_items bi join public.cards c on c.id = bi.card_id
                         where b.id = any(v_has_binders) and bi.binder_id = b.id and bi.card_id = any(v_prints) and bi.qty > 0
                         group by c.oracle_id order by 2 desc, 1 limit 1) h on true
                     where b.deleted_at is null
                       and case when b.user_id = v_uid then not nm.named and h.oracle_id is not null
                                else nm.named or h.oracle_id is not null end
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
      ) r
     where case when v_all then r.n <= v_limit else r.ord <= v_limit end), '[]'::jsonb);

  if v_all then
    -- Insights archetypes in the formats it reads, with lists in the last 90 days; the most played first.
    v_archetypes := coalesce((
      select jsonb_agg(jsonb_build_object('kind', 'archetype', 'id', a.id::text, 'name', a.name, 'format', a.format, 'decks', a.decks)
                       order by a.decks desc, a.name)
        from (select a.* from (
          select a.id, a.name, a.format,
                 (select count(*)::int from t1_private.meta_decks d
                   where d.format = a.format and d.archetype_id = a.id and d.on_date >= current_date - 90) decks
            from t1_private.meta_archetypes a
            join t1_private.meta_formats f on f.format = a.format and f.enabled
           where a.status = 'approved'
             and (select bool_and(strpos(lower(a.name || ' ' || a.format || ' ' || coalesce(f.name, '')), w) > 0) from unnest(v_words) w)
        ) a where a.decks > 0 order by a.decks desc, a.name limit v_limit) a), '[]'::jsonb);

    -- Rankings you can see: by what they rank, who ranked it, or its label. Yours first, then friends', newest first.
    v_rankings := coalesce((
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'kind', 'ranking', 'id', r.id, 'name', r.subject_name, 'subject', r.subject,
               'label', r.label, 'owner', jsonb_build_object('display_name', r.owner_name),
               'mine', case when r.mine then true end))
             order by r.mine desc, r.friend desc, r.updated_at desc)
        from (select r.* from (
          select r.id, r.updated_at, r.user_id = v_uid mine, r.user_id = any(v_friends) friend, pr.display_name owner_name,
                 coalesce(case when r.set_key is not null then 'set:' || r.set_key end, r.list_id::text) subject,
                 nullif(nullif(btrim(r.name), ''), 'My ranking') label,
                 coalesce(l.name, (select v.name from t1_private.limited_cube_versions v where v.key = r.set_key),
                          (select s.name from public.mtg_sets s where s.code = lower(r.set_key)), r.set_key) subject_name, r rk
            from public.cube_rankings r
            join public.profiles pr on pr.id = r.user_id
            left join public.card_lists l on l.id = r.list_id and l.deleted_at is null
           where (r.set_key is not null or l.id is not null)
             and not r.user_id = any(v_blocked)
        ) r
       where (select bool_and(strpos(lower(coalesce(r.subject_name, '') || ' ' || coalesce(r.owner_name, '') || ' '
                                           || coalesce(r.label, '') || ' ' || r.subject), w) > 0) from unnest(v_words) w)
         and t1_private.ranking_seen(r.rk, v_uid)
       order by r.mine desc, r.friend desc, r.updated_at desc limit v_limit) r), '[]'::jsonb);
  end if;

  return jsonb_build_object('items', v_lists || v_archetypes || v_rankings);
end $$;

revoke execute on function public.library_search(text, integer, boolean) from public;
grant execute on function public.library_search(text, integer, boolean) to authenticated;
