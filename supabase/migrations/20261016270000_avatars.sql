-- Avatars (contract/avatars-2026-10-16.md).
-- Default is drawn by the client: initials on a muted tile picked from the account id. A photo replaces it.
-- Photos live in the public `avatars` bucket at <user_id>/<random>.jpg; profiles.avatar_url holds that path
-- (a new name per upload, so caches never show a stale photo). Profiles are already world-readable, and so
-- are their photos.

-- Provider pictures (Google) are not used: the default is initials until the player picks a photo.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_name text := coalesce(
    nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
    nullif(trim(new.raw_user_meta_data->>'name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'Player');
begin
  insert into public.profiles (id, display_name)
  values (new.id, left(v_name, 40))
  on conflict (id) do nothing;
  return new;
end $$;

update public.profiles set avatar_url = null
 where avatar_url is not null and avatar_url !~ ('^' || id::text || '/[A-Za-z0-9-]{1,64}\.jpg$');

alter table public.profiles drop constraint if exists profiles_avatar_path;
alter table public.profiles add constraint profiles_avatar_path
  check (avatar_url is null or avatar_url ~ ('^' || id::text || '/[A-Za-z0-9-]{1,64}\.jpg$'));

-- Only the RPCs below set it.
revoke update on public.profiles from anon, authenticated;
grant update (handle, display_name) on public.profiles to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg'])
on conflict (id) do nothing;

-- Writes only in your own folder. Reads go through the public URL, so no select policy beyond your own
-- (upsert and remove need to see the row).
drop policy if exists avatars_insert on storage.objects;
create policy avatars_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists avatars_read_own on storage.objects;
create policy avatars_read_own on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and owner_id = (select auth.uid())::text);
drop policy if exists avatars_update on storage.objects;
create policy avatars_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and owner_id = (select auth.uid())::text);
drop policy if exists avatars_delete on storage.objects;
create policy avatars_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and owner_id = (select auth.uid())::text);

-- After the upload. Returns the old path so the client can remove that file.
create or replace function public.avatar_set(p_path text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_old text;
begin
  if v_uid is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  if p_path is null or p_path !~ ('^' || v_uid::text || '/[A-Za-z0-9-]{1,64}\.jpg$') then
    raise exception 'Not your photo' using errcode = '42501';
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'avatars' and o.name = p_path) then
    raise exception 'Upload the photo first' using errcode = '22023';
  end if;
  select avatar_url into v_old from public.profiles where id = v_uid;
  update public.profiles set avatar_url = p_path, updated_at = now() where id = v_uid;
  return jsonb_build_object('avatar_url', p_path, 'previous', v_old);
end $$;

create or replace function public.avatar_clear()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_old text;
begin
  if v_uid is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  select avatar_url into v_old from public.profiles where id = v_uid;
  update public.profiles set avatar_url = null, updated_at = now() where id = v_uid;
  return jsonb_build_object('avatar_url', null, 'previous', v_old);
end $$;

revoke execute on function public.avatar_set(text) from public, anon;
revoke execute on function public.avatar_clear() from public, anon;
grant execute on function public.avatar_set(text) to authenticated;
grant execute on function public.avatar_clear() to authenticated;
