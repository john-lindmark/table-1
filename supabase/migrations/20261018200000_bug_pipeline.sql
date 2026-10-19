-- Bug pipeline (contract/bug-pipeline-2026-10-18.md): errors from Sentry (iOS, Android, web) and from the
-- server's own background work (failed cron jobs, pg_net calls that got a 5xx or timed out) become one row per
-- problem in t1_private.bugs, with a severity S1–S4 (rules, then Claude in the `bugs` edge function). A fix runner
-- on John's Mac (tools/bugs/runner.sh + the fix-bugs skill) claims the most severe open bug, fixes it with a test,
-- merges to main and records which platforms the fix needs shipping on. The watchers (John) get a push for each
-- new S1 and when a platform's unshipped fixes call for a build (or, for the server, a deploy).
-- Everything here is service-role only: the edge function is the only caller.

-- ==================================================================== a_tables
create table if not exists t1_private.bug_watchers (
  user_id uuid primary key references auth.users (id) on delete cascade,
  note text,
  added_at timestamptz not null default now()
);

create table if not exists t1_private.bugs (
  id bigint generated always as identity primary key,
  fingerprint text not null unique,          -- sentry:<issue id>, http:<path>, cron:<job>:<hash>, net:<status>:<hash>, manual:<…>
  source text not null check (source in ('sentry', 'server', 'manual')),
  platform text not null check (platform in ('ios', 'android', 'web', 'server', 'unknown')),
  title text not null,
  culprit text,
  level text,                                -- fatal / error / warning (Sentry's), or error
  detail jsonb not null default '{}',        -- the latest sample: exception, in-app frames, breadcrumbs, tags. No user data.
  link text,                                 -- Sentry issue URL
  environments text[] not null default '{}',
  releases text[] not null default '{}',
  events integer not null default 0,
  users integer not null default 0,
  spikes integer not null default 0,         -- "seen a lot" alerts
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  severity text check (severity in ('S1', 'S2', 'S3', 'S4')),
  severity_reason text,
  severity_by text check (severity_by in ('rules', 'claude', 'john')),
  status text not null default 'new'
    check (status in ('new', 'open', 'fixing', 'fixed', 'needs_john', 'wontfix', 'duplicate')),
  duplicate_of bigint references t1_private.bugs (id),
  regressed boolean not null default false,
  claimed_by text,
  claimed_at timestamptz,
  attempts integer not null default 0,
  notes text,                                -- what the runner found, or what it needs from John
  fix_commit text,
  fix_summary text,
  fix_test text,
  fix_platforms text[] not null default '{}' check (fix_platforms <@ array['ios', 'android', 'web', 'server']),
  fixed_at timestamptz,
  shipped text[] not null default '{}',      -- platforms the fix has shipped on (a build, or a server deploy)
  notified_at timestamptz,                   -- S1 push sent
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists bugs_queue on t1_private.bugs (status, severity, last_seen desc);

create table if not exists t1_private.bug_ships (
  id bigint generated always as identity primary key,
  platform text not null check (platform in ('ios', 'android', 'web', 'server')),
  version text,
  bug_ids bigint[] not null default '{}',
  shipped_at timestamptz not null default now()
);

create table if not exists t1_private.bug_state (
  id integer primary key default 1 check (id = 1),
  cron_swept_to timestamptz not null default now(),
  net_swept_to bigint not null default 0,
  build_notice text,                         -- the last build-needed summary pushed
  build_notice_at timestamptz
);
insert into t1_private.bug_state (id) values (1) on conflict do nothing;

revoke all on t1_private.bug_watchers, t1_private.bugs, t1_private.bug_ships, t1_private.bug_state
  from anon, authenticated, public;

-- John watches (lindmarkjohn@gmail.com); more are added the same way.
insert into t1_private.bug_watchers (user_id, note)
select id, 'John' from auth.users where lower(email) = 'lindmarkjohn@gmail.com'
on conflict do nothing;

-- ==================================================================== b_helpers
create or replace function t1_private.bug_rank(p_severity text)
returns integer language sql immutable set search_path = '' as $$
  select case p_severity when 'S1' then 1 when 'S2' then 2 when 'S3' then 3 when 'S4' then 4 else 5 end;
$$;

create or replace function t1_private.bug_sev(p_rank integer)
returns text language sql immutable set search_path = '' as $$
  select 'S' || least(greatest(p_rank, 1), 4);
$$;

-- Digits, hex runs and ids differ between occurrences of the same problem; fold them so they group.
create or replace function t1_private.bug_normalize(p_text text)
returns text language sql immutable set search_path = '' as $$
  select left(regexp_replace(regexp_replace(lower(coalesce(p_text, '')),
    '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<id>', 'g'), '[0-9]+', '#', 'g'), 300);
$$;

create or replace function t1_private.bug_watcher_ids()
returns uuid[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(user_id), '{}') from t1_private.bug_watchers;
$$;

create or replace function public.bug_runner_ok(p_secret text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(p_secret, '') <> '' and exists (
    select 1 from t1_private.settings
     where name = 'bug_runner_secret_sha256' and value = encode(sha256(convert_to(p_secret, 'UTF8')), 'hex'));
$$;

create or replace function public.bug_setting(p_name text)
returns text language sql stable security definer set search_path = '' as $$
  select value from t1_private.settings where name = p_name and p_name in ('sentry_client_secret');
$$;

-- Set by the runner (tools/bugs/bugs.sh setup-sentry), never from a client.
create or replace function public.bug_setting_set(p_name text, p_value text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_name not in ('sentry_client_secret') then raise exception 'Unknown setting' using errcode = '22023'; end if;
  insert into t1_private.settings (name, value) values (p_name, p_value)
  on conflict (name) do update set value = excluded.value;
end $$;

-- ==================================================================== c_intake
-- One occurrence (or a batch of them) of a problem. Debug and dev builds never count.
--   {fingerprint, source, platform, title, culprit, level, detail, link, environment, release,
--    events (default 1), users, spike (bool), seen_at}
-- Returns {id, status, created, reopened} or null when ignored.
create or replace function public.bug_report(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_env text := nullif(p->>'environment', '');
  v_rel text := nullif(p->>'release', '');
  v_at timestamptz := coalesce((p->>'seen_at')::timestamptz, now());
  v_users integer := coalesce((p->>'users')::integer, 0);
  v_events integer := greatest(coalesce((p->>'events')::integer, 1), 0);
  v_spike boolean := coalesce((p->>'spike')::boolean, false);
  b t1_private.bugs;
  v_created boolean := false;
  v_reopened boolean := false;
  v_floor integer;
begin
  if coalesce(p->>'fingerprint', '') = '' or coalesce(p->>'title', '') = '' then
    raise exception 'fingerprint and title are required' using errcode = '22023';
  end if;
  if v_env in ('debug', 'dev', 'development') then return null; end if;

  select * into b from t1_private.bugs where fingerprint = p->>'fingerprint' for update;
  if b.id is null then
    insert into t1_private.bugs (fingerprint, source, platform, title, culprit, level, detail, link,
                                 environments, releases, events, users, spikes, first_seen, last_seen)
    values (p->>'fingerprint', coalesce(p->>'source', 'manual'), coalesce(p->>'platform', 'unknown'),
            left(p->>'title', 300), left(p->>'culprit', 300), p->>'level', coalesce(p->'detail', '{}'), p->>'link',
            case when v_env is null then '{}' else array[v_env] end, case when v_rel is null then '{}' else array[v_rel] end,
            v_events, v_users, case when v_spike then 1 else 0 end, v_at, v_at)
    returning * into b;
    v_created := true;
  else
    -- A fix that has shipped on this bug's platform and the problem is back: reopen for triage, one level more urgent.
    -- A fix not shipped yet: the old builds still hit it, so just count.
    if b.status = 'fixed' and (b.platform = any (b.shipped) or (b.platform = 'unknown' and cardinality(b.shipped) > 0)) then
      v_reopened := true;
    end if;
    update t1_private.bugs set
      events = events + v_events,
      users = greatest(users, v_users),
      spikes = spikes + case when v_spike then 1 else 0 end,
      last_seen = greatest(last_seen, v_at),
      environments = case when v_env is null or v_env = any (environments) then environments else environments || v_env end,
      releases = case when v_rel is null or v_rel = any (releases) then releases else (releases || v_rel)[greatest(cardinality(releases) - 18, 1):] end,
      -- A sample with a stack trace is never replaced by one without (an issue webhook after the event alert).
      detail = case when p ? 'detail' and (p->'detail' ? 'exception' or not detail ? 'exception') then p->'detail' else detail end,
      link = coalesce(p->>'link', link),
      culprit = coalesce(left(p->>'culprit', 300), culprit),
      level = case when p->>'level' = 'fatal' then 'fatal' else coalesce(level, p->>'level') end,
      status = case when v_reopened then 'new' else status end,
      regressed = regressed or v_reopened,
      claimed_by = case when v_reopened then null else claimed_by end,
      attempts = case when v_reopened then 0 else attempts end,
      notified_at = case when v_reopened then null else notified_at end,
      updated_at = now()
    where id = b.id
    returning * into b;
  end if;

  -- Volume moves an already-triaged, still-open bug up: 5 people or a spike → at least S2; 25 people or a
  -- second spike → S1. (New and reopened bugs get the same floors in triage.)
  if b.status in ('open', 'fixing', 'needs_john') and b.severity is not null then
    v_floor := case when b.users >= 25 or b.spikes >= 2 then 1 when b.users >= 5 or b.spikes >= 1 then 2 else 4 end;
    if v_floor < t1_private.bug_rank(b.severity) then
      update t1_private.bugs set severity = t1_private.bug_sev(v_floor), severity_by = 'rules',
        severity_reason = case when b.spikes > 0 then 'Seen in a burst' else b.users || ' people hit it' end,
        updated_at = now()
      where id = b.id returning * into b;
      perform t1_private.bug_alert(b.id);
    end if;
  end if;

  return jsonb_build_object('id', b.id, 'status', b.status, 'created', v_created, 'reopened', v_reopened);
end $$;

-- ==================================================================== d_triage
-- Bugs waiting for a severity (new, or reopened), oldest first.
create or replace function public.bug_triage_claim(p_n integer default 20)
returns jsonb language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]') from (
    select id, source, platform, title, culprit, level, detail, environments, releases, events, users, spikes,
           regressed, first_seen, last_seen
      from t1_private.bugs where status = 'new' order by id limit least(greatest(p_n, 1), 50)) x;
$$;

-- [{id, severity, reason, by: rules/claude}]. Regressions move one level up; volume floors apply. Each new S1
-- alerts the watchers once.
create or replace function public.bug_triage_record(p jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  r jsonb;
  b t1_private.bugs;
  v_rank integer;
  v_n integer := 0;
begin
  for r in select * from jsonb_array_elements(coalesce(p, '[]')) loop
    select * into b from t1_private.bugs where id = (r->>'id')::bigint and status = 'new' for update;
    continue when b.id is null or coalesce(r->>'severity', '') not in ('S1', 'S2', 'S3', 'S4');
    v_rank := t1_private.bug_rank(r->>'severity');
    if b.regressed then v_rank := v_rank - 1; end if;
    if b.users >= 25 or b.spikes >= 2 then v_rank := least(v_rank, 1);
    elsif b.users >= 5 or b.spikes >= 1 then v_rank := least(v_rank, 2); end if;
    update t1_private.bugs set
      severity = t1_private.bug_sev(v_rank),
      severity_reason = left(case when b.regressed then 'Came back after a shipped fix. ' else '' end || coalesce(r->>'reason', ''), 500),
      severity_by = case when r->>'by' in ('rules', 'claude') then r->>'by' else 'claude' end,
      status = 'open',
      updated_at = now()
    where id = b.id;
    perform t1_private.bug_alert(b.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Push the watchers about an S1 once (title only; the details stay here).
create or replace function t1_private.bug_alert(p_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare b t1_private.bugs;
begin
  select * into b from t1_private.bugs where id = p_id;
  if b.id is null or b.severity <> 'S1' or b.notified_at is not null or b.status not in ('open', 'fixing') then return; end if;
  update t1_private.bugs set notified_at = now() where id = p_id;
  perform public.enqueue_notification('ops.bug', null, t1_private.bug_watcher_ids(),
    jsonb_build_object('bug_id', b.id, 'severity', b.severity, 'platform', b.platform,
                       'title', left(b.title, 120), 'regressed', b.regressed));
end $$;

-- ==================================================================== e_runner
-- The most severe open bug at or above p_max ('S1' = S1 only, 'S4' = anything), claimed for p_runner.
-- A claim older than 3 hours is stale (the run died) and can be taken again; three tries and it goes to John.
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
  return to_jsonb(b) - 'notified_at';
end $$;

-- The runner's outcome for a claimed bug:
--   {outcome: 'fixed', commit, summary, test, platforms: [ios|android|web|server]}
--   {outcome: 'release', notes}        back in the queue (e.g. ran out of time)
--   {outcome: 'needs_john', notes}     needs a decision, a device, or access the runner doesn't have
--   {outcome: 'wontfix', notes}        noise, expected, or not ours
--   {outcome: 'duplicate', of}         the same problem as another bug
create or replace function public.bug_done(p_id bigint, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b t1_private.bugs;
  v_out text := p->>'outcome';
  v_platforms text[];
begin
  select * into b from t1_private.bugs where id = p_id for update;
  if b.id is null then raise exception 'No such bug' using errcode = 'P0002'; end if;
  if v_out = 'fixed' then
    select coalesce(array_agg(distinct x order by x), '{}') into v_platforms from jsonb_array_elements_text(coalesce(p->'platforms', '[]')) x;
    if coalesce(p->>'commit', '') = '' or cardinality(v_platforms) = 0
       or not v_platforms <@ array['ios', 'android', 'web', 'server'] then
      raise exception 'A fix needs a commit and the platforms it ships on' using errcode = '22023';
    end if;
    update t1_private.bugs set status = 'fixed', fix_commit = p->>'commit', fix_summary = left(p->>'summary', 2000),
      fix_test = left(p->>'test', 500), fix_platforms = v_platforms, fixed_at = now(), shipped = '{}',
      regressed = false, claimed_by = null, notes = coalesce(nullif(p->>'notes', ''), notes), updated_at = now()
    where id = p_id;
  elsif v_out in ('release', 'needs_john', 'wontfix') then
    update t1_private.bugs set status = case v_out when 'release' then 'open' else v_out end, claimed_by = null,
      notes = left(coalesce(notes || E'\n', '') || coalesce(p->>'notes', ''), 4000), updated_at = now()
    where id = p_id;
  elsif v_out = 'duplicate' then
    if not exists (select 1 from t1_private.bugs where id = (p->>'of')::bigint and id <> p_id) then
      raise exception 'Duplicate of what?' using errcode = '22023';
    end if;
    update t1_private.bugs set status = 'duplicate', duplicate_of = (p->>'of')::bigint, claimed_by = null, updated_at = now()
    where id = p_id;
  else
    raise exception 'Unknown outcome %', v_out using errcode = '22023';
  end if;
  return public.bug_build_check();
end $$;

-- John's overrides: {severity, status (open / wontfix / needs_john), notes}.
create or replace function public.bug_set(p_id bigint, p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p ? 'severity' and p->>'severity' not in ('S1', 'S2', 'S3', 'S4') then raise exception 'Bad severity' using errcode = '22023'; end if;
  if p ? 'status' and p->>'status' not in ('open', 'wontfix', 'needs_john') then raise exception 'Bad status' using errcode = '22023'; end if;
  update t1_private.bugs set
    severity = coalesce(p->>'severity', severity),
    severity_by = case when p ? 'severity' then 'john' else severity_by end,
    severity_reason = case when p ? 'severity' then 'Set by John' else severity_reason end,
    status = coalesce(p->>'status', status),
    attempts = case when p->>'status' = 'open' then 0 else attempts end,
    claimed_by = case when p ? 'status' then null else claimed_by end,
    notes = case when p ? 'notes' then left(coalesce(notes || E'\n', '') || (p->>'notes'), 4000) else notes end,
    updated_at = now()
  where id = p_id;
  if not found then raise exception 'No such bug' using errcode = 'P0002'; end if;
end $$;

-- A build (or a server deploy) went out: its platform's pending fixes are shipped. p_ids limits it to the fixes
-- the shipped commit contains (the runner checks git ancestry); null = all pending on that platform.
create or replace function public.bug_shipped(p_platform text, p_version text default null, p_ids bigint[] default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_ids bigint[];
begin
  if p_platform not in ('ios', 'android', 'web', 'server') then raise exception 'Bad platform' using errcode = '22023'; end if;
  with s as (
    update t1_private.bugs set shipped = shipped || p_platform, updated_at = now()
     where status = 'fixed' and p_platform = any (fix_platforms) and not p_platform = any (shipped)
       and (p_ids is null or id = any (p_ids))
    returning id)
  select coalesce(array_agg(id order by id), '{}') into v_ids from s;
  insert into t1_private.bug_ships (platform, version, bug_ids) values (p_platform, p_version, v_ids);
  update t1_private.bug_state set build_notice = null where id = 1;
  return jsonb_build_object('platform', p_platform, 'shipped', to_jsonb(v_ids));
end $$;

-- ==================================================================== f_status
-- Per platform, the fixes merged but not shipped, and whether that calls for a build now:
-- any S1 or S2, five or more fixes, or the oldest waiting a week.
create or replace function t1_private.bug_pending()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'platform', p.platform, 'fixes', p.fixes, 'worst', p.worst, 'oldest', p.oldest, 'ids', to_jsonb(p.ids),
      'due', p.worst in ('S1', 'S2') or p.fixes >= 5 or p.oldest < now() - interval '7 days')
    order by array_position(array['ios', 'web', 'android', 'server'], p.platform)), '[]')
  from (
    select x.platform, count(*)::integer fixes, t1_private.bug_sev(min(t1_private.bug_rank(b.severity))) worst,
           min(b.fixed_at) oldest, array_agg(b.id order by b.id) ids
      from t1_private.bugs b, unnest(b.fix_platforms) x(platform)
     where b.status = 'fixed' and not x.platform = any (b.shipped)
     group by x.platform) p;
$$;

create or replace function public.bug_status()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'open', (select coalesce(jsonb_object_agg(s, n), '{}') from (
               select coalesce(severity, 'untriaged') s, count(*) n from t1_private.bugs
                where status in ('new', 'open', 'fixing') group by 1) x),
    'open_s1', (select count(*) from t1_private.bugs where status = 'open' and severity = 'S1'),
    'open_total', (select count(*) from t1_private.bugs where status = 'open'),
    'fixing', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'severity', severity, 'title', title, 'claimed_by', claimed_by, 'claimed_at', claimed_at)), '[]')
                 from t1_private.bugs where status = 'fixing'),
    'needs_john', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'severity', severity, 'platform', platform, 'title', title, 'notes', notes) order by t1_private.bug_rank(severity), id), '[]')
                     from t1_private.bugs where status = 'needs_john'),
    'pending', t1_private.bug_pending());
