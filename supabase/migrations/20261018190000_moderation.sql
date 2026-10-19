-- Moderation (contract/moderation-2026-10-18.md): content other people can see is checked by the `moderate` edge
-- function (Claude, structured verdict allow / review / block) after it's written; blocks are enforced with the least
-- drastic reversible action and the owner is told, with one appeal per action. Accounts are only restricted by a
-- moderator. Starts in shadow mode: verdicts are recorded and queued, nothing is enforced except child safety.
-- Private content is never checked. Strikes are derived from actions (never stored).

-- ==================================================================== a_tables
create table if not exists public.moderation_checks (
  id bigint generated always as identity primary key,
  subject_kind text not null check (subject_kind in ('display_name', 'handle', 'avatar', 'list_name', 'binder_name',
                                                     'event_name', 'guest_name', 'deck_photo', 'deck_photo_note')),
  subject_id uuid not null,
  owner uuid,
  content text,           -- text subjects; cleared after 180 days
  path text,              -- image subjects: storage path
  content_hash text not null,
  source text not null default 'write' check (source in ('write', 'report', 'sweep')),
  status text not null default 'pending' check (status in ('pending', 'running', 'allow', 'review', 'block')),
  category text,
  reason text,
  model text,
  claimed_at timestamptz,
  attempts integer not null default 0,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  resolved_by uuid,       -- a moderator closed it (allow / block)
  resolved_at timestamptz
);
create index if not exists moderation_checks_pending_idx on public.moderation_checks (created_at) where status in ('pending', 'running');
create index if not exists moderation_checks_subject_idx on public.moderation_checks (subject_kind, subject_id, created_at desc);
create index if not exists moderation_checks_hash_idx on public.moderation_checks (content_hash, decided_at desc) where status in ('allow', 'block');
create index if not exists moderation_checks_queue_idx on public.moderation_checks (created_at) where status in ('review', 'block') and resolved_at is null;
create index if not exists moderation_checks_owner_idx on public.moderation_checks (owner) where owner is not null;

create table if not exists public.moderation_actions (
  id bigint generated always as identity primary key,
  check_id bigint references public.moderation_checks (id) on delete set null,
  owner uuid,
  subject_kind text not null,
  subject_id uuid not null,
  action text not null check (action in ('reset_name', 'clear_handle', 'remove_avatar', 'unshare', 'rename_event',
                                         'rename_guest', 'hide_photo', 'clear_note')),
  category text,
  label text not null,     -- what the owner sees: "Your display name", "Deck Burn"
  before jsonb not null,
  replaced jsonb not null, -- what the action set, so a revert never clobbers a later change
  auto boolean not null default true,
  by_user uuid,
  at timestamptz not null default now(),
  seen_at timestamptz,
  appeal_status text not null default 'none' check (appeal_status in ('none', 'open', 'upheld', 'reverted')),
  appeal_note text check (length(appeal_note) <= 500),
  appealed_at timestamptz,
  appeal_resolved_at timestamptz,
  appeal_resolved_by uuid,
  reverted_at timestamptz
);
create index if not exists moderation_actions_owner_idx on public.moderation_actions (owner, at desc) where owner is not null;
create index if not exists moderation_actions_appeals_idx on public.moderation_actions (appealed_at) where appeal_status = 'open';

create table if not exists public.moderation_restrictions (
  user_id uuid primary key,
  until timestamptz not null,
  reason text not null,
  by_user uuid not null,
  at timestamptz not null default now()
);

-- Reports link to the check they caused (or the one already standing for that content).
alter table public.user_reports add column if not exists check_id bigint references public.moderation_checks (id) on delete set null;
create index if not exists user_reports_check_idx on public.user_reports (check_id) where check_id is not null;

alter table public.event_deck_photos add column if not exists hidden_at timestamptz;

-- Child-safety photos are moved here (private, service role only) and kept for the legal report.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('moderation-quarantine', 'moderation-quarantine', false, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'image/gif'])
on conflict (id) do nothing;

