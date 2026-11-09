-- Friends on profiles (contract/friends-sharing-2026-10-18.md § Friends on profiles, John 2026-11-09): "the ability to
-- see other people's friends in profiles and for users to set the visibility of themselves across friends and the
-- ability to set who can see their friends on their own profile."
--
-- Two new settings on share_settings, both capped by the profile like every other part:
--   friends  private (default)  who sees your friends list on your profile
--   listed   friends (default)  who sees *you* in the friends lists of your friends' profiles
-- A friend shows in a list to a viewer only when the list reaches the viewer (the owner's `friends`) and that friend's
-- own `listed` reaches the viewer too (as that friend's part: their level to the viewer, capped by their profile).
-- The viewer always sees themselves; the owner sees every friend. Blocks either way, deleted and demo accounts
-- never show. No total is ever returned, only the rows that reach you (friend counts stay private, § UX rules 7).

-- ==================================================================== a_settings
alter table public.share_settings add column if not exists friends text not null default 'private'
  check (friends in ('private', 'friends', 'public'));
alter table public.share_settings add column if not exists listed text not null default 'friends'
  check (listed in ('private', 'friends', 'public'));

-- share_of builds the row by position: the two new columns go after updated_at. Restricted accounts share nothing.
create or replace function t1_private.share_of(p_owner uuid)
returns public.share_settings language sql stable security definer set search_path = '' as $$
  select case when t1_private.is_restricted(p_owner) then
      row(p_owner, 'private', 'private', null, null, null, null, null, null, 'private', now(), 'private', 'private')::public.share_settings
    else coalesce(
      (select s from public.share_settings s where s.user_id = p_owner),
      row(p_owner, 'friends', 'private', null, null, null, null, null, null, 'private', now(), 'private', 'friends')::public.share_settings) end;
$$;

-- ==================================================================== b_shown
-- p_owner's friends that reach p_viewer, with whether each is also the viewer's friend. Only call once the owner's
-- list itself reaches the viewer.
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
      or (select t1_private.vis_ok(t1_private.share_level(fr.uid, p_viewer), s.profile, s.listed)
            from t1_private.share_of(fr.uid) s);
$$;

-- ==================================================================== c_sharing
create or replace function public.sharing_get()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  s public.share_settings;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  s := t1_private.share_of(v_uid);
  return jsonb_build_object(
    'profile', s.profile, 'library', s.library, 'all_cards', s.all_cards, 'for_trade', s.for_trade, 'wants', s.wants,
    'binders', s.binders, 'decks', s.decks, 'cubes', s.cubes, 'record', s.record,
    'friends', s.friends, 'listed', s.listed,
    'items', coalesce((select jsonb_agg(i order by i->>'kind', lower(i->>'name'), i->>'id') from (
        select jsonb_build_object('kind', 'binder', 'id', b.id, 'name', b.name, 'for_trade', b.for_trade,
                                  'visibility', b.visibility) i
          from public.binders b where b.user_id = v_uid and b.deleted_at is null
        union all
        select jsonb_build_object('kind', l.kind, 'id', l.id, 'name', l.name, 'visibility', l.visibility)
          from public.card_lists l where l.user_id = v_uid and l.deleted_at is null) x), '[]'::jsonb),
    'links', coalesce((select jsonb_agg(t1_private.share_link_json(k) order by k.part, k.item_id)
                         from public.share_links k
                        where k.user_id = v_uid and k.revoked_at is null
                          and t1_private.share_part_name(v_uid, k.part, k.item_id) is not null), '[]'::jsonb));
end $$;

create or replace function public.sharing_set(p_settings jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_old public.share_settings;
  v_new public.share_settings;
  v_key text;
  v_val text;
  v_item jsonb;
  v_before text;
  v_n integer;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then
    raise exception 'Settings must be an object' using errcode = '22023';
  end if;
  for v_key in select jsonb_object_keys(p_settings) loop
    if v_key not in ('profile', 'library', 'all_cards', 'for_trade', 'wants', 'binders', 'decks', 'cubes', 'record',
                     'friends', 'listed', 'items') then
      raise exception 'Unknown setting: %', v_key using errcode = '22023';
    end if;
    continue when v_key = 'items';
    v_val := p_settings->>v_key;
    if v_val is null and v_key in ('profile', 'library', 'record', 'friends', 'listed') then
      raise exception '% needs a value', v_key using errcode = '22023';
    end if;
    if v_val is not null and v_val not in ('private', 'friends', 'public') then
      raise exception 'Visibility is private, friends or public' using errcode = '22023';
    end if;
  end loop;
  if p_settings ? 'items' and (jsonb_typeof(p_settings->'items') <> 'array' or jsonb_array_length(p_settings->'items') > 500) then
    raise exception 'Items must be a list of at most 500' using errcode = '22023';
  end if;

  v_old := t1_private.share_of(v_uid);
  v_new := v_old;
  if p_settings ? 'profile' then v_new.profile := p_settings->>'profile'; end if;
  if p_settings ? 'library' then v_new.library := p_settings->>'library'; end if;
  if p_settings ? 'record' then v_new.record := p_settings->>'record'; end if;
  if p_settings ? 'all_cards' then v_new.all_cards := p_settings->>'all_cards'; end if;
  if p_settings ? 'for_trade' then v_new.for_trade := p_settings->>'for_trade'; end if;
  if p_settings ? 'wants' then v_new.wants := p_settings->>'wants'; end if;
  if p_settings ? 'binders' then v_new.binders := p_settings->>'binders'; end if;
  if p_settings ? 'decks' then v_new.decks := p_settings->>'decks'; end if;
  if p_settings ? 'cubes' then v_new.cubes := p_settings->>'cubes'; end if;
  if p_settings ? 'friends' then v_new.friends := p_settings->>'friends'; end if;
  if p_settings ? 'listed' then v_new.listed := p_settings->>'listed'; end if;
  if (to_jsonb(v_new) - 'updated_at') is distinct from (to_jsonb(v_old) - 'updated_at') then
    insert into public.share_settings as s (user_id, profile, library, all_cards, for_trade, wants, binders, decks, cubes,
                                            record, friends, listed)
    values (v_uid, v_new.profile, v_new.library, v_new.all_cards, v_new.for_trade, v_new.wants, v_new.binders,
            v_new.decks, v_new.cubes, v_new.record, v_new.friends, v_new.listed)
    on conflict (user_id) do update set
      profile = excluded.profile, library = excluded.library, all_cards = excluded.all_cards,
      for_trade = excluded.for_trade, wants = excluded.wants, binders = excluded.binders, decks = excluded.decks,
      cubes = excluded.cubes, record = excluded.record, friends = excluded.friends, listed = excluded.listed,
      updated_at = now();
    insert into public.account_audit (actor, action, before, after)
    values (v_uid, 'sharing.set', to_jsonb(v_old) - 'updated_at' - 'user_id', to_jsonb(v_new) - 'updated_at' - 'user_id');
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_settings->'items', '[]'::jsonb)) loop
    v_val := v_item->>'visibility';
    if v_val is not null and v_val not in ('private', 'friends', 'public') then
      raise exception 'Visibility is private, friends or public' using errcode = '22023';
    end if;
    if v_item->>'kind' = 'binder' then
      select visibility into v_before from public.binders
       where id = (v_item->>'id')::uuid and user_id = v_uid and deleted_at is null for update;
      get diagnostics v_n = row_count;
      if v_n = 0 then raise exception 'That isn''t yours' using errcode = '42501'; end if;
      continue when v_before is not distinct from v_val;
      update public.binders set visibility = v_val where id = (v_item->>'id')::uuid;
    elsif v_item->>'kind' in ('deck', 'cube') then
      select visibility into v_before from public.card_lists
       where id = (v_item->>'id')::uuid and user_id = v_uid and kind = v_item->>'kind' and deleted_at is null for update;
      get diagnostics v_n = row_count;
      if v_n = 0 then raise exception 'That isn''t yours' using errcode = '42501'; end if;
      continue when v_before is not distinct from v_val;
      update public.card_lists set visibility = v_val where id = (v_item->>'id')::uuid;
    else
      raise exception 'An item is a binder, deck or cube' using errcode = '22023';
    end if;
    insert into public.account_audit (actor, action, target_id, before, after)
    values (v_uid, 'sharing.item', (v_item->>'id')::uuid, jsonb_build_object('visibility', v_before),
            jsonb_build_object('kind', v_item->>'kind', 'visibility', v_val));
  end loop;
  return public.sharing_get();
end $$;

-- ==================================================================== d_profile
-- profile_view (20261018160000_friends_privacy_fixes.sql) plus a `friends` section when your list reaches the viewer:
-- {mutual}: how many of the friends shown to them are their friends too (0 on your own profile).
create or replace function public.profile_view(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  pr public.profiles;
  s public.share_settings;
  v_level integer;
  v_sections jsonb := '{}'::jsonb;
  v_rel text;
  v_since timestamptz;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into pr from public.profiles where id = p_user_id;
  if pr.id is null or pr.deleted_at is not null or (pr.is_demo and pr.id <> v_uid) then
    raise exception 'That account isn''t on Table 1' using errcode = 'P0002';
  end if;
  v_level := t1_private.share_level(p_user_id, v_uid);
  v_rel := t1_private.relation(v_uid, p_user_id);
  s := t1_private.share_of(p_user_id);
  if v_rel = 'friend' then
    select coalesce(f.responded_at, f.created_at) into v_since from public.friendships f
     where f.user_lo = least(v_uid, p_user_id) and f.user_hi = greatest(v_uid, p_user_id);
  end if;

  if t1_private.vis_ok(v_level, s.profile, 'public') then
    if t1_private.vis_ok(v_level, s.profile, coalesce(s.all_cards, s.library)) then
      -- The collection's value is yours alone.
      v_sections := v_sections || jsonb_build_object('all_cards', coalesce(
        (select jsonb_build_object('cards', ls.total_qty, 'printings', ls.unique_printings)
                || case when v_level >= 3 then jsonb_build_object('value_usd', ls.value_usd) else '{}'::jsonb end
           from public.library_summary ls where ls.user_id = p_user_id),
        jsonb_build_object('cards', 0, 'printings', 0)
          || case when v_level >= 3 then jsonb_build_object('value_usd', 0) else '{}'::jsonb end));
    end if;
    if exists (select 1 from t1_private.trade_binders_for(p_user_id, v_level)) then
      v_sections := v_sections || jsonb_build_object('for_trade', jsonb_build_object('cards',
        (select coalesce(sum(bi.qty), 0) from public.binder_items bi
           where bi.binder_id in (select t1_private.trade_binders_for(p_user_id, v_level)) and bi.qty > 0)));
    end if;
    if t1_private.vis_ok(v_level, s.profile, coalesce(s.wants, s.library)) then
      v_sections := v_sections || jsonb_build_object('wants', jsonb_build_object('cards',
        (select coalesce(sum(w.qty), 0) from public.wants w where w.user_id = p_user_id and w.qty > 0)));
    end if;
    v_sections := v_sections || jsonb_build_object('binders', coalesce((
      select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'for_trade', b.for_trade,
               'cards', (select coalesce(sum(bi.qty), 0) from public.binder_items bi where bi.binder_id = b.id and bi.qty > 0))
             order by lower(b.name), b.id)
        from public.binders b
       where b.user_id = p_user_id and b.deleted_at is null
         and t1_private.vis_ok(v_level, s.profile, coalesce(b.visibility, s.binders, s.library))), '[]'::jsonb));
    v_sections := v_sections || jsonb_build_object('decks', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'format', l.format,
               'cards', (select coalesce(sum(e.qty), 0) from public.card_list_entries e where e.list_id = l.id and e.board <> 'maybe'))
             order by lower(l.name), l.id)
        from public.card_lists l
       where l.user_id = p_user_id and l.kind = 'deck' and l.deleted_at is null
         and t1_private.vis_ok(v_level, s.profile, coalesce(l.visibility, s.decks, s.library))), '[]'::jsonb));
    v_sections := v_sections || jsonb_build_object('cubes', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'format', l.format,
               'cards', (select coalesce(sum(e.qty), 0) from public.card_list_entries e where e.list_id = l.id and e.board <> 'maybe'))
             order by lower(l.name), l.id)
        from public.card_lists l
       where l.user_id = p_user_id and l.kind = 'cube' and l.deleted_at is null
         and t1_private.vis_ok(v_level, s.profile, coalesce(l.visibility, s.cubes, s.library))), '[]'::jsonb));
    if t1_private.vis_ok(v_level, s.profile, s.record) then
      v_sections := v_sections || jsonb_build_object('record', (
        select jsonb_build_object('match_wins', coalesce(sum(o.mw), 0), 'match_losses', coalesce(sum(o.ml), 0),
                                  'match_draws', coalesce(sum(o.md), 0), 'events_played', count(distinct o.event_id))
          from public.match_outcomes o where o.user_id = p_user_id and not o.is_demo));
    end if;
    if t1_private.vis_ok(v_level, s.profile, s.friends) then
      v_sections := v_sections || jsonb_build_object('friends', jsonb_build_object('mutual',
        (select count(*) from t1_private.friends_shown(p_user_id, v_uid) x where x.mutual)));
    end if;
  end if;

  return t1_private.person_json(p_user_id) || jsonb_build_object(
    'relation', v_rel, 'friends_since', v_since,
    'visible', t1_private.vis_ok(v_level, s.profile, 'public'), 'sections', v_sections);