$$;

create or replace function public.bug_get(p_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(b) from t1_private.bugs b where b.id = p_id;
$$;

-- The register, most urgent first: status filter (null = everything not closed), newest activity within a severity.
create or replace function public.bug_list(p_status text[] default null, p_limit integer default 50)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by t1_private.bug_rank(x->>'severity'), x->>'last_seen' desc), '[]') from (
    select jsonb_build_object('id', id, 'severity', severity, 'status', status, 'platform', platform, 'title', title,
             'events', events, 'users', users, 'regressed', regressed, 'last_seen', last_seen, 'fix_commit', fix_commit,
             'fix_platforms', fix_platforms, 'shipped', shipped, 'link', link) x
      from t1_private.bugs
     where case when p_status is null then status not in ('wontfix', 'duplicate') and not (status = 'fixed' and fix_platforms <@ shipped)
                else status = any (p_status) end
     order by last_seen desc limit least(greatest(p_limit, 1), 500)) y;
$$;

-- Pushes the watchers when the set of platforms that need a build changes, and again daily while it stands.
-- Returns the pending summary either way.
create or replace function public.bug_build_check()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_pending jsonb := t1_private.bug_pending();
  v_due jsonb;
  v_text text;
  st t1_private.bug_state;
begin
  select coalesce(jsonb_agg(e), '[]') into v_due from jsonb_array_elements(v_pending) e where (e->>'due')::boolean;
  select string_agg(case e->>'platform' when 'ios' then 'iOS' when 'web' then 'web' when 'android' then 'Android' else 'server' end
                    || ' ' || (e->>'fixes') || ' (' || (e->>'worst') || ')', ', ')
    into v_text from jsonb_array_elements(v_due) e;
  select * into st from t1_private.bug_state where id = 1 for update;
  if v_text is not null and (v_text is distinct from st.build_notice or st.build_notice_at < now() - interval '24 hours') then
    update t1_private.bug_state set build_notice = v_text, build_notice_at = now() where id = 1;
    perform public.enqueue_notification('ops.build', null, t1_private.bug_watcher_ids(),
      jsonb_build_object('summary', v_text, 'platforms', (select jsonb_agg(e->>'platform') from jsonb_array_elements(v_due) e),
                         'server', exists (select 1 from jsonb_array_elements(v_due) e where e->>'platform' = 'server')));
  elsif v_text is null and st.build_notice is not null then
    update t1_private.bug_state set build_notice = null where id = 1;
  end if;
  return jsonb_build_object('pending', v_pending, 'due', v_due);