create table if not exists t1_private.moderators (user_id uuid primary key, note text, added_at timestamptz not null default now());
-- One row. mode: shadow (record and queue only) / enforce.
create table if not exists t1_private.moderation_settings (
  id boolean primary key default true check (id),
  mode text not null default 'shadow' check (mode in ('shadow', 'enforce')),
  report_threshold integer not null default 3,
  updated_at timestamptz not null default now()
);
insert into t1_private.moderation_settings (id) values (true) on conflict do nothing;
-- Throttles (e.g. the moderators' review push).
create table if not exists t1_private.moderation_state (key text primary key, at timestamptz not null);

do $$
declare t text;
begin
  foreach t in array array['moderation_checks', 'moderation_actions', 'moderation_restrictions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);   -- RPCs only
  end loop;
end $$;
revoke all on t1_private.moderators, t1_private.moderation_settings, t1_private.moderation_state from anon, authenticated, public;

-- John moderates (lindmarkjohn@gmail.com); more are added the same way.
insert into t1_private.moderators (user_id, note)
select id, 'John' from auth.users where lower(email) = 'lindmarkjohn@gmail.com'
on conflict do nothing;

-- ==================================================================== b_helpers
create or replace function t1_private.is_moderator(p_uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from t1_private.moderators m where m.user_id = p_uid);
$$;

create or replace function t1_private.require_moderator()
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or not t1_private.is_moderator(v_uid) then
    raise exception 'Moderators only' using errcode = '42501';
  end if;
  return v_uid;
end $$;

create or replace function t1_private.moderation_mode()
returns text language sql stable security definer set search_path = '' as $$
  select coalesce((select mode from t1_private.moderation_settings), 'shadow');
$$;

create or replace function t1_private.is_restricted(p_uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.moderation_restrictions r where r.user_id = p_uid and r.until > now());
$$;

-- Plain words for the owner's notice.
create or replace function t1_private.moderation_reason_text(p_category text)
returns text language sql immutable as $$
  select case p_category
    when 'hate' then 'It looks like hate speech.'
    when 'harassment' then 'It looks like it targets or harasses someone.'
    when 'sexual' then 'It looks sexual.'
    when 'child_safety' then 'It breaks our child-safety rules.'
    when 'violence' then 'It looks like a real threat of violence.'
    when 'self_harm' then 'It looks like it encourages self-harm.'
    when 'spam' then 'It looks like spam or advertising.'
    when 'personal_info' then 'It shares personal contact details.'
    when 'impersonation' then 'It looks like it impersonates Table 1 or someone else.'
    else 'It breaks the community rules.' end;
$$;

-- Can someone besides the owner see this deck, cube or binder name? (It reaches friends at least.)
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
  end;
$$;

create or replace function t1_private.moderation_kick()
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  select value into v_secret from t1_private.settings where name = 'live_push_secret';
  perform net.http_post(
    url := 'https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/moderate',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-t1-secret', v_secret),
    timeout_milliseconds := 10000);
exception when others then
  raise warning 'moderation_kick skipped: %', sqlerrm;
end $$;

-- Queues a check unless this exact content already has one standing for this subject. Content judged allow or block
-- elsewhere is reused at once (a common deck name is checked once). Returns the check id that now stands for it.
create or replace function t1_private.moderation_enqueue(
  p_kind text, p_subject uuid, p_owner uuid, p_content text, p_path text, p_source text default 'write')
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_hash text := md5(p_kind || ':' || coalesce(lower(trim(p_content)), '') || ':' || coalesce(p_path, ''));
  v_id bigint;
  v_prev public.moderation_checks;
  v_status text;
begin
  if coalesce(trim(p_content), '') = '' and p_path is null then return null; end if;
  select * into v_prev from public.moderation_checks c
   where c.subject_kind = p_kind and c.subject_id = p_subject and c.content_hash = v_hash
   order by c.id desc limit 1;
  if v_prev.id is not null then return v_prev.id; end if;
  -- The same words judged before (text only; every photo is checked).
  if p_path is null then
    select * into v_prev from public.moderation_checks c
     where c.content_hash = v_hash and c.status in ('allow', 'block') and c.resolved_at is null
     order by c.decided_at desc limit 1;
  end if;
  v_status := case when v_prev.id is not null then v_prev.status else 'pending' end;
  insert into public.moderation_checks (subject_kind, subject_id, owner, content, path, content_hash, source, status,
                                        category, reason, model, decided_at)
  values (p_kind, p_subject, p_owner, nullif(trim(p_content), ''), p_path, v_hash, p_source, v_status,
          v_prev.category, v_prev.reason, case when v_prev.id is not null then 'cache' end,
          case when v_prev.id is not null then now() end)
  returning id into v_id;
  if v_status = 'pending' then
    perform t1_private.moderation_kick();
  elsif v_status = 'block' then
    perform t1_private.moderation_decided(v_id);
  end if;
  return v_id;
end $$;

-- ==================================================================== c_enforce
-- The action for a blocked check, applied only if the content is still what was judged. Returns the action id.
create or replace function t1_private.moderation_enforce(p_check_id bigint, p_auto boolean default true, p_by uuid default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  c public.moderation_checks;
  v_action text;
  v_label text;
  v_before jsonb;
  v_replaced jsonb;
  v_owner uuid;
  v_id bigint;
  v_cur text;
  v_event uuid;
begin
  select * into c from public.moderation_checks where id = p_check_id;
  if c.id is null then return null; end if;
  -- Already acted on this check.
  select id into v_id from public.moderation_actions where check_id = c.id and reverted_at is null;
  if v_id is not null then return v_id; end if;
  perform set_config('t1.moderating', 'on', true);
  v_owner := c.owner;

  if c.subject_kind = 'display_name' then
    select display_name into v_cur from public.profiles where id = c.subject_id;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'reset_name'; v_label := 'Your display name';
    v_before := jsonb_build_object('display_name', v_cur);
    v_replaced := jsonb_build_object('display_name', 'Player ' || upper(right(replace(c.subject_id::text, '-', ''), 4)));
    update public.profiles set display_name = v_replaced->>'display_name', updated_at = now() where id = c.subject_id;
    update public.participants set display_name = v_replaced->>'display_name' where user_id = c.subject_id and display_name = v_cur;
  elsif c.subject_kind = 'handle' then
    select handle into v_cur from public.profiles where id = c.subject_id;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'clear_handle'; v_label := 'Your handle';
    v_before := jsonb_build_object('handle', v_cur);
    v_replaced := jsonb_build_object('handle', null);
    update public.profiles set handle = null, updated_at = now() where id = c.subject_id;
  elsif c.subject_kind = 'avatar' then
    select avatar_url into v_cur from public.profiles where id = c.subject_id;
    if v_cur is distinct from c.path then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'remove_avatar'; v_label := 'Your profile photo';
    v_before := jsonb_build_object('avatar_url', v_cur);
    v_replaced := jsonb_build_object('avatar_url', null);
    update public.profiles set avatar_url = null, updated_at = now() where id = c.subject_id;
  elsif c.subject_kind = 'list_name' then
    select name, kind into v_cur, v_label from public.card_lists where id = c.subject_id and deleted_at is null;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'unshare';
    v_label := initcap(v_label) || ' ' || v_cur;
    select jsonb_build_object('visibility', visibility) into v_before from public.card_lists where id = c.subject_id;
    v_replaced := jsonb_build_object('visibility', 'private');
    update public.card_lists set visibility = 'private' where id = c.subject_id;
  elsif c.subject_kind = 'binder_name' then
    select name into v_cur from public.binders where id = c.subject_id and deleted_at is null;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'unshare'; v_label := 'Binder ' || v_cur;
    select jsonb_build_object('visibility', visibility) into v_before from public.binders where id = c.subject_id;
    v_replaced := jsonb_build_object('visibility', 'private');
    update public.binders set visibility = 'private' where id = c.subject_id;
  elsif c.subject_kind = 'event_name' then
    select name into v_cur from public.events where id = c.subject_id;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'rename_event'; v_label := 'Event ' || v_cur;
    v_before := jsonb_build_object('name', v_cur);
    v_replaced := jsonb_build_object('name', 'Event ' || (select short_code from public.events where id = c.subject_id));
    update public.events set name = v_replaced->>'name', updated_at = now() where id = c.subject_id;
    insert into public.audit_log (event_id, actor_label, action, target_type, target_id, reason, before, after)
    values (c.subject_id, 'Table 1 moderation', 'moderation.renamed', 'event', c.subject_id, c.category, v_before, v_replaced);
  elsif c.subject_kind = 'guest_name' then
    select display_name, event_id into v_cur, v_event from public.participants where id = c.subject_id;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'rename_guest'; v_label := 'Guest ' || v_cur;
    v_before := jsonb_build_object('display_name', v_cur);
    v_replaced := jsonb_build_object('display_name', 'Guest ' || coalesce((select seat::text from public.participants where id = c.subject_id), ''));
    update public.participants set display_name = v_replaced->>'display_name' where id = c.subject_id;
    insert into public.audit_log (event_id, actor_label, action, target_type, target_id, reason, before, after)
    values (v_event, 'Table 1 moderation', 'moderation.renamed', 'participant', c.subject_id, c.category, v_before, v_replaced);
  elsif c.subject_kind = 'deck_photo' then
    if not exists (select 1 from public.event_deck_photos where id = c.subject_id and path = c.path and hidden_at is null) then
      perform set_config('t1.moderating', '', true); return null;
    end if;
    v_action := 'hide_photo'; v_label := 'Your deck photo';
    v_before := jsonb_build_object('hidden_at', null);
    v_replaced := jsonb_build_object('hidden_at', now());
    update public.event_deck_photos set hidden_at = now() where id = c.subject_id;
  elsif c.subject_kind = 'deck_photo_note' then
    select note into v_cur from public.event_deck_photos where id = c.subject_id;
    if v_cur is distinct from c.content then perform set_config('t1.moderating', '', true); return null; end if;
    v_action := 'clear_note'; v_label := 'Your deck photo note';
    v_before := jsonb_build_object('note', v_cur);
    v_replaced := jsonb_build_object('note', '');
    update public.event_deck_photos set note = '', updated_at = now() where id = c.subject_id;
  else
    perform set_config('t1.moderating', '', true);
    return null;
  end if;

  insert into public.moderation_actions (check_id, owner, subject_kind, subject_id, action, category, label, before, replaced, auto, by_user)
  values (c.id, v_owner, c.subject_kind, c.subject_id, v_action, c.category, v_label, v_before, v_replaced, p_auto, p_by)
  returning id into v_id;
  if v_owner is not null then
    perform public.enqueue_notification('moderation.notice', null, array[v_owner],
      jsonb_build_object('label', v_label, 'action', v_action, 'action_id', v_id));
  end if;
  perform set_config('t1.moderating', '', true);
  return v_id;
end $$;

-- Undo an action: put back what was there, unless the owner has changed it since.
create or replace function t1_private.moderation_revert(p_action_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare a public.moderation_actions;
begin
  select * into a from public.moderation_actions where id = p_action_id for update;
  if a.id is null or a.reverted_at is not null then return; end if;
  perform set_config('t1.moderating', 'on', true);
  if a.action = 'reset_name' then
    update public.profiles set display_name = a.before->>'display_name', updated_at = now()
     where id = a.subject_id and display_name = a.replaced->>'display_name';
    update public.participants set display_name = a.before->>'display_name'
     where user_id = a.subject_id and display_name = a.replaced->>'display_name';
  elsif a.action = 'clear_handle' then
    update public.profiles set handle = a.before->>'handle', updated_at = now() where id = a.subject_id and handle is null
       and not exists (select 1 from public.profiles x where x.handle = a.before->>'handle');
  elsif a.action = 'remove_avatar' then
    update public.profiles set avatar_url = a.before->>'avatar_url', updated_at = now() where id = a.subject_id and avatar_url is null;
  elsif a.action = 'unshare' and a.subject_kind = 'list_name' then
    update public.card_lists set visibility = a.before->>'visibility' where id = a.subject_id and visibility = 'private';
  elsif a.action = 'unshare' then
    update public.binders set visibility = a.before->>'visibility' where id = a.subject_id and visibility = 'private';
  elsif a.action = 'rename_event' then
    update public.events set name = a.before->>'name', updated_at = now() where id = a.subject_id and name = a.replaced->>'name';
    insert into public.audit_log (event_id, actor_label, action, target_type, target_id, before, after)
    values (a.subject_id, 'Table 1 moderation', 'moderation.restored', 'event', a.subject_id, a.replaced, a.before);
  elsif a.action = 'rename_guest' then
    update public.participants set display_name = a.before->>'display_name'
     where id = a.subject_id and display_name = a.replaced->>'display_name';
  elsif a.action = 'hide_photo' then
    update public.event_deck_photos set hidden_at = null where id = a.subject_id;
  elsif a.action = 'clear_note' then
    update public.event_deck_photos set note = a.before->>'note', updated_at = now() where id = a.subject_id and note = '';
  end if;
  update public.moderation_actions set reverted_at = now() where id = a.id;
  perform set_config('t1.moderating', '', true);
end $$;

-- After a check is decided: enforce a block (enforce mode, or child safety in any mode) and tell moderators about
-- anything that needs a person, at most once an hour.
create or replace function t1_private.moderation_decided(p_check_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c public.moderation_checks;
  v_last timestamptz;
  v_open integer;
begin
  select * into c from public.moderation_checks where id = p_check_id;
  if c.status = 'block' and (t1_private.moderation_mode() = 'enforce' or c.category = 'child_safety') then
    perform t1_private.moderation_enforce(c.id);
  end if;
  if c.status in ('review', 'block') then
    select at into v_last from t1_private.moderation_state where key = 'review_push';
    if c.category = 'child_safety' or v_last is null or v_last < now() - interval '1 hour' then
      select count(*) into v_open from public.moderation_checks where status in ('review', 'block') and resolved_at is null;
      insert into t1_private.moderation_state (key, at) values ('review_push', now())
        on conflict (key) do update set at = excluded.at;
      perform public.enqueue_notification('moderation.review', null,
        (select array_agg(user_id) from t1_private.moderators),
        jsonb_build_object('open', v_open, 'urgent', c.category = 'child_safety'));
    end if;
  end if;
end $$;

-- ==================================================================== d_triggers
create or replace function t1_private.mod_profiles_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if current_setting('t1.moderating', true) = 'on' or new.is_demo or new.deleted_at is not null then return null; end if;
  if tg_op = 'INSERT' or new.display_name is distinct from old.display_name then
    perform t1_private.moderation_enqueue('display_name', new.id, new.id, new.display_name, null);
  end if;
  if new.handle is not null and (tg_op = 'INSERT' or new.handle is distinct from old.handle) then
    perform t1_private.moderation_enqueue('handle', new.id, new.id, new.handle, null);
  end if;
  if new.avatar_url is not null and (tg_op = 'INSERT' or new.avatar_url is distinct from old.avatar_url) then
    perform t1_private.moderation_enqueue('avatar', new.id, new.id, null, new.avatar_url);
  end if;
  return null;
end $$;
drop trigger if exists profiles_moderation on public.profiles;
create trigger profiles_moderation after insert or update of display_name, handle, avatar_url on public.profiles
  for each row execute function t1_private.mod_profiles_trg();

create or replace function t1_private.mod_lists_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if current_setting('t1.moderating', true) = 'on' or new.deleted_at is not null then return null; end if;
  if (tg_op = 'INSERT' or new.name is distinct from old.name or new.visibility is distinct from old.visibility)
     and t1_private.item_visible(case when tg_table_name = 'binders' then 'binder' else 'list' end, new.id) then
    perform t1_private.moderation_enqueue(case when tg_table_name = 'binders' then 'binder_name' else 'list_name' end,
                                          new.id, new.user_id, new.name, null);
  end if;
  return null;
end $$;
drop trigger if exists card_lists_moderation on public.card_lists;
create trigger card_lists_moderation after insert or update of name, visibility on public.card_lists
  for each row execute function t1_private.mod_lists_trg();
drop trigger if exists binders_moderation on public.binders;
create trigger binders_moderation after insert or update of name, visibility on public.binders
  for each row execute function t1_private.mod_lists_trg();

-- Sharing opened up: the names that now reach someone get checked.
create or replace function t1_private.moderation_sweep_user(p_uid uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_n integer := 0; r record;
begin
  for r in select 'list_name' k, l.id, l.name from public.card_lists l
            where l.user_id = p_uid and l.deleted_at is null and t1_private.item_visible('list', l.id)
           union all
           select 'binder_name', b.id, b.name from public.binders b
            where b.user_id = p_uid and b.deleted_at is null and t1_private.item_visible('binder', b.id) loop
    perform t1_private.moderation_enqueue(r.k, r.id, p_uid, r.name, null, 'sweep');
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function t1_private.mod_share_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform t1_private.moderation_sweep_user(new.user_id);
  return null;
end $$;
drop trigger if exists share_settings_moderation on public.share_settings;
create trigger share_settings_moderation after insert or update on public.share_settings
  for each row execute function t1_private.mod_share_trg();

create or replace function t1_private.mod_events_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if current_setting('t1.moderating', true) = 'on' or new.is_demo then return null; end if;
  if tg_op = 'INSERT' or new.name is distinct from old.name then
    perform t1_private.moderation_enqueue('event_name', new.id, new.created_by, new.name, null);
  end if;
  return null;
end $$;
drop trigger if exists events_moderation on public.events;
create trigger events_moderation after insert or update of name on public.events
  for each row execute function t1_private.mod_events_trg();

-- Guests only (a signed-in player's name is their profile's, checked there). The organizer typed it or the guest
-- joined by code, so the notice goes to the organizer.
create or replace function t1_private.mod_guests_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_org uuid;
begin
  if current_setting('t1.moderating', true) = 'on' or new.user_id is not null then return null; end if;
  if tg_op = 'INSERT' or new.display_name is distinct from old.display_name then
    select created_by into v_org from public.events where id = new.event_id and not is_demo;
    if not found then return null; end if;
    perform t1_private.moderation_enqueue('guest_name', new.id, v_org, new.display_name, null);
  end if;
  return null;
end $$;
drop trigger if exists participants_moderation on public.participants;
create trigger participants_moderation after insert or update of display_name on public.participants
  for each row execute function t1_private.mod_guests_trg();

create or replace function t1_private.mod_photos_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if current_setting('t1.moderating', true) = 'on' then return null; end if;
  if tg_op = 'INSERT' or new.path is distinct from old.path then
    perform t1_private.moderation_enqueue('deck_photo', new.id, new.uploaded_by, null, new.path);
  end if;
  if coalesce(new.note, '') <> '' and (tg_op = 'INSERT' or new.note is distinct from old.note) then
    perform t1_private.moderation_enqueue('deck_photo_note', new.id, new.uploaded_by, new.note, null);
  end if;
  return null;
end $$;
drop trigger if exists event_deck_photos_moderation on public.event_deck_photos;
create trigger event_deck_photos_moderation after insert or update of path, note on public.event_deck_photos
  for each row execute function t1_private.mod_photos_trg();

-- A hidden deck photo shows only to whoever took it.
create or replace function public.deck_photo_visible(ph public.event_deck_photos)
returns boolean language sql stable security definer set search_path = '' as $$
  select ph.uploaded_by = auth.uid()
      or (ph.hidden_at is null and (
            exists (select 1 from public.participants p where p.id = ph.participant_id and p.user_id = auth.uid())
         or public.is_event_organizer(ph.event_id)
         or (public.in_event(ph.event_id)
             and exists (select 1 from public.events e where e.id = ph.event_id and e.status in ('completed', 'archived')))));
$$;
revoke execute on function public.deck_photo_visible(public.event_deck_photos) from public, anon;

-- Reports queue a check of what was reported and link to it.
create or replace function t1_private.mod_reports_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_check bigint;
  v_kind text := new.context->>'kind';
  v_item uuid := (new.context->>'id')::uuid;
  p public.profiles;
begin
  if v_kind in ('deck', 'cube') and exists (select 1 from public.card_lists where id = v_item and user_id = new.reported) then
    v_check := t1_private.moderation_enqueue('list_name', v_item, new.reported,
                                             (select name from public.card_lists where id = v_item), null, 'report');
  elsif v_kind = 'binder' and exists (select 1 from public.binders where id = v_item and user_id = new.reported) then
    v_check := t1_private.moderation_enqueue('binder_name', v_item, new.reported,
                                             (select name from public.binders where id = v_item), null, 'report');
  else
    select * into p from public.profiles where id = new.reported;
    if p.avatar_url is not null and new.reason = 'offensive_profile' then
      perform t1_private.moderation_enqueue('avatar', p.id, p.id, null, p.avatar_url, 'report');
    end if;
    if p.handle is not null then perform t1_private.moderation_enqueue('handle', p.id, p.id, p.handle, null, 'report'); end if;
    v_check := t1_private.moderation_enqueue('display_name', p.id, p.id, p.display_name, null, 'report');
  end if;
  update public.user_reports set check_id = v_check where id = new.id;
  return null;
end $$;
drop trigger if exists user_reports_moderation on public.user_reports;
create trigger user_reports_moderation after insert on public.user_reports
  for each row execute function t1_private.mod_reports_trg();

-- ==================================================================== e_worker (service role)
-- Hands out up to p_limit checks to judge, with a 5-minute lease (a crashed run is picked up again; 3 tries).
create or replace function public.moderation_claim(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  with picked as (
    select c.id from public.moderation_checks c
     where (c.status = 'pending' or (c.status = 'running' and c.claimed_at < now() - interval '5 minutes'))
       and c.attempts < 3
     order by (c.source = 'report') desc, c.id
     limit least(greatest(coalesce(p_limit, 20), 1), 50)
     for update skip locked
  ), upd as (
    update public.moderation_checks c set status = 'running', claimed_at = now(), attempts = c.attempts + 1
      from picked where c.id = picked.id
    returning c.id, c.subject_kind, c.content, c.path
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'kind', u.subject_kind, 'text', u.content,
           'bucket', case u.subject_kind when 'avatar' then 'avatars' when 'deck_photo' then 'deck-photos' end,
           'path', u.path) order by u.id), '[]'::jsonb)
    into v from upd u;
  -- Gave up after 3 tries: a person looks.
  update public.moderation_checks set status = 'review', reason = 'Could not be checked automatically', decided_at = now()
   where status in ('pending', 'running') and attempts >= 3 and (claimed_at is null or claimed_at < now() - interval '5 minutes');
  return v;
end $$;

-- p_results: [{id, verdict: allow | review | block, category, reason, model}].
create or replace function public.moderation_record(p_results jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r jsonb;
  v_n integer := 0;
  v_id bigint;
begin
  for r in select * from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) loop
    v_id := null;
    if r->>'verdict' not in ('allow', 'review', 'block') then continue; end if;
    update public.moderation_checks
       set status = r->>'verdict', category = nullif(r->>'category', 'none'), reason = left(r->>'reason', 300),
           model = left(r->>'model', 60), decided_at = now()
     where id = (r->>'id')::bigint and status = 'running'
    returning id into v_id;
    if v_id is null then continue; end if;
    v_n := v_n + 1;
    perform t1_private.moderation_decided(v_id);
  end loop;
  return jsonb_build_object('recorded', v_n);
end $$;

-- ==================================================================== f_owner
create or replace function public.moderation_notices()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', a.id, 'subject_kind', a.subject_kind, 'label', a.label, 'action', a.action, 'category', a.category,
      'reason_text', t1_private.moderation_reason_text(a.category), 'at', a.at, 'seen', a.seen_at is not null,
      'appeal', case when a.reverted_at is not null then 'reverted' else a.appeal_status end,
      'can_appeal', a.appeal_status = 'none' and a.reverted_at is null) order by a.at desc)
    from public.moderation_actions a
   where a.owner = v_uid and a.at > now() - interval '180 days'), '[]'::jsonb);
end $$;

create or replace function public.moderation_notices_seen()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  update public.moderation_actions set seen_at = now() where owner = auth.uid() and seen_at is null;
end $$;

create or replace function public.moderation_appeal(p_action_id bigint, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  a public.moderation_actions;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  select * into a from public.moderation_actions where id = p_action_id for update;
  if a.id is null or a.owner is distinct from v_uid then raise exception 'That isn''t yours' using errcode = '42501'; end if;
  if a.appeal_status <> 'none' or a.reverted_at is not null then
    raise exception 'You already appealed this' using errcode = '22023';
  end if;
  if length(v_note) > 500 then raise exception 'Keep the note under 500 characters' using errcode = '22023'; end if;
  update public.moderation_actions set appeal_status = 'open', appeal_note = v_note, appealed_at = now() where id = a.id;
  perform t1_private.account_audit(v_uid, 'moderation.appealed', null, null, jsonb_build_object('action_id', a.id));
  perform public.enqueue_notification('moderation.review', null, (select array_agg(user_id) from t1_private.moderators),
    jsonb_build_object('appeal', true));
  return jsonb_build_object('appeal', 'open');
end $$;

-- ==================================================================== g_moderators
create or replace function t1_private.strikes(p_uid uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.moderation_actions a
   where a.owner = p_uid and a.reverted_at is null and a.at > now() - interval '90 days';
$$;

-- Distinct reporters of an account in 14 days who are trusted (not 3+ dismissed reports with none actioned).
create or replace function t1_private.trusted_reporters(p_uid uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select count(distinct r.reporter)::int from public.user_reports r
   where r.reported = p_uid and r.reporter is not null and r.created_at > now() - interval '14 days'
     and not exists (
       select 1 from public.user_reports x where x.reporter = r.reporter
       group by x.reporter
       having count(*) filter (where x.status = 'dismissed') >= 3 and count(*) filter (where x.status = 'actioned') = 0);
$$;

create or replace function public.moderation_queue(p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_lim integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_threshold integer := coalesce((select report_threshold from t1_private.moderation_settings), 3);
begin
  perform t1_private.require_moderator();
  return jsonb_build_object(
    'mode', t1_private.moderation_mode(),
    'checks', coalesce((select jsonb_agg(x order by x->>'priority' desc, (x->>'id')::bigint) from (
      select jsonb_build_object(
        'id', c.id, 'subject_kind', c.subject_kind, 'subject_id', c.subject_id, 'text', c.content,
        'bucket', case c.subject_kind when 'avatar' then 'avatars' when 'deck_photo' then 'deck-photos' end, 'path', c.path,
        'status', c.status, 'category', c.category, 'reason', c.reason, 'source', c.source, 'at', c.created_at,
        'enforced', exists (select 1 from public.moderation_actions a where a.check_id = c.id and a.reverted_at is null),
        'owner', t1_private.person_json(c.owner), 'strikes', t1_private.strikes(c.owner),
        'reports', (select count(*) from public.user_reports r where r.check_id = c.id),
        'priority', case when c.category = 'child_safety' then 3 when c.status = 'block' then 2
                         when c.source = 'report' then 1 else 0 end) x
        from public.moderation_checks c
       where c.status in ('review', 'block') and c.resolved_at is null
       order by c.id limit v_lim) q), '[]'::jsonb),
    'appeals', coalesce((select jsonb_agg(jsonb_build_object(
        'id', a.id, 'label', a.label, 'action', a.action, 'category', a.category, 'note', a.appeal_note,
        'at', a.appealed_at, 'before', a.before, 'owner', t1_private.person_json(a.owner),
        'text', (select c.content from public.moderation_checks c where c.id = a.check_id),
        'path', (select c.path from public.moderation_checks c where c.id = a.check_id),
        'bucket', case a.subject_kind when 'avatar' then 'avatars' when 'deck_photo' then 'deck-photos' end)
        order by a.appealed_at)
      from public.moderation_actions a where a.appeal_status = 'open' limit v_lim), '[]'::jsonb),
    'flagged', coalesce((select jsonb_agg(t1_private.person_json(f.uid) || jsonb_build_object(
        'strikes', t1_private.strikes(f.uid), 'reporters', t1_private.trusted_reporters(f.uid),
        'restricted_until', (select until from public.moderation_restrictions r where r.user_id = f.uid and r.until > now())))
      from (select distinct uid from (
              select a.owner uid from public.moderation_actions a
               where a.owner is not null and a.reverted_at is null and a.at > now() - interval '90 days'
               group by a.owner having count(*) >= 3
              union
              select r.reported from public.user_reports r where r.created_at > now() - interval '14 days'
               group by r.reported having count(distinct r.reporter) >= v_threshold) u) f
     where t1_private.strikes(f.uid) >= 3 or t1_private.trusted_reporters(f.uid) >= v_threshold), '[]'::jsonb));
end $$;

-- allow: undoes any action and dismisses linked reports. block: applies the action (any mode), actions linked reports.
create or replace function public.moderation_resolve(p_check_id bigint, p_decision text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_mod uuid := t1_private.require_moderator();
  c public.moderation_checks;
  v_action bigint;
begin
  if p_decision not in ('allow', 'block') then raise exception 'Allow or block' using errcode = '22023'; end if;
  select * into c from public.moderation_checks where id = p_check_id for update;
  if c.id is null then raise exception 'That check is gone' using errcode = 'P0002'; end if;
  update public.moderation_checks
     set status = p_decision, resolved_by = v_mod, resolved_at = now(),
         reason = coalesce(nullif(trim(coalesce(p_note, '')), ''), reason)
   where id = c.id;
  if p_decision = 'allow' then
    for v_action in select id from public.moderation_actions where check_id = c.id and reverted_at is null loop
      perform t1_private.moderation_revert(v_action);
    end loop;
    update public.user_reports set status = 'dismissed', reviewed_at = now() where check_id = c.id and status = 'open';
  else
    v_action := t1_private.moderation_enforce(c.id, false, v_mod);
    update public.user_reports set status = 'actioned', reviewed_at = now() where check_id = c.id and status = 'open';
  end if;
  perform t1_private.account_audit(v_mod, 'moderation.resolved', c.owner, null,
    jsonb_build_object('check_id', c.id, 'decision', p_decision));
  return jsonb_build_object('status', p_decision, 'action_id', v_action);
end $$;

create or replace function public.moderation_appeal_resolve(p_action_id bigint, p_decision text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_mod uuid := t1_private.require_moderator();
  a public.moderation_actions;
begin
  if p_decision not in ('uphold', 'revert') then raise exception 'Uphold or revert' using errcode = '22023'; end if;
  select * into a from public.moderation_actions where id = p_action_id for update;
  if a.id is null then raise exception 'That action is gone' using errcode = 'P0002'; end if;
  if p_decision = 'revert' then
    perform t1_private.moderation_revert(a.id);
    update public.moderation_checks set status = 'allow', resolved_by = v_mod, resolved_at = now() where id = a.check_id;
  else
    update public.moderation_checks set resolved_by = v_mod, resolved_at = now() where id = a.check_id;
  end if;
  update public.moderation_actions
     set appeal_status = case when p_decision = 'revert' then 'reverted' else 'upheld' end,
         appeal_resolved_at = now(), appeal_resolved_by = v_mod
   where id = a.id;
  perform t1_private.account_audit(v_mod, 'moderation.appeal_resolved', a.owner, null,
    jsonb_build_object('action_id', a.id, 'decision', p_decision));
  if a.owner is not null then
    perform public.enqueue_notification('moderation.notice', null, array[a.owner],
      jsonb_build_object('label', a.label, 'appeal', p_decision, 'action_id', a.id));
  end if;
  return jsonb_build_object('appeal', case when p_decision = 'revert' then 'reverted' else 'upheld' end,
                            'delete_path', case when p_decision = 'uphold' and a.action = 'remove_avatar' then a.before->>'avatar_url' end);
end $$;

create or replace function public.moderation_restrict(p_user_id uuid, p_days integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_mod uuid := t1_private.require_moderator();
begin
  if p_user_id is null or p_days is null or p_days < 0 or p_days > 365 then
    raise exception 'Restrict for 0 to 365 days' using errcode = '22023';
  end if;
  if p_days = 0 then
    delete from public.moderation_restrictions where user_id = p_user_id;
  else
    if coalesce(trim(p_reason), '') = '' then raise exception 'Say why' using errcode = '22023'; end if;
    insert into public.moderation_restrictions (user_id, until, reason, by_user)
    values (p_user_id, now() + make_interval(days => p_days), left(trim(p_reason), 300), v_mod)
    on conflict (user_id) do update set until = excluded.until, reason = excluded.reason, by_user = excluded.by_user, at = now();
    perform public.enqueue_notification('moderation.notice', null, array[p_user_id],
      jsonb_build_object('restricted_days', p_days));
  end if;
  perform t1_private.account_audit(v_mod, 'moderation.restricted', p_user_id, null, jsonb_build_object('days', p_days));
  return jsonb_build_object('restricted_until', (select until from public.moderation_restrictions where user_id = p_user_id));
end $$;

create or replace function public.moderation_stats(p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_since timestamptz := now() - make_interval(days => least(greatest(coalesce(p_days, 30), 1), 365));
begin
  perform t1_private.require_moderator();
  return jsonb_build_object(
    'mode', t1_private.moderation_mode(),
    'checks', coalesce((select jsonb_object_agg(k, n) from (
        select c.status || ':' || coalesce(c.category, 'none') k, count(*) n from public.moderation_checks c
         where c.created_at > v_since group by 1) s), '{}'::jsonb),
    'cached', (select count(*) from public.moderation_checks c where c.created_at > v_since and c.model = 'cache'),
    'actions', (select count(*) from public.moderation_actions a where a.at > v_since),
    'appeals', (select count(*) from public.moderation_actions a where a.appealed_at > v_since),
    'reverted_on_appeal', (select count(*) from public.moderation_actions a where a.appealed_at > v_since and a.appeal_status = 'reverted'),
    'moderator_overturned', (select count(*) from public.moderation_checks c
                              where c.created_at > v_since and c.resolved_at is not null and c.model is distinct from 'cache'
                                and c.status = 'allow' and c.category is not null),
    'reports', (select count(*) from public.user_reports r where r.created_at > v_since));
end $$;

create or replace function public.moderation_set_mode(p_mode text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_mod uuid := t1_private.require_moderator();
begin
  if p_mode not in ('shadow', 'enforce') then raise exception 'shadow or enforce' using errcode = '22023'; end if;
  update t1_private.moderation_settings set mode = p_mode, updated_at = now();
  perform t1_private.account_audit(v_mod, 'moderation.mode', null, null, jsonb_build_object('mode', p_mode));
  return jsonb_build_object('mode', p_mode);
end $$;

-- Is this account a moderator (shows the Review row)?
create or replace function public.moderation_me()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('moderator', t1_private.is_moderator(auth.uid()),
                            'unseen', (select count(*) from public.moderation_actions a where a.owner = auth.uid() and a.seen_at is null),
                            'restricted_until', (select until from public.moderation_restrictions r where r.user_id = auth.uid() and r.until > now()));
$$;

-- ==================================================================== h_restrictions
-- A restricted account can't ask anyone to be friends or look up emails, and its profile shows to no one else.
create or replace function t1_private.account_rate_limit(p_actor uuid, p_action text, p_max integer, p_window interval)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_action in ('friend.request', 'friend.email_lookup') and t1_private.is_restricted(p_actor) then
    raise exception 'You can''t send friend requests right now' using errcode = '42501';
  end if;
  if (select count(*) from public.account_audit a
       where a.actor = p_actor and a.action = p_action and a.at > now() - p_window) >= p_max then
    raise exception 'Too many requests, try again later' using errcode = '53400';
  end if;
end $$;

create or replace function t1_private.share_of(p_owner uuid)
returns public.share_settings language sql stable security definer set search_path = '' as $$
  select case when t1_private.is_restricted(p_owner) then
      row(p_owner, 'private', 'private', null, null, null, null, null, null, 'private', now())::public.share_settings
    else coalesce(
      (select s from public.share_settings s where s.user_id = p_owner),
      row(p_owner, 'friends', 'private', null, null, null, null, null, null, 'private', now())::public.share_settings) end;
$$;

-- ==================================================================== i_retention
-- Text kept 180 days; a deleted account's checks go, its actions stay without the owner.
create or replace function t1_private.moderation_purge()
returns void language sql security definer set search_path = '' as $$
  update public.moderation_checks set content = null
   where content is not null and created_at < now() - interval '180 days' and status not in ('pending', 'running');
$$;

create or replace function t1_private.mod_forget_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.moderation_checks where owner = new.id;
  update public.moderation_actions set owner = null, before = '{}'::jsonb where owner = new.id;
  delete from public.moderation_restrictions where user_id = new.id;
  return null;
end $$;
drop trigger if exists profiles_moderation_forget on public.profiles;
create trigger profiles_moderation_forget after update of deleted_at on public.profiles
  for each row when (old.deleted_at is null and new.deleted_at is not null)
  execute function t1_private.mod_forget_trg();

-- Nightly: names that reach someone and have no check for their current text.
create or replace function t1_private.moderation_sweep()
returns integer language plpgsql security definer set search_path = '' as $$
declare v_n integer := 0; r record;
begin
  for r in select distinct user_id from (
             select l.user_id from public.card_lists l where l.deleted_at is null
             union select b.user_id from public.binders b where b.deleted_at is null) u
            join public.profiles p on p.id = u.user_id and p.deleted_at is null and not p.is_demo loop
    v_n := v_n + t1_private.moderation_sweep_user(r.user_id);
  end loop;
  return v_n;
end $$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-moderation-tick') then
      perform cron.schedule('t1-moderation-tick', '* * * * *',
        $c$select t1_private.moderation_kick() where exists (select 1 from public.moderation_checks where status in ('pending', 'running'))$c$);
    end if;
    if not exists (select 1 from cron.job where jobname = 't1-moderation-sweep') then
      perform cron.schedule('t1-moderation-sweep', '13 5 * * *', 'select t1_private.moderation_sweep()');
    end if;
    if not exists (select 1 from cron.job where jobname = 't1-moderation-purge') then
      perform cron.schedule('t1-moderation-purge', '43 5 * * *', 'select t1_private.moderation_purge()');
    end if;
  end if;
end $$;

-- ==================================================================== j_grants
do $$
declare f text;
begin
  foreach f in array array[
    'is_moderator(uuid)', 'require_moderator()', 'moderation_mode()', 'is_restricted(uuid)', 'moderation_reason_text(text)',
    'item_visible(text, uuid)', 'moderation_kick()', 'moderation_enqueue(text, uuid, uuid, text, text, text)',
    'moderation_enforce(bigint, boolean, uuid)', 'moderation_revert(bigint)', 'moderation_decided(bigint)',
    'mod_profiles_trg()', 'mod_lists_trg()', 'moderation_sweep_user(uuid)', 'mod_share_trg()', 'mod_events_trg()',
    'mod_guests_trg()', 'mod_photos_trg()', 'mod_reports_trg()', 'strikes(uuid)', 'trusted_reporters(uuid)',
    'moderation_purge()', 'mod_forget_trg()', 'moderation_sweep()'] loop
    execute format('revoke execute on function t1_private.%s from public', f);
  end loop;
  foreach f in array array['moderation_claim(integer)', 'moderation_record(jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array[
    'moderation_notices()', 'moderation_notices_seen()', 'moderation_appeal(bigint, text)', 'moderation_queue(integer)',
    'moderation_resolve(bigint, text, text)', 'moderation_appeal_resolve(bigint, text, text)',
    'moderation_restrict(uuid, integer, text)', 'moderation_stats(integer)', 'moderation_set_mode(text)', 'moderation_me()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
