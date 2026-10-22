-- Bug inbox (contract/bug-pipeline-2026-10-18.md § Inbox, 2026-10-22). Tapping a bug push opened the app's home and
-- nothing more. Now the watchers (t1_private.bug_watchers, John) have Account → Bugs: the register, each bug's sample
-- and fix, and what is waiting to ship. From there they change a bug's severity or status, answer the fix runner,
-- leave notes the runner reads on its next claim (`john_notes`), and mark a platform shipped.
-- Every function here refuses anyone who isn't a watcher (42501); `bugs_me` says only {watcher: false} to them.
-- Ops pushes are also checked against the watchers when they are sent (`notify_ops_recipients`, notify-worker).

-- ==================================================================== a_notes
-- John's notes and the changes he made, per bug. The runner's own notes stay in bugs.notes.
create table if not exists t1_private.bug_notes (
  id bigint generated always as identity primary key,
  bug_id bigint not null references t1_private.bugs (id) on delete cascade,
  author uuid references auth.users (id) on delete set null,
  kind text not null default 'note' check (kind in ('note', 'change')),
  body text not null check (length(body) between 1 and 2000),
  client_key uuid unique,                    -- a retried send doesn't post twice
  at timestamptz not null default now()
);
create index if not exists bug_notes_bug on t1_private.bug_notes (bug_id, at);
revoke all on t1_private.bug_notes from anon, authenticated, public;

-- ==================================================================== b_helpers
create or replace function t1_private.bug_watcher_check()
returns uuid language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists (select 1 from t1_private.bug_watchers where user_id = auth.uid()) then
    raise exception 'Bug watchers only' using errcode = '42501';
  end if;
  return auth.uid();
end $$;

-- The runner's last note line: its question when it needs John, or where it got to.
create or replace function t1_private.bug_last_note(p_notes text)
returns text language sql immutable set search_path = '' as $$
  select nullif(left(trim((select x from regexp_split_to_table(coalesce(p_notes, ''), E'\n+') with ordinality t(x, n)
                           where trim(x) <> '' order by n desc limit 1)), 300), '');
$$;

create or replace function t1_private.bug_john_notes(p_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('at', at, 'body', body) order by at), '[]')
    from t1_private.bug_notes where bug_id = p_id and kind = 'note';
$$;

create or replace function t1_private.bug_row(b t1_private.bugs)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', b.id, 'severity', b.severity, 'status', b.status, 'platform', b.platform,
    'title', b.title, 'events', b.events, 'users', b.users, 'regressed', b.regressed, 'last_seen', b.last_seen,
    'fixed_at', b.fixed_at, 'fix_platforms', b.fix_platforms, 'shipped', b.shipped,
    'last_note', t1_private.bug_last_note(b.notes),
    'my_notes', (select count(*) from t1_private.bug_notes n where n.bug_id = b.id and n.kind = 'note'));
$$;

-- ==================================================================== c_reads
create or replace function public.bugs_me()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when auth.uid() is null or not exists (select 1 from t1_private.bug_watchers where user_id = auth.uid())
    then jsonb_build_object('watcher', false)
    else jsonb_build_object('watcher', true,
      'needs_you', (select count(*) from t1_private.bugs where status = 'needs_john'),
      'open', (select count(*) from t1_private.bugs where status in ('new', 'open', 'fixing')),
      'to_ship', (select count(*) from jsonb_array_elements(t1_private.bug_pending()) e where (e->>'due')::boolean))
  end;
$$;