end $$;

-- ==================================================================== g_server_sweep
-- The server's own failures, which no client sees: cron jobs that failed, and pg_net calls (the database kicking
-- edge functions) that answered 5xx, timed out or never connected. Returns how many occurrences were filed.
create or replace function t1_private.bugs_sweep_server()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  st t1_private.bug_state;
  r record;
  v_n integer := 0;
  v_cron_to timestamptz;
  v_net_to bigint;
begin
  select * into st from t1_private.bug_state where id = 1 for update;
  v_cron_to := st.cron_swept_to; v_net_to := st.net_swept_to;
  for r in
    select j.jobname, t1_private.bug_normalize(d.return_message) norm, max(d.return_message) msg,
           count(*) n, max(d.start_time) at
      from cron.job_run_details d join cron.job j on j.jobid = d.jobid
     where d.status = 'failed' and d.start_time > st.cron_swept_to
     group by 1, 2 loop
    perform public.bug_report(jsonb_build_object(
      'fingerprint', 'cron:' || r.jobname || ':' || left(md5(r.norm), 12), 'source', 'server', 'platform', 'server',
      'title', 'Cron job ' || r.jobname || ' failed: ' || left(coalesce(r.msg, 'no message'), 200),
      'culprit', r.jobname, 'level', 'error', 'environment', 'production', 'events', r.n, 'seen_at', r.at,
      'detail', jsonb_build_object('kind', 'cron', 'job', r.jobname, 'message', left(r.msg, 2000))));
    v_n := v_n + r.n;
    v_cron_to := greatest(v_cron_to, r.at);
  end loop;
  for r in
    select coalesce(h.status_code, 0) code, h.timed_out, t1_private.bug_normalize(coalesce(h.error_msg, h.content)) norm,
           max(left(coalesce(h.error_msg, h.content), 2000)) msg, count(*) n, max(h.created) at, max(h.id) last_id
      from net._http_response h
     where h.id > st.net_swept_to and (h.status_code >= 500 or h.timed_out or h.error_msg is not null)
     group by 1, 2, 3 loop
    perform public.bug_report(jsonb_build_object(
      'fingerprint', 'net:' || r.code || ':' || left(md5(coalesce(r.timed_out::text, '') || r.norm), 12),
      'source', 'server', 'platform', 'server',
      'title', 'Background call failed (' || case when r.timed_out then 'timed out' when r.code = 0 then 'no response'
               else 'HTTP ' || r.code end || '): ' || left(coalesce(r.msg, ''), 200),
      'level', 'error', 'environment', 'production', 'events', r.n, 'seen_at', r.at,
      'detail', jsonb_build_object('kind', 'pg_net', 'status', r.code, 'timed_out', r.timed_out, 'message', r.msg)));
    v_n := v_n + r.n;
  end loop;
  select greatest(st.net_swept_to, coalesce(max(id), 0)) into v_net_to from net._http_response;
  update t1_private.bug_state set cron_swept_to = v_cron_to, net_swept_to = v_net_to where id = 1;
  return v_n;
