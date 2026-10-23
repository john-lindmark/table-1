-- Share links (contract/share-links-2026-10-23.md): "Anyone with the link" as a per-item audience next to
-- Private / Friends / Anyone. The owner makes a link for one part of their Library (All cards, For trade, Wants, a
-- binder, a deck or a cube); anyone holding it sees that part and nothing else, signed out too, whatever the profile
-- and the part's own setting say. Settings stay the rule for everyone else. One live link per part; a new link
-- retires the old one; Stop sharing retires it. Blocks still win for signed-in viewers. Names that reach link viewers
-- are moderated like anything else others can see, and a name moderation unshared doesn't show through a link.

-- ==================================================================== a_table
create table if not exists public.share_links (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  part text not null check (part in ('all_cards', 'for_trade', 'wants', 'binder', 'deck', 'cube')),
  item_id uuid,                                 -- the binder / deck / cube; null for the three parts
  token text not null unique,                   -- 22 characters, 128 random bits
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  check ((part in ('binder', 'deck', 'cube')) = (item_id is not null))
);
create unique index if not exists share_links_live_idx on public.share_links
  (user_id, part, coalesce(item_id, '00000000-0000-0000-0000-000000000000'::uuid)) where revoked_at is null;
create index if not exists share_links_item_idx on public.share_links (item_id) where revoked_at is null and item_id is not null;
alter table public.share_links enable row level security;
-- No policy: read and written only through the RPCs below.
revoke all on public.share_links from anon, authenticated;

