-- L3 decks and cubes (plan-collection-2026-10-14.md §6, "L3 status").
-- A list is a series of versions; its contents are the newest. card_list_versions is append-only history
-- (a JSON snapshot per version); card_list_entries materializes the current version for queries ("which of my
-- decks use this card?"). Every write goes through these RPCs, serialized per user on library_summary (the
-- same lock collection_apply takes), so versions and the sync cursor stay in order across devices.
--  - Sections (board): main, side (decks only), maybe ("Considering"), commander (decks only).
--  - Edits within 10 minutes of the previous edit extend that version instead of starting a new one, so a run
--    of +1s is one entry in the history. Restoring appends a copy of an old version; nothing is rewritten.
--  - Clients sync with lists_changes(after seq), like collection_changes.

create sequence if not exists public.card_list_seq;

create table if not exists public.card_lists (
  id uuid primary key,                         -- client-generated, so creating is idempotent and works offline-first
  user_id uuid not null,
  kind text not null check (kind in ('deck', 'cube')),
  name text not null check (char_length(name) between 1 and 60),
  format text not null check (char_length(format) between 1 and 30),
  current_version integer not null default 1,
  seq bigint not null,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists card_lists_user_seq_idx on public.card_lists (user_id, seq);

create table if not exists public.card_list_versions (
  list_id uuid not null references public.card_lists(id) on delete cascade,
  version integer not null,
  note text not null,
  entries jsonb not null,                      -- [[card_id, board, qty], ...]
  created_at timestamptz not null default now(),
  edited_at timestamptz not null default now(),
  open_until timestamptz,                      -- set while later edits may still extend this version
  primary key (list_id, version)
);

create table if not exists public.card_list_entries (
  list_id uuid not null references public.card_lists(id) on delete cascade,
  card_id uuid not null references public.cards(id),
  board text not null check (board in ('main', 'side', 'maybe', 'commander')),
  qty integer not null check (qty between 1 and 999),
  primary key (list_id, board, card_id)
);
create index if not exists card_list_entries_card_idx on public.card_list_entries (card_id);

alter table public.card_lists enable row level security;
alter table public.card_list_versions enable row level security;
alter table public.card_list_entries enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'card_lists' and policyname = 'card_lists_own_read') then
    create policy card_lists_own_read on public.card_lists for select to authenticated using (user_id = (select auth.uid()));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'card_list_versions' and policyname = 'card_list_versions_own_read') then
    create policy card_list_versions_own_read on public.card_list_versions for select to authenticated
      using (exists (select 1 from public.card_lists l where l.id = list_id and l.user_id = (select auth.uid())));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'card_list_entries' and policyname = 'card_list_entries_own_read') then
    create policy card_list_entries_own_read on public.card_list_entries for select to authenticated
      using (exists (select 1 from public.card_lists l where l.id = list_id and l.user_id = (select auth.uid())));
  end if;
end $$;

-- ==================================================================== helpers
-- One list as the clients see it: header plus every version (oldest first) with its entries.
create or replace function t1_private.list_json(p_list_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', l.id, 'kind', l.kind, 'name', l.name, 'format', l.format, 'seq', l.seq,
    'current_version', l.current_version, 'deleted', l.deleted_at is not null,
    'versions', coalesce((select jsonb_agg(jsonb_build_object('version', v.version, 'note', v.note,
                                   'at', extract(epoch from v.edited_at), 'entries', v.entries) order by v.version)
                            from public.card_list_versions v where v.list_id = l.id), '[]'::jsonb))
  from public.card_lists l where l.id = p_list_id;
$$;

-- Locks the caller's library (shared with collection_apply) and returns the list if it's theirs and live.
create or replace function t1_private.list_lock(p_uid uuid, p_list_id uuid)
returns public.card_lists language plpgsql security definer set search_path = '' as $$
declare v_list public.card_lists;
begin
  if p_uid is null then raise exception 'Sign in to change your decks and cubes' using errcode = '28000'; end if;
  insert into public.library_summary (user_id) values (p_uid) on conflict do nothing;
  perform 1 from public.library_summary where user_id = p_uid for update;
  select * into v_list from public.card_lists where id = p_list_id and user_id = p_uid and deleted_at is null;
  if v_list.id is null then raise exception 'That list isn''t here anymore' using errcode = 'P0002'; end if;
  return v_list;
end $$;

