-- Rankings on profiles (John, 2026-11-10: "add my rankings to my profile and set the visibility to friends but have
-- the ability to set visibility like the other pieces of the profile"; contract/friends-sharing-2026-10-18.md
-- § Rankings on profiles, contract/cube-rankings-2026-10-21.md § Who sees a ranking).
--
-- A new part on share_settings, capped by the profile like every part:
--   rankings  friends (default)  who sees your Rankings section: your cube and set rankings, newest first
-- A ranking set to Only me never shows to anyone else. A cube ranking shows only to people who can see its cube (as
-- before: the part narrows, never widens, a cube ranking). A set ranking was shared with your friends only; it now
-- also reaches whoever the Rankings part reaches (Anyone on a public profile), so the part means what it says.
--
-- Replaces t1_private.share_of (20261109230000_listed_friends_of_friends.sql), t1_private.ranking_seen
-- (20261030140000_limited_rankings.sql), public.sharing_get, public.sharing_set and public.profile_view
-- (20261109210000_profile_friends.sql).

-- ==================================================================== a_settings
alter table public.share_settings add column if not exists rankings text not null default 'friends'
  check (rankings in ('private', 'friends', 'public'));

-- share_of builds the row by position: rankings goes after listed. Restricted accounts share nothing.
create or replace function t1_private.share_of(p_owner uuid)
returns public.share_settings language sql stable security definer set search_path = '' as $$
  select case when t1_private.is_restricted(p_owner) then
      row(p_owner, 'private', 'private', null, null, null, null, null, null, 'private', now(), 'private', 'private', 'private')::public.share_settings
    else coalesce(
      (select s from public.share_settings s where s.user_id = p_owner),
      row(p_owner, 'friends', 'private', null, null, null, null, null, null, 'private', now(), 'friends', 'friends', 'friends')::public.share_settings) end;
$$;

-- ==================================================================== b_seen
-- A ranking the viewer may see: their own; a cube's when shared with the cube's audience (as before); a set's when
-- shared and the viewer is the maker's friend (as before) or the maker's Rankings part reaches them. Always by a live,
-- unrestricted account across no block.
create or replace function t1_private.ranking_seen(r public.cube_rankings, p_viewer uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_viewer is not null and (r.user_id = p_viewer
    or (r.sharing = 'cube' and t1_private.live_account(r.user_id) and not t1_private.is_restricted(r.user_id)
        and case when r.set_key is not null then
                   t1_private.share_level(r.user_id, p_viewer) >= 1
                   or (select t1_private.vis_ok(t1_private.share_level(r.user_id, p_viewer), s.profile, s.rankings)
                         from t1_private.share_of(r.user_id) s)
                 else t1_private.share_level(r.user_id, p_viewer) >= 0 and t1_private.cube_seen(r.list_id, p_viewer) end));
$$;

-- One row of a profile's Rankings section: the ranking as cube_rankings lists it, plus what it ranks.
create or replace function t1_private.profile_ranking_json(r public.cube_rankings, p_viewer uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select t1_private.ranking_json(r, p_viewer) || jsonb_build_object('subject',
    case when r.set_key is not null then
      (select jsonb_build_object('id', j->>'id', 'kind', j->>'kind', 'name', coalesce(j->>'name', r.set_key), 'set', j->>'set')
         from (select coalesce(t1_private.set_subject_json(r.set_key), jsonb_build_object('id', 'set:' || r.set_key, 'kind', 'set', 'set', r.set_key)) j) x)
    else (select jsonb_build_object('id', l.id, 'kind', 'list', 'name', l.name)
            from public.card_lists l where l.id = r.list_id) end);
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
    'friends', s.friends, 'listed', s.listed, 'rankings', s.rankings,
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
                     'friends', 'listed', 'rankings', 'items') then
      raise exception 'Unknown setting: %', v_key using errcode = '22023';
    end if;
    continue when v_key = 'items';
    v_val := p_settings->>v_key;
    if v_val is null and v_key in ('profile', 'library', 'record', 'friends', 'listed', 'rankings') then
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
  if p_settings ? 'rankings' then v_new.rankings := p_settings->>'rankings'; end if;
  if (to_jsonb(v_new) - 'updated_at') is distinct from (to_jsonb(v_old) - 'updated_at') then
    insert into public.share_settings as s (user_id, profile, library, all_cards, for_trade, wants, binders, decks, cubes,
                                            record, friends, listed, rankings)
    values (v_uid, v_new.profile, v_new.library, v_new.all_cards, v_new.for_trade, v_new.wants, v_new.binders,
            v_new.decks, v_new.cubes, v_new.record, v_new.friends, v_new.listed, v_new.rankings)
    on conflict (user_id) do update set
      profile = excluded.profile, library = excluded.library, all_cards = excluded.all_cards,
      for_trade = excluded.for_trade, wants = excluded.wants, binders = excluded.binders, decks = excluded.decks,
      cubes = excluded.cubes, record = excluded.record, friends = excluded.friends, listed = excluded.listed,
      rankings = excluded.rankings,
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
    -- Rankings: the ones shared (not Only me) that the viewer may open, newest first; your own profile lists all of yours.
    if t1_private.vis_ok(v_level, s.profile, s.rankings) then
      v_sections := v_sections || jsonb_build_object('rankings', coalesce((
        select jsonb_agg(t1_private.profile_ranking_json(r, v_uid) order by r.updated_at desc, r.id)
          from (select r.* from public.cube_rankings r
                 where r.user_id = p_user_id and (r.user_id = v_uid or r.sharing = 'cube')
                   and t1_private.ranking_seen(r, v_uid)
                 order by r.updated_at desc, r.id limit 50) r), '[]'::jsonb));
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

-- ==================================================================== e_grants
revoke execute on function t1_private.share_of(uuid) from public, anon, authenticated;
revoke execute on function t1_private.ranking_seen(public.cube_rankings, uuid) from public, anon, authenticated;
revoke execute on function t1_private.profile_ranking_json(public.cube_rankings, uuid) from public, anon, authenticated;
revoke execute on function public.profile_view(uuid) from public, anon;
grant execute on function public.profile_view(uuid) to authenticated;
revoke execute on function public.sharing_get() from public, anon;
grant execute on function public.sharing_get() to authenticated;
revoke execute on function public.sharing_set(jsonb) from public, anon;
grant execute on function public.sharing_set(jsonb) to authenticated;