end $$;

-- The friends behind a profile's Friends section, paged by offset: {rows: [Person + relation (to you) + mutual], more}.
-- Mutual friends first, then by name. Not visible (or no such account): "That's private".
create or replace function public.profile_friends(p_user_id uuid, p_after integer default 0, p_limit integer default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  s public.share_settings;
  v_level integer;
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_rows jsonb;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  v_level := t1_private.share_level(p_user_id, v_uid);
  s := t1_private.share_of(p_user_id);
  if not exists (select 1 from public.profiles pr where pr.id = p_user_id and pr.deleted_at is null
                    and (not pr.is_demo or pr.id = v_uid))
     or not t1_private.vis_ok(v_level, s.profile, s.friends) then
    raise exception 'That''s private' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(r.j order by r.n), '[]'::jsonb) into v_rows from (
    select t1_private.person_json(x.user_id)
             || jsonb_build_object('relation', t1_private.relation(v_uid, x.user_id), 'mutual', x.mutual) j,
           row_number() over (order by x.mutual desc, lower(pr.display_name), x.user_id) n
      from t1_private.friends_shown(p_user_id, v_uid) x
      join public.profiles pr on pr.id = x.user_id
     order by x.mutual desc, lower(pr.display_name), x.user_id
    offset greatest(coalesce(p_after, 0), 0) limit v_limit + 1) r;
  return jsonb_build_object(
    'rows', coalesce((select jsonb_agg(e order by i) from jsonb_array_elements(v_rows) with ordinality t(e, i)
                       where i <= v_limit), '[]'::jsonb),
    'more', jsonb_array_length(v_rows) > v_limit);
end $$;

-- ==================================================================== e_grants
revoke execute on function t1_private.friends_shown(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.profile_friends(uuid, integer, integer) from public, anon;
grant execute on function public.profile_friends(uuid, integer, integer) to authenticated;
revoke execute on function public.profile_view(uuid) from public, anon;
grant execute on function public.profile_view(uuid) to authenticated;
revoke execute on function public.sharing_get() from public, anon;
grant execute on function public.sharing_get() to authenticated;
revoke execute on function public.sharing_set(jsonb) from public, anon;
grant execute on function public.sharing_set(jsonb) to authenticated;