-- Everything not settled (waiting, being fixed, needing John, fixed but not shipped everywhere), most urgent first;
-- p_closed adds what closed in the last 30 days. Plus the per-platform shipping summary.
create or replace function public.bugs_inbox(p_closed boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform t1_private.bug_watcher_check();
  return jsonb_build_object(
    'bugs', (select coalesce(jsonb_agg(t1_private.bug_row(b) order by t1_private.bug_rank(b.severity), b.last_seen desc, b.id desc), '[]')
               from t1_private.bugs b
              where b.status in ('new', 'open', 'fixing', 'needs_john')
                 or (b.status = 'fixed' and not b.fix_platforms <@ b.shipped)
                 or (coalesce(p_closed, false) and b.updated_at > now() - interval '30 days')),
    'pending', t1_private.bug_pending());
end $$;

create or replace function public.bugs_detail(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare b t1_private.bugs;
begin
  perform t1_private.bug_watcher_check();
  select * into b from t1_private.bugs where id = p_id;
  if b.id is null then raise exception 'No such bug' using errcode = 'P0002'; end if;
  return to_jsonb(b) - 'notified_at' - 'fingerprint'
    || jsonb_build_object(
      'duplicate_title', (select title from t1_private.bugs d where d.id = b.duplicate_of),
      'log', (select coalesce(jsonb_agg(jsonb_build_object('kind', n.kind, 'body', n.body, 'at', n.at) order by n.at), '[]')
                from t1_private.bug_notes n where n.bug_id = b.id));
end $$;

-- ==================================================================== d_writes
-- p: {severity?: S1–S4, status?: open | wontfix | needs_john, note?: text, key?: uuid}. Only what changed is
-- applied; each change and the note are logged. A bug the runner is fixing keeps its status (PT409), and a bug
-- sent to the runner needs a severity. Retrying with the same key returns the bug unchanged.
create or replace function public.bugs_update(p_id bigint, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.bug_watcher_check();
  b t1_private.bugs;
  v_set jsonb := '{}';
  v_note text := nullif(trim(left(p->>'note', 2000)), '');
  v_key uuid;
  v_changes text[] := '{}';
begin
  begin
    v_key := nullif(p->>'key', '')::uuid;
  exception when invalid_text_representation then
    raise exception 'Bad key' using errcode = '22023';
  end;
  if v_key is not null and exists (select 1 from t1_private.bug_notes where client_key = v_key) then
    return public.bugs_detail(p_id);
  end if;
  select * into b from t1_private.bugs where id = p_id for update;
  if b.id is null then raise exception 'No such bug' using errcode = 'P0002'; end if;

  if p ? 'severity' and p->>'severity' is distinct from b.severity then
    v_set := v_set || jsonb_build_object('severity', p->>'severity');
    v_changes := v_changes || ('Severity ' || coalesce(b.severity, 'none') || ' → ' || coalesce(p->>'severity', 'none'));
  end if;
  if p ? 'status' and p->>'status' is distinct from b.status then
    if b.status = 'fixing' then
      raise exception 'The fix runner is working on this one. Try again when it''s done.' using errcode = 'PT409';
    end if;
    if p->>'status' = 'open' and coalesce(v_set->>'severity', b.severity) is null then
      raise exception 'Pick a severity first' using errcode = '22023';
    end if;
    v_set := v_set || jsonb_build_object('status', p->>'status');
    v_changes := v_changes || case p->>'status'
      when 'open' then 'Sent to the fix runner'
      when 'wontfix' then 'Won''t fix'
      when 'needs_john' then 'Kept for John'
      else 'Status ' || (p->>'status') end;
  end if;

  if v_set <> '{}' then
    perform public.bug_set(p_id, v_set);       -- validates severity and status (22023)
    insert into t1_private.bug_notes (bug_id, author, kind, body, client_key)
    values (p_id, v_uid, 'change', array_to_string(v_changes, ' · '), case when v_note is null then v_key end);
  end if;
  if v_note is not null then
    insert into t1_private.bug_notes (bug_id, author, kind, body, client_key) values (p_id, v_uid, 'note', v_note, v_key);
  end if;
  return public.bugs_detail(p_id);
end $$;

-- A build or deploy went out for a platform: all its pending fixes are shipped (as `bugs.py shipped <platform>`
-- without --commit). Nothing pending → nothing happens, so a retry is harmless.
create or replace function public.bugs_ship(p_platform text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := t1_private.bug_watcher_check();
  v_out jsonb;
begin
  if p_platform not in ('ios', 'android', 'web', 'server') then raise exception 'Bad platform' using errcode = '22023'; end if;
  if not exists (select 1 from t1_private.bugs where status = 'fixed' and p_platform = any (fix_platforms)
                                                 and not p_platform = any (shipped)) then
    return jsonb_build_object('platform', p_platform, 'shipped', '[]'::jsonb);
  end if;
  v_out := public.bug_shipped(p_platform, 'marked in the app', null);
  insert into t1_private.bug_notes (bug_id, author, kind, body)
  select (x)::bigint, v_uid, 'change',
         'Shipped on ' || case p_platform when 'ios' then 'iOS' when 'android' then 'Android' when 'web' then 'web' else 'the server' end
    from jsonb_array_elements_text(v_out->'shipped') x;
  return v_out;
end $$;

-- ==================================================================== e_runner
-- The runner reads John's notes with the bug it claims (and with bug_get).
create or replace function public.bug_next(p_max text default 'S4', p_runner text default 'runner')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare b t1_private.bugs;
begin
  update t1_private.bugs set status = 'needs_john', claimed_by = null,
    notes = coalesce(notes || E'\n', '') || 'Three fix attempts did not land.', updated_at = now()
  where status = 'fixing' and claimed_at < now() - interval '3 hours' and attempts >= 3;
  update t1_private.bugs set status = 'open', claimed_by = null, updated_at = now()
  where status = 'fixing' and claimed_at < now() - interval '3 hours';

  select * into b from t1_private.bugs
   where status = 'open' and t1_private.bug_rank(severity) <= t1_private.bug_rank(coalesce(p_max, 'S4'))
   order by t1_private.bug_rank(severity), regressed desc, users desc, events desc, last_seen desc
   limit 1 for update skip locked;
  if b.id is null then return null; end if;
  update t1_private.bugs set status = 'fixing', claimed_by = left(p_runner, 80), claimed_at = now(),
    attempts = attempts + 1, updated_at = now()
  where id = b.id returning * into b;
  return to_jsonb(b) - 'notified_at' || jsonb_build_object('john_notes', t1_private.bug_john_notes(b.id));
end $$;

create or replace function public.bug_get(p_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(b) || jsonb_build_object('john_notes', t1_private.bug_john_notes(b.id)) from t1_private.bugs b where b.id = p_id;
$$;

-- ==================================================================== f_push_gate
-- notify-worker keeps only the watchers among an ops push's recipients, whoever queued it.
create or replace function public.notify_ops_recipients(p_user_ids uuid[])
returns uuid[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(user_id), '{}') from t1_private.bug_watchers where user_id = any (coalesce(p_user_ids, '{}'));
$$;

-- ==================================================================== g_grants
do $$
declare f text;
begin
  foreach f in array array[
    'public.bugs_me()', 'public.bugs_inbox(boolean)', 'public.bugs_detail(bigint)', 'public.bugs_update(bigint, jsonb)',
    'public.bugs_ship(text)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['public.bug_next(text, text)', 'public.bug_get(bigint)', 'public.notify_ops_recipients(uuid[])'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array[
    't1_private.bug_watcher_check()', 't1_private.bug_last_note(text)', 't1_private.bug_john_notes(bigint)',
    't1_private.bug_row(t1_private.bugs)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;