-- Validates entries and writes them as the list's current contents (version row + materialized entries).
-- p_extend: overwrite the open version instead of appending one.
create or replace function t1_private.list_write(
  p_list public.card_lists, p_entries jsonb, p_note text, p_extend boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_bad text;
  v_version integer;
  v_clean jsonb;
begin
  -- Merge duplicate lines, drop zero/negative, validate boards, cards and size.
  with rows as (
    select (e->>0)::uuid card_id, e->>1 board, (e->>2)::int qty from jsonb_array_elements(p_entries) e
  ), merged as (
    select card_id, board, sum(qty)::int qty from rows group by 1, 2 having sum(qty) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_array(card_id, board, qty) order by board, card_id), '[]'::jsonb) into v_clean from merged;

  if jsonb_array_length(v_clean) > 1000 then raise exception 'A list holds at most 1000 different cards' using errcode = '22023'; end if;
  select string_agg(distinct e->>1, ', ') into v_bad from jsonb_array_elements(v_clean) e
   where e->>1 not in ('main', 'maybe') and not (p_list.kind = 'deck' and e->>1 in ('side', 'commander'));
  if v_bad is not null then raise exception 'Not a section of a %: %', p_list.kind, v_bad using errcode = '22023'; end if;
  if exists (select 1 from jsonb_array_elements(v_clean) e where (e->>2)::int > 999) then
    raise exception 'At most 999 copies of a card in one section' using errcode = '22023';
  end if;
  select string_agg(e->>0, ', ') into v_bad from (select e from jsonb_array_elements(v_clean) e
    where not exists (select 1 from public.cards c where c.id = (e->>0)::uuid) limit 3) x;
  if v_bad is not null then raise exception 'Unknown card: %', v_bad using errcode = '22023'; end if;

  if p_extend then
    update public.card_list_versions set entries = v_clean, edited_at = now(), open_until = now() + interval '10 minutes'
     where list_id = p_list.id and version = p_list.current_version;
    v_version := p_list.current_version;
  else
    update public.card_list_versions set open_until = null where list_id = p_list.id and open_until is not null;
    v_version := coalesce((select max(version) from public.card_list_versions where list_id = p_list.id), 0) + 1;
    insert into public.card_list_versions (list_id, version, note, entries, open_until)
    values (p_list.id, v_version, left(coalesce(nullif(trim(p_note), ''), 'Edited'), 80), v_clean,
            case when p_note = 'Edited' then now() + interval '10 minutes' end);
  end if;

  delete from public.card_list_entries where list_id = p_list.id;
  insert into public.card_list_entries (list_id, card_id, board, qty)
  select p_list.id, (e->>0)::uuid, e->>1, (e->>2)::int from jsonb_array_elements(v_clean) e;
  update public.card_lists set current_version = v_version, seq = nextval('public.card_list_seq'), updated_at = now()
   where id = p_list.id;
end $$;

-- ==================================================================== client RPCs
-- Creates a list (id chosen by the client; calling again with the same id returns the existing list).
-- p_entries: optional starting cards ([[card_id, board, qty]]), e.g. from an import.
create or replace function public.list_create(
  p_id uuid, p_kind text, p_name text, p_format text, p_entries jsonb default '[]'::jsonb, p_note text default 'Created')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_list public.card_lists;
begin
  if v_uid is null then raise exception 'Sign in to save decks and cubes' using errcode = '28000'; end if;
  if p_kind not in ('deck', 'cube') then raise exception 'A list is a deck or a cube' using errcode = '22023'; end if;
  insert into public.library_summary (user_id) values (v_uid) on conflict do nothing;
  perform 1 from public.library_summary where user_id = v_uid for update;
  select * into v_list from public.card_lists where id = p_id;
  if v_list.id is not null then
    if v_list.user_id <> v_uid then raise exception 'List id already used' using errcode = '23505'; end if;
    return t1_private.list_json(p_id);
  end if;
  if (select count(*) from public.card_lists where user_id = v_uid and deleted_at is null) >= 500 then
    raise exception 'At most 500 decks and cubes' using errcode = '22023';
  end if;
  insert into public.card_lists (id, user_id, kind, name, format, current_version, seq)
  values (p_id, v_uid, p_kind, left(trim(p_name), 60), left(lower(trim(p_format)), 30), 0, nextval('public.card_list_seq'))
  returning * into v_list;
  perform t1_private.list_write(v_list, coalesce(p_entries, '[]'::jsonb), coalesce(p_note, 'Created'), false);
  -- The first version is never extended by later edits.
  update public.card_list_versions set open_until = null where list_id = p_id;
  return t1_private.list_json(p_id);
end $$;

