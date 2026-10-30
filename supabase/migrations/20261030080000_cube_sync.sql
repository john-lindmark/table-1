-- Sync a cube with Cube Cobra (John, 2026-10-30; contract/cube-sync-2026-10-30.md).
-- A cube imported from Cube Cobra remembers the link it came from (card_lists.source_url), and Sync with Cube Cobra
-- reads the cube there again (list-import, unchanged), shows what's in, out and in a new printing or finish, and on
-- Accept writes the whole synced cube as one new version noted "Synced with Cube Cobra".
--  - list_json answers carry source_url (null when unknown); older clients ignore it.
--  - list_source_set(p_list_id, p_source_url) remembers (or, with null/blank, forgets) the link; clients call it
--    right after an import from Cube Cobra.
--  - list_sync(p_list_id, p_seq, p_entries, p_source_url, p_note) replaces the current contents with p_entries as a
--    new version (never extending an open one) and remembers the link. p_seq is the list's seq the client compared
--    against: if the list changed since (another device, a rename), nothing is written and it raises PT409 so the
--    client checks again. list_write does the usual cleaning (finish fallback, a foreign printing's language, limits).
-- Replaces t1_private.list_json (as of 20261016220000_roto.sql, checked identical to live 2026-10-30); adds a column
-- and two functions.

alter table public.card_lists add column if not exists source_url text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'card_lists_source_url_shape') then
    alter table public.card_lists add constraint card_lists_source_url_shape
      check (source_url is null or (char_length(source_url) <= 300 and source_url ~ '^https://'));
  end if;
end $$;

create or replace function t1_private.list_json(p_list_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', l.id, 'kind', l.kind, 'name', l.name, 'format', l.format, 'seq', l.seq,
    'current_version', l.current_version, 'deleted', l.deleted_at is not null,
    'event_id', l.event_id, 'event_name', e.name, 'source_url', l.source_url,
    'versions', coalesce((select jsonb_agg(jsonb_build_object('version', v.version, 'note', v.note,
                                   'at', extract(epoch from v.edited_at), 'entries', v.entries) order by v.version)
                            from public.card_list_versions v where v.list_id = l.id), '[]'::jsonb))
  from public.card_lists l left join public.events e on e.id = l.event_id where l.id = p_list_id;
$$;

create or replace function t1_private.list_source_check(p_source_url text)
returns text language plpgsql immutable set search_path = '' as $$
declare v text := nullif(trim(coalesce(p_source_url, '')), '');
begin
  if v is not null and (char_length(v) > 300 or v !~ '^https://') then
    raise exception 'Not a link: %', left(v, 60) using errcode = '22023';
  end if;
  return v;
end $$;

create or replace function public.list_source_set(p_list_id uuid, p_source_url text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_list public.card_lists := t1_private.list_lock(auth.uid(), p_list_id);
  v_url text := t1_private.list_source_check(p_source_url);
begin
  if v_url is distinct from v_list.source_url then
    update public.card_lists set source_url = v_url, seq = nextval('public.card_list_seq'), updated_at = now()
     where id = v_list.id;
  end if;
  return t1_private.list_json(p_list_id);
end $$;

create or replace function public.list_sync(
  p_list_id uuid, p_seq bigint, p_entries jsonb, p_source_url text default null, p_note text default 'Synced with Cube Cobra')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_list public.card_lists := t1_private.list_lock(auth.uid(), p_list_id);
  v_url text := t1_private.list_source_check(p_source_url);
begin
  if p_entries is null or jsonb_typeof(p_entries) <> 'array' then
    raise exception 'Nothing to sync' using errcode = '22023';
  end if;
  if p_seq is distinct from v_list.seq then
    raise exception 'This list changed since you checked. Check again.' using errcode = 'PT409';
  end if;
  perform t1_private.list_write(v_list, p_entries, coalesce(nullif(trim(p_note), ''), 'Synced with Cube Cobra'), false);
  -- A sync is its own version: the next edit starts another.
  update public.card_list_versions set open_until = null where list_id = p_list_id and open_until is not null;
  if v_url is not null then
    update public.card_lists set source_url = v_url where id = v_list.id;
  end if;
  return t1_private.list_json(p_list_id);
end $$;

do $$
declare f text;
begin
  foreach f in array array['list_source_set(uuid, text)', 'list_sync(uuid, bigint, jsonb, text, text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
revoke execute on function t1_private.list_source_check(text) from public, anon, authenticated;