-- ==================================================================== b_helpers
-- The name of a part you own, or null when it isn't yours (or is gone). The three parts are always yours.
create or replace function t1_private.share_part_name(p_uid uuid, p_part text, p_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when p_part in ('all_cards', 'for_trade', 'wants') then p_part
    when p_part = 'binder' then (select b.name from public.binders b where b.id = p_id and b.user_id = p_uid and b.deleted_at is null)
    when p_part in ('deck', 'cube') then (select l.name from public.card_lists l
                                           where l.id = p_id and l.user_id = p_uid and l.kind = p_part and l.deleted_at is null)
  end;
$$;

create or replace function t1_private.share_token()
returns text language sql volatile set search_path = '' as $$
  select translate(rtrim(encode(extensions.gen_random_bytes(16), 'base64'), '='), '+/', '-_');
$$;

-- A live link anyone may open: the owner is a live account, the part is still there, and its name isn't one
-- moderation unshared (that action stands until it's reverted or the item is renamed). A block either way hides it
-- from a signed-in viewer. Everything that doesn't open reads the same.
create or replace function t1_private.share_link_open(p_token text)
returns public.share_links language plpgsql stable security definer set search_path = '' as $$
declare
  k public.share_links;
  v_uid uuid := auth.uid();
  v_name text;
begin
  select * into k from public.share_links where token = p_token and revoked_at is null;
  if k.id is null
     or not exists (select 1 from public.profiles pr where pr.id = k.user_id and pr.deleted_at is null
                     and (not pr.is_demo or pr.id = v_uid))
     or (v_uid is not null and t1_private.share_level(k.user_id, v_uid) < 0) then
    raise exception 'This isn''t available' using errcode = '42501';
  end if;
  v_name := t1_private.share_part_name(k.user_id, k.part, k.item_id);
  if v_name is null or (k.item_id is not null and exists (
      select 1 from public.moderation_actions a join public.moderation_checks c on c.id = a.check_id
       where a.subject_id = k.item_id and a.action = 'unshare' and a.reverted_at is null and c.content = v_name)) then
    raise exception 'This isn''t available' using errcode = '42501';
  end if;
  return k;
end $$;

-- Moderation: a binder, deck or cube with a live link reaches someone besides its owner.
create or replace function t1_private.item_visible(p_kind text, p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select case
    when p_kind = 'binder' then exists (
      select 1 from public.binders b, t1_private.share_of(b.user_id) s
       where b.id = p_id and b.deleted_at is null
         and t1_private.vis_ok(1, s.profile, coalesce(b.visibility, s.binders, s.library)))
    else exists (
      select 1 from public.card_lists l, t1_private.share_of(l.user_id) s
       where l.id = p_id and l.deleted_at is null
         and t1_private.vis_ok(1, s.profile, coalesce(l.visibility, case l.kind when 'cube' then s.cubes else s.decks end, s.library)))
  end
  or exists (select 1 from public.share_links k where k.item_id = p_id and k.revoked_at is null);
$$;

-- A new link puts the item's name in front of strangers: check it (the rename trigger covers later names).
create or replace function t1_private.mod_share_links_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.item_id is not null and new.revoked_at is null then
    perform t1_private.moderation_enqueue(case when new.part = 'binder' then 'binder_name' else 'list_name' end,
                                          new.item_id, new.user_id, t1_private.share_part_name(new.user_id, new.part, new.item_id), null);
  end if;
  return null;
end $$;
drop trigger if exists share_links_moderation on public.share_links;
create trigger share_links_moderation after insert on public.share_links
  for each row execute function t1_private.mod_share_links_trg();

-- Deleting your account removes your links (delete_account marks the profile deleted; no need to redefine it).
create or replace function t1_private.share_links_forget()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.share_links where user_id = new.id;
  return null;
end $$;
drop trigger if exists profiles_share_links_forget on public.profiles;
create trigger profiles_share_links_forget after update of deleted_at on public.profiles
  for each row when (old.deleted_at is null and new.deleted_at is not null)
  execute function t1_private.share_links_forget();

-- ==================================================================== c_owner
create or replace function t1_private.share_link_json(k public.share_links)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('part', k.part, 'id', k.item_id, 'token', k.token, 'created_at', k.created_at);
$$;

-- Your live link for a part, made if there isn't one. `p_new` retires the old link first (anyone holding it loses it).
create or replace function public.share_link_create(p_part text, p_id uuid default null, p_new boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  k public.share_links;
  v_old text;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_part is null or p_part not in ('all_cards', 'for_trade', 'wants', 'binder', 'deck', 'cube')
     or ((p_part in ('binder', 'deck', 'cube')) <> (p_id is not null)) then
    raise exception 'A link is for All cards, For trade, Wants, or one binder, deck or cube' using errcode = '22023';
  end if;
  if t1_private.share_part_name(v_uid, p_part, p_id) is null then
    raise exception 'That isn''t yours' using errcode = '42501';
  end if;
  -- One at a time per account, so two taps can't make two live links.
  perform pg_advisory_xact_lock(hashtextextended('share_link:' || v_uid::text, 0));
  select * into k from public.share_links
   where user_id = v_uid and part = p_part and item_id is not distinct from p_id and revoked_at is null;
  if k.id is not null and not coalesce(p_new, false) then return t1_private.share_link_json(k); end if;
  perform t1_private.account_rate_limit(v_uid, 'sharing.link', 50, interval '1 day');
  if k.id is not null then
    update public.share_links set revoked_at = now() where id = k.id;
    v_old := k.token;
  end if;
  insert into public.share_links (user_id, part, item_id, token)
  values (v_uid, p_part, p_id, t1_private.share_token())
  returning * into k;
  perform t1_private.account_audit(v_uid, 'sharing.link', null,
    case when v_old is not null then jsonb_build_object('link', true) end,
    jsonb_build_object('part', p_part, 'id', p_id, 'link', true, 'new', v_old is not null));
  return t1_private.share_link_json(k);
end $$;

-- Stop sharing the link: it stops working at once. Nothing live = no change (no audit row).
create or replace function public.share_link_revoke(p_part text, p_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_n integer;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_part is null or p_part not in ('all_cards', 'for_trade', 'wants', 'binder', 'deck', 'cube') then
    raise exception 'A link is for All cards, For trade, Wants, or one binder, deck or cube' using errcode = '22023';
  end if;
  update public.share_links set revoked_at = now()
   where user_id = v_uid and part = p_part and item_id is not distinct from p_id and revoked_at is null;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    perform t1_private.account_audit(v_uid, 'sharing.link', null, jsonb_build_object('link', true),
      jsonb_build_object('part', p_part, 'id', p_id, 'link', false));
  end if;
  return jsonb_build_object('ok', true, 'revoked', v_n > 0);
end $$;

-- sharing_get, plus `links`: your live links (parts that are gone are left out).
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

-- ==================================================================== d_viewer
-- What a link shows, signed out or in: the part, its name, the owner's name and photo, and a card count. Never the
-- owner's id, handle, value or max prices. `mine`: you made it.
create or replace function public.shared_view(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  k public.share_links;
  l public.card_lists;
  v_name text;
  v_cards integer;
  v_for_trade boolean;
begin
  k := t1_private.share_link_open(p_token);
  if k.part = 'all_cards' then
    select coalesce((select ls.total_qty from public.library_summary ls where ls.user_id = k.user_id), 0) into v_cards;
  elsif k.part = 'for_trade' then
    select coalesce(sum(bi.qty), 0) into v_cards from public.binder_items bi join public.binders b on b.id = bi.binder_id
     where b.user_id = k.user_id and b.for_trade and b.deleted_at is null and bi.qty > 0;
  elsif k.part = 'wants' then
    select coalesce(sum(w.qty), 0) into v_cards from public.wants w where w.user_id = k.user_id and w.qty > 0;
  elsif k.part = 'binder' then
    select b.name, b.for_trade into v_name, v_for_trade from public.binders b where b.id = k.item_id;
    select coalesce(sum(bi.qty), 0) into v_cards from public.binder_items bi where bi.binder_id = k.item_id and bi.qty > 0;
  else
    select * into l from public.card_lists where id = k.item_id;
    v_name := l.name;
    select coalesce(sum(e.qty), 0) into v_cards from public.card_list_entries e where e.list_id = k.item_id and e.board <> 'maybe';
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'part', k.part, 'id', k.item_id, 'name', v_name, 'format', l.format, 'for_trade', v_for_trade, 'cards', v_cards,
    'owner', (select jsonb_build_object('display_name', pr.display_name, 'avatar_url', pr.avatar_url)
                from public.profiles pr where pr.id = k.user_id))) || jsonb_build_object('mine', coalesce(k.user_id = auth.uid(), false));
end $$;

-- The cards behind a link, paged by offset, in profile_cards' shapes: all_cards [card, finish, qty]; for_trade and
-- binder [card, finish, condition, lang, qty]; deck / cube [card, board, qty]; wants [oracle, card, finish, qty].
create or replace function public.shared_cards(p_token text, p_after integer default 0, p_limit integer default 5000)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  k public.share_links;
  v_off integer := greatest(coalesce(p_after, 0), 0);
  v_lim integer := least(greatest(coalesce(p_limit, 5000), 1), 10000);
  v_rows jsonb;
  v_n integer;
begin
  k := t1_private.share_link_open(p_token);
  if k.part = 'all_cards' then
    select coalesce(jsonb_agg(jsonb_build_array(r.card_id, r.finish, r.qty) order by r.card_id, r.finish), '[]'::jsonb), count(*)
      into v_rows, v_n
      from (select i.card_id, i.finish, sum(i.qty)::int qty from public.collection_items i
             where i.user_id = k.user_id and i.qty > 0 group by 1, 2 order by 1, 2 offset v_off limit v_lim) r;
  elsif k.part in ('for_trade', 'binder') then
    select coalesce(jsonb_agg(jsonb_build_array(r.card_id, r.finish, r.condition, r.lang, r.qty)
                              order by r.card_id, r.finish, r.condition, r.lang), '[]'::jsonb), count(*)
      into v_rows, v_n
      from (select bi.card_id, bi.finish, bi.condition, bi.lang, sum(bi.qty)::int qty from public.binder_items bi
             where bi.qty > 0 and case when k.part = 'binder' then bi.binder_id = k.item_id
                                       else bi.binder_id in (select b.id from public.binders b
                                                              where b.user_id = k.user_id and b.for_trade and b.deleted_at is null) end
             group by 1, 2, 3, 4 order by 1, 2, 3, 4 offset v_off limit v_lim) r;
  elsif k.part = 'wants' then
    select coalesce(jsonb_agg(jsonb_build_array(r.oracle_id, r.card_id, r.finish, r.qty) order by r.id), '[]'::jsonb), count(*)
      into v_rows, v_n
      from (select w.id, w.oracle_id, w.card_id, w.finish, w.qty from public.wants w
             where w.user_id = k.user_id and w.qty > 0 order by w.id offset v_off limit v_lim) r;
  else
    select coalesce(jsonb_agg(jsonb_build_array(r.card_id, r.board, r.qty) order by r.board, r.card_id), '[]'::jsonb), count(*)
      into v_rows, v_n
      from (select e.card_id, e.board, e.qty from public.card_list_entries e where e.list_id = k.item_id
             order by e.board, e.card_id offset v_off limit v_lim) r;
  end if;
  return jsonb_build_object('rows', v_rows, 'more', v_n = v_lim);
end $$;

-- ==================================================================== e_grants
revoke execute on function t1_private.share_part_name(uuid, text, uuid) from public;
revoke execute on function t1_private.share_token() from public;
revoke execute on function t1_private.share_link_open(text) from public;
revoke execute on function t1_private.share_link_json(public.share_links) from public;
revoke execute on function t1_private.mod_share_links_trg() from public;
revoke execute on function t1_private.share_links_forget() from public;
revoke execute on function public.share_link_create(text, uuid, boolean) from public, anon;
grant execute on function public.share_link_create(text, uuid, boolean) to authenticated;
revoke execute on function public.share_link_revoke(text, uuid) from public, anon;
grant execute on function public.share_link_revoke(text, uuid) to authenticated;
revoke execute on function public.sharing_get() from public, anon;
grant execute on function public.sharing_get() to authenticated;
revoke execute on function public.shared_view(text) from public;
grant execute on function public.shared_view(text) to anon, authenticated;
revoke execute on function public.shared_cards(text, integer, integer) from public;
grant execute on function public.shared_cards(text, integer, integer) to anon, authenticated;