end $$;

create or replace function t1_private.bugs_kick()
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  select value into v_secret from t1_private.settings where name = 'live_push_secret';
  perform net.http_post(
    url := 'https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/bugs',
    body := '{"action": "triage"}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-t1-secret', v_secret),
    timeout_milliseconds := 30000);
exception when others then
  raise warning 'bugs_kick skipped: %', sqlerrm;
end $$;

-- Every 10 minutes: file the server's failures, triage anything new, and re-check builds (the daily reminder).
create or replace function t1_private.bugs_tick()
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform t1_private.bugs_sweep_server();
  if exists (select 1 from t1_private.bugs where status = 'new') then perform t1_private.bugs_kick(); end if;
  perform public.bug_build_check();
end $$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 't1-bugs-tick') then
      perform cron.schedule('t1-bugs-tick', '*/10 * * * *', 'select t1_private.bugs_tick()');
    end if;
  end if;
end $$;

-- ==================================================================== h_grants
do $$
declare f text;
begin
  foreach f in array array[
    'public.bug_runner_ok(text)', 'public.bug_setting(text)', 'public.bug_setting_set(text, text)',
    'public.bug_report(jsonb)', 'public.bug_triage_claim(integer)', 'public.bug_triage_record(jsonb)',
    'public.bug_next(text, text)', 'public.bug_done(bigint, jsonb)', 'public.bug_set(bigint, jsonb)',
    'public.bug_shipped(text, text, bigint[])', 'public.bug_status()', 'public.bug_build_check()',
    'public.bug_get(bigint)', 'public.bug_list(text[], integer)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array[
    't1_private.bug_watcher_ids()', 't1_private.bug_alert(bigint)', 't1_private.bug_pending()',
    't1_private.bugs_sweep_server()', 't1_private.bugs_kick()', 't1_private.bugs_tick()'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;