-- Applies edits to the current contents. p_ops: [{card_id, board, delta} | {card_id, board, qty} |
-- {card_id, from, to}] (move every copy of a line to another section). Edits within 10 minutes of the last
-- edit extend that version.
create or replace function public.list_edit(p_list_id uuid, p_ops jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_list public.card_lists := t1_private.list_lock(auth.uid(), p_list_id);
  v_cur public.card_list_versions;
  v_entries jsonb;
  v_op jsonb;
  v_key text;
  v_map jsonb := '{}'::jsonb;
  v_q integer;
begin
  if p_ops is null or jsonb_typeof(p_ops) <> 'array' or jsonb_array_length(p_ops) = 0 then
    raise exception 'Nothing to change' using errcode = '22023';
  end if;
  if jsonb_array_length(p_ops) > 2000 then raise exception 'At most 2000 changes at once' using errcode = '22023'; end if;
  select * into v_cur from public.card_list_versions where list_id = p_list_id and version = v_list.current_version;
  -- Work on a {"card|board": qty} map.
  select coalesce(jsonb_object_agg((e->>0) || '|' || (e->>1), (e->>2)::int), '{}'::jsonb) into v_map
    from jsonb_array_elements(v_cur.entries) e;
  for v_op in select * from jsonb_array_elements(p_ops) loop
    if v_op ? 'from' then
      v_key := (v_op->>'card_id') || '|' || (v_op->>'from');
      v_q := coalesce((v_map->>v_key)::int, 0);
      if v_q > 0 then
        v_map := v_map - v_key;
        v_key := (v_op->>'card_id') || '|' || (v_op->>'to');
        v_map := jsonb_set(v_map, array[v_key], to_jsonb(coalesce((v_map->>v_key)::int, 0) + v_q));
      end if;
    else
      v_key := (v_op->>'card_id') || '|' || coalesce(v_op->>'board', 'main');
      v_q := case when v_op ? 'qty' then (v_op->>'qty')::int
                  else coalesce((v_map->>v_key)::int, 0) + coalesce((v_op->>'delta')::int, 0) end;
      v_map := case when v_q > 0 then jsonb_set(v_map, array[v_key], to_jsonb(v_q)) else v_map - v_key end;
    end if;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_array(split_part(k, '|', 1), split_part(k, '|', 2), v::int)), '[]'::jsonb)
    into v_entries from jsonb_each_text(v_map) as m(k, v);
  perform t1_private.list_write(v_list, v_entries, 'Edited', v_cur.open_until is not null and v_cur.open_until > now());
  return t1_private.list_json(p_list_id);
end $$;

-- Makes an old version current by appending a copy of it ("Restored vN").
create or replace function public.list_restore(p_list_id uuid, p_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_list public.card_lists := t1_private.list_lock(auth.uid(), p_list_id);
  v_old public.card_list_versions;
begin
  select * into v_old from public.card_list_versions where list_id = p_list_id and version = p_version;
  if v_old.list_id is null then raise exception 'No version %', p_version using errcode = 'P0002'; end if;
  if p_version = v_list.current_version then return t1_private.list_json(p_list_id); end if;
  perform t1_private.list_write(v_list, v_old.entries, 'Restored v' || p_version, false);
  return t1_private.list_json(p_list_id);
end $$;

create or replace function public.list_update(p_list_id uuid, p_name text default null, p_format text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_list public.card_lists := t1_private.list_lock(auth.uid(), p_list_id);
begin
  update public.card_lists
     set name = coalesce(left(nullif(trim(p_name), ''), 60), name),
         format = coalesce(left(lower(nullif(trim(p_format), '')), 30), format),
         seq = nextval('public.card_list_seq'), updated_at = now()
   where id = v_list.id;
  return t1_private.list_json(p_list_id);
end $$;

-- Deletes a list for all devices (kept as a tombstone so other devices learn about it on sync).
create or replace function public.list_delete(p_list_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_list public.card_lists := t1_private.list_lock(auth.uid(), p_list_id);
begin
  update public.card_lists set deleted_at = now(), seq = nextval('public.card_list_seq'), updated_at = now()
   where id = v_list.id;
  delete from public.card_list_entries where list_id = v_list.id;
  return jsonb_build_object('id', v_list.id, 'deleted', true);
end $$;

-- Delta sync: lists changed after `p_after` (a seq the client holds), oldest first, each with its full
-- version history. Deleted lists come through as {id, deleted: true}.
create or replace function public.lists_changes(p_after bigint default 0, p_limit integer default 100)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_lim integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_out jsonb;
  v_n integer;
  v_last bigint;
begin
  if v_uid is null then raise exception 'Sign in to see your decks and cubes' using errcode = '28000'; end if;
  select coalesce(jsonb_agg(case when l.deleted_at is not null
                                 then jsonb_build_object('id', l.id, 'deleted', true, 'seq', l.seq)
                                 else t1_private.list_json(l.id) end order by l.seq), '[]'::jsonb),
         count(*), max(l.seq)
    into v_out, v_n, v_last
    from (select * from public.card_lists where user_id = v_uid and seq > coalesce(p_after, 0)
           order by seq limit v_lim) l;
  return jsonb_build_object('lists', v_out, 'next', coalesce(v_last, coalesce(p_after, 0)), 'more', v_n = v_lim);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'list_create(uuid, text, text, text, jsonb, text)', 'list_edit(uuid, jsonb)', 'list_restore(uuid, integer)',
    'list_update(uuid, text, text)', 'list_delete(uuid)', 'lists_changes(bigint, integer)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ==================================================================== account deletion
create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  perform public.demo_remove();
  update public.profiles
     set handle = null, display_name = 'Deleted player', avatar_url = null,
         deleted_at = now(), updated_at = now()
   where id = v_uid;
  update public.participants set display_name = 'Deleted player' where user_id = v_uid;
  delete from public.devices where user_id = v_uid;
  delete from public.notification_prefs where user_id = v_uid;
  delete from public.presence_cells where user_id = v_uid;
  delete from public.event_invites where user_id = v_uid and status = 'pending';
  delete from public.collection_ledger where user_id = v_uid;
  delete from public.collection_batches where user_id = v_uid;
  delete from public.collection_items where user_id = v_uid;
  delete from public.card_lists where user_id = v_uid;   -- versions and entries cascade
  delete from public.library_summary where user_id = v_uid;
end $$;
revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
