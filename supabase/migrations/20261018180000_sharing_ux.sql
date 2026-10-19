-- Sharing UX (contract/friends-sharing-2026-10-18.md § UX rules): reporting an account, and new decks that start
-- private on their own setting so a brew never follows an open Decks default. Reports keep a snapshot of what was
-- reported (name, handle, photo, the named binder/deck/cube) so a later rename doesn't erase the evidence; they're
-- read in Supabase only (RLS on, no policy). Deleting your account clears your id from reports you made.

-- ==================================================================== a_reports
create table if not exists public.user_reports (
  id bigint generated always as identity primary key,
  reporter uuid,
  reported uuid not null,
  reason text not null check (reason in ('spam', 'harassment', 'offensive_profile', 'offensive_content', 'other')),
  note text check (length(note) <= 500),
  context jsonb not null default '{}'::jsonb,
  snapshot jsonb not null default '{}'::jsonb,
  status text not null default 'open' check (status in ('open', 'actioned', 'dismissed')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create index if not exists user_reports_open_idx on public.user_reports (created_at) where status = 'open';
create index if not exists user_reports_reported_idx on public.user_reports (reported, created_at desc);
create index if not exists user_reports_reporter_idx on public.user_reports (reporter, created_at desc) where reporter is not null;
alter table public.user_reports enable row level security;
revoke all on public.user_reports from anon, authenticated;

create or replace function public.user_report(
  p_user_id uuid, p_reason text, p_note text default null, p_context jsonb default null, p_block boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_ctx jsonb := coalesce(p_context, '{}'::jsonb);
  v_from text := v_ctx->>'from';
  v_kind text := v_ctx->>'kind';
  v_item uuid;
  v_snap jsonb;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_user_id is null or p_user_id = v_uid then raise exception 'You can''t report yourself' using errcode = '22023'; end if;
  if not t1_private.live_account(p_user_id) then
    raise exception 'That account isn''t on Table 1' using errcode = 'P0002';
  end if;
  if p_reason is null or p_reason not in ('spam', 'harassment', 'offensive_profile', 'offensive_content', 'other') then
    raise exception 'Pick a reason' using errcode = '22023';
  end if;
  if length(v_note) > 500 then raise exception 'Keep the note under 500 characters' using errcode = '22023'; end if;
  if jsonb_typeof(v_ctx) <> 'object'
     or (v_from is not null and v_from not in ('profile', 'friends', 'request', 'search', 'trade_match'))
     or (v_kind is not null and v_kind not in ('binder', 'deck', 'cube')) then
    raise exception 'Unknown report context' using errcode = '22023';
  end if;
  if v_kind is not null then
    begin
      v_item := (v_ctx->>'id')::uuid;
    exception when others then
      raise exception 'Unknown report context' using errcode = '22023';
    end;
  end if;
  perform t1_private.account_rate_limit(v_uid, 'user.reported', 20, interval '1 day');

  select jsonb_build_object('display_name', pr.display_name, 'handle', pr.handle, 'avatar_url', pr.avatar_url)
    into v_snap from public.profiles pr where pr.id = p_user_id;
  -- The named item, only when it's theirs (a wrong id is kept out of the snapshot, not an error).
  if v_kind = 'binder' then
    v_snap := v_snap || coalesce((select jsonb_build_object('item_name', b.name) from public.binders b
                                   where b.id = v_item and b.user_id = p_user_id), '{}'::jsonb);
  elsif v_kind in ('deck', 'cube') then
    v_snap := v_snap || coalesce((select jsonb_build_object('item_name', l.name) from public.card_lists l
                                   where l.id = v_item and l.user_id = p_user_id and l.kind = v_kind), '{}'::jsonb);
  end if;

  insert into public.user_reports (reporter, reported, reason, note, context, snapshot)
  values (v_uid, p_user_id, p_reason, v_note,
          jsonb_strip_nulls(jsonb_build_object('from', v_from, 'kind', v_kind, 'id', v_item)), v_snap);
  perform t1_private.account_audit(v_uid, 'user.reported', p_user_id, null, jsonb_build_object('reason', p_reason));
  if coalesce(p_block, false) then
    perform public.user_block(p_user_id, true);
  end if;
  return jsonb_build_object('ok', true, 'blocked', coalesce(p_block, false));
end $$;

-- delete_account marks the profile deleted; this clears the reporter on their reports without redefining it.
create or replace function t1_private.reports_forget_reporter()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.user_reports set reporter = null where reporter = new.id;
  return null;
end $$;

drop trigger if exists profiles_reports_forget on public.profiles;
create trigger profiles_reports_forget after update of deleted_at on public.profiles
  for each row when (old.deleted_at is null and new.deleted_at is not null)
  execute function t1_private.reports_forget_reporter();

-- ==================================================================== b_new_decks_private
-- A new deck gets its own `private` setting instead of "Same as Decks". Cubes keep following their group.
create or replace function t1_private.card_lists_new_deck_private()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.kind = 'deck' and new.visibility is null then new.visibility := 'private'; end if;
  return new;
end $$;

drop trigger if exists card_lists_new_deck_private on public.card_lists;
create trigger card_lists_new_deck_private before insert on public.card_lists
  for each row execute function t1_private.card_lists_new_deck_private();

-- ==================================================================== c_grants
revoke execute on function t1_private.reports_forget_reporter() from public;
revoke execute on function t1_private.card_lists_new_deck_private() from public;
revoke execute on function public.user_report(uuid, text, text, jsonb, boolean) from public, anon;
grant execute on function public.user_report(uuid, text, text, jsonb, boolean) to authenticated;
