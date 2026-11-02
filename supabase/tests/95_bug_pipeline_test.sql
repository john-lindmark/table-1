-- Bug pipeline (contract/bug-pipeline-2026-10-18.md): intake and grouping, debug ignored, triage with regression
-- and volume floors, S1 pushes once, the runner's claim/outcomes (idempotent, stale claims, three tries), shipping
-- per platform and build-needed pushes, the server sweep, and that nobody but the service role can call any of it.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000000f1', 'ops@example.com', '{"full_name": "Ops Person"}');
insert into t1_private.bug_watchers (user_id, note) values ('00000000-0000-0000-0000-0000000000f1', 'test');
insert into public.devices (user_id, platform, push_token) values ('00000000-0000-0000-0000-0000000000f1', 'ios', 'tok-ops');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''

create or replace function pg_temp.rep(p_fp text, p_extra jsonb default '{}') returns jsonb language sql as $$
  select public.bug_report(jsonb_build_object('fingerprint', p_fp, 'source', 'sentry', 'platform', 'ios',
    'title', 'Crash in ' || p_fp, 'level', 'error', 'environment', 'production', 'release', 'site.table1.events@1.0+7') || p_extra) $$;
create or replace function pg_temp.bug(p_fp text) returns t1_private.bugs language sql as $$
  select * from t1_private.bugs where fingerprint = p_fp $$;
create or replace function pg_temp.pushes(p_kind text) returns text language sql as $$
  select count(*)::text from pgmq.messages where msg->>'kind' = p_kind $$;
create or replace function pg_temp.triage(p_fp text, p_sev text) returns integer language sql as $$
  select public.bug_triage_record(jsonb_build_array(jsonb_build_object('id', (pg_temp.bug(p_fp)).id, 'severity', p_sev, 'reason', 'test', 'by', 'claude'))) $$;

-- Permissions ---------------------------------------------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.throws('a signed-in client cannot file bugs', $$select public.bug_report('{"fingerprint": "x", "title": "x"}')$$, '42501');
select pg_temp.throws('or read the queue', $$select public.bug_status()$$, '42501');
select pg_temp.throws('or claim one', $$select public.bug_next('S4', 'me')$$, '42501');
select pg_temp.throws('or mark builds shipped', $$select public.bug_shipped('ios')$$, '42501');
select pg_temp.throws('or read the table', $$select count(*) from t1_private.bugs$$, '42501');
reset role;
set role anon;
select pg_temp.throws('anon cannot file bugs', $$select public.bug_report('{"fingerprint": "x", "title": "x"}')$$, '42501');
reset role;

-- Runner secret ---------------------------------------------------------------------------------------------
reset role;
insert into t1_private.settings (name, value) values ('bug_runner_secret_sha256', encode(sha256(convert_to('s3cret', 'UTF8')), 'hex'));
set role service_role;
select pg_temp.eq('the service role can call the pipeline', (public.bug_status() ? 'pending')::text, 'true');
select pg_temp.eq('runner secret checks', (public.bug_runner_ok('s3cret') and not public.bug_runner_ok('nope') and not public.bug_runner_ok(''))::text, 'true');
select pg_temp.eq('only the Sentry secret is readable', coalesce(public.bug_setting('bug_runner_secret_sha256'), 'none'), 'none');
select public.bug_setting_set('sentry_client_secret', 'abc');
select pg_temp.eq('Sentry secret set and read', public.bug_setting('sentry_client_secret'), 'abc');
select pg_temp.throws('no other settings writable', $$select public.bug_setting_set('live_push_secret', 'x')$$, '22023');
reset role;   -- the rest reads t1_private directly to check results

-- Intake ----------------------------------------------------------------------------------------------------
select pg_temp.eq('first report creates', (pg_temp.rep('sentry:1')->>'created'), 'true');
select pg_temp.eq('second groups', (pg_temp.rep('sentry:1', '{"release": "site.table1.events@1.0+8", "users": 3}')->>'created'), 'false');
select pg_temp.eq('counts, releases, users',
  (select events || ' ' || array_to_string(releases, ',') || ' ' || users || ' ' || status from t1_private.bugs where fingerprint = 'sentry:1'),
  '2 site.table1.events@1.0+7,site.table1.events@1.0+8 3 new');
select pg_temp.eq('debug builds never count', coalesce(pg_temp.rep('sentry:dbg', '{"environment": "debug"}')::text, 'ignored'), 'ignored');
select pg_temp.eq('dev neither', coalesce(pg_temp.rep('sentry:dbg', '{"environment": "dev"}')::text, 'ignored'), 'ignored');
select pg_temp.throws('fingerprint required', $$select public.bug_report('{"title": "x"}')$$, '22023');
select pg_temp.eq('a fatal stays fatal', (pg_temp.rep('sentry:1', '{"level": "fatal"}') is not null and (pg_temp.bug('sentry:1')).level = 'fatal'
  and pg_temp.rep('sentry:1', '{"level": "error"}') is not null and (pg_temp.bug('sentry:1')).level = 'fatal')::text, 'true');

-- Triage ----------------------------------------------------------------------------------------------------
select pg_temp.rep('sentry:2', '{"platform": "web"}');
select pg_temp.rep('sentry:3', '{"platform": "android"}');
select pg_temp.eq('triage claims new bugs', (select string_agg(x->>'title', ',' order by (x->>'id')::bigint) from jsonb_array_elements(public.bug_triage_claim(10)) x),
  'Crash in sentry:1,Crash in sentry:2,Crash in sentry:3');
select pg_temp.eq('claim carries no fix fields', (select count(*)::text from jsonb_array_elements(public.bug_triage_claim(1)) x where x ? 'fix_commit' or x ? 'notes'), '0');
select pg_temp.triage('sentry:1', 'S3');
select pg_temp.triage('sentry:2', 'S1');
select pg_temp.triage('sentry:3', 'S4');
select pg_temp.eq('severities recorded, open', (select string_agg(fingerprint || '=' || severity || '/' || status, ',' order by id) from t1_private.bugs),
  'sentry:1=S3/open,sentry:2=S1/open,sentry:3=S4/open');
select pg_temp.eq('an S1 pushes the watchers once', pg_temp.pushes('ops.bug'), '1');
select pg_temp.eq('push says what and where, nothing else',
  (select string_agg(k, ',' order by k) from pgmq.messages, jsonb_object_keys(msg->'data') k where msg->>'kind' = 'ops.bug'),
  'bug_id,platform,regressed,severity,title');
select pg_temp.eq('triage only touches new bugs', pg_temp.triage('sentry:3', 'S1')::text, '0');
select pg_temp.eq('bad severity ignored', (select public.bug_triage_record('[{"id": 1, "severity": "S9"}]'))::text, '0');

-- Volume: 5 people → S2, 25 → S1 (and that pushes).
select pg_temp.rep('sentry:3', '{"platform": "android", "users": 5}');
select pg_temp.eq('5 people make an S4 an S2', (pg_temp.bug('sentry:3')).severity || ' ' || (pg_temp.bug('sentry:3')).severity_by, 'S2 rules');
select pg_temp.rep('sentry:3', '{"platform": "android", "users": 25}');
select pg_temp.eq('25 make it an S1, which pushes', (pg_temp.bug('sentry:3')).severity || ' ' || pg_temp.pushes('ops.bug'), 'S1 2');
select pg_temp.rep('sentry:4', '{"spike": true}');
select pg_temp.triage('sentry:4', 'S4');
select pg_temp.eq('a spike floors new bugs at S2', (pg_temp.bug('sentry:4')).severity, 'S2');

-- Runner ----------------------------------------------------------------------------------------------------
select pg_temp.eq('S1 only takes the most severe, most people first', (public.bug_next('S1', 'run-a')->>'fingerprint'), 'sentry:3');
select pg_temp.eq('then the other S1', (public.bug_next('S1', 'run-a')->>'fingerprint'), 'sentry:2');
select pg_temp.eq('no S1 left', coalesce(public.bug_next('S1', 'run-a')::text, 'none'), 'none');
select pg_temp.eq('claims are marked', (select string_agg(status || ':' || claimed_by || ':' || attempts, ',' order by id) from t1_private.bugs where status = 'fixing'),
  'fixing:run-a:1,fixing:run-a:1');
select pg_temp.eq('status shows what is being fixed', jsonb_array_length(public.bug_status()->'fixing')::text, '2');

select pg_temp.throws('a fix needs a commit', $$select public.bug_done((pg_temp.bug('sentry:2')).id, '{"outcome": "fixed", "platforms": ["web"]}')$$, '22023');
select pg_temp.throws('and real platforms', $$select public.bug_done((pg_temp.bug('sentry:2')).id, '{"outcome": "fixed", "commit": "abc", "platforms": ["tv"]}')$$, '22023');
select pg_temp.throws('unknown outcome', $$select public.bug_done((pg_temp.bug('sentry:2')).id, '{"outcome": "maybe"}')$$, '22023');
select public.bug_done((pg_temp.bug('sentry:2')).id, '{"outcome": "fixed", "commit": "abc123", "summary": "Guard nil deck", "test": "deckStats.test.ts", "platforms": ["web", "server", "web"]}');
select pg_temp.eq('fixed with its platforms (deduped)', (select status || ' ' || array_to_string(fix_platforms, ',') from t1_private.bugs where fingerprint = 'sentry:2'), 'fixed server,web');
select pg_temp.eq('an S1 fix calls for a web build and a server deploy at once',
  pg_temp.pushes('ops.build') || ' ' || (select msg->'data'->>'summary' from pgmq.messages where msg->>'kind' = 'ops.build' order by msg_id desc limit 1),
  '1 web 1 (S1), server 1 (S1)');
select public.bug_build_check();
select pg_temp.eq('the same summary does not push again', pg_temp.pushes('ops.build'), '1');
select pg_temp.eq('retrying the same outcome is safe',
  (public.bug_done((pg_temp.bug('sentry:2')).id, '{"outcome": "fixed", "commit": "abc123", "platforms": ["web", "server"]}') is not null
   and pg_temp.pushes('ops.build') = '1')::text, 'true');

select public.bug_done((pg_temp.bug('sentry:3')).id, '{"outcome": "release", "notes": "ran out of time"}');
select pg_temp.eq('released goes back to the queue', (pg_temp.bug('sentry:3')).status || ' ' || (pg_temp.bug('sentry:3')).notes, 'open ran out of time');
-- A claim the run never finished frees itself after 3 hours; the third stale try goes to John.
select public.bug_next('S1', 'run-b');
update t1_private.bugs set claimed_at = now() - interval '4 hours' where fingerprint = 'sentry:3';
select pg_temp.eq('a stale claim is taken again', (public.bug_next('S1', 'run-c')->>'attempts'), '3');
update t1_private.bugs set claimed_at = now() - interval '4 hours' where fingerprint = 'sentry:3';
select pg_temp.eq('three tries and it is John''s', coalesce(public.bug_next('S1', 'run-d')::text, 'none') || ' ' || (pg_temp.bug('sentry:3')).status, 'none needs_john');
select pg_temp.eq('status lists it for John', (public.bug_status()->'needs_john'->0->>'title'), 'Crash in sentry:3');
select public.bug_set((pg_temp.bug('sentry:3')).id, '{"status": "open", "severity": "S2", "notes": "Try again with the logs"}');
select pg_temp.eq('John can put it back with a new severity', (select status || ' ' || severity || ' ' || severity_by || ' ' || attempts from t1_private.bugs where fingerprint = 'sentry:3'), 'open S2 john 0');
select pg_temp.throws('John cannot mark fixed by hand', $$select public.bug_set((pg_temp.bug('sentry:3')).id, '{"status": "fixed"}')$$, '22023');

select public.bug_done((pg_temp.bug('sentry:4')).id, '{"outcome": "duplicate", "of": 1}');
select pg_temp.throws('not a duplicate of itself', $$select public.bug_done((pg_temp.bug('sentry:1')).id, jsonb_build_object('outcome', 'duplicate', 'of', (pg_temp.bug('sentry:1')).id))$$, '22023');
select pg_temp.eq('duplicate recorded', (pg_temp.bug('sentry:4')).status || ' ' || (pg_temp.bug('sentry:4')).duplicate_of, 'duplicate 1');

-- Shipping and regressions ----------------------------------------------------------------------------------
select pg_temp.rep('sentry:2', '{"platform": "web"}');
select pg_temp.eq('more events before the fix ships do not reopen', (pg_temp.bug('sentry:2')).status, 'fixed');
select pg_temp.eq('pending per platform', (select string_agg((e->>'platform') || ':' || (e->>'fixes') || ':' || (e->>'due'), ',') from jsonb_array_elements(public.bug_status()->'pending') e),
  'web:1:true,server:1:true');
select pg_temp.eq('shipping web', (public.bug_shipped('web', '2026.10.18')->>'shipped'), '[2]');
select pg_temp.eq('server still pending', (select string_agg(e->>'platform', ',') from jsonb_array_elements(public.bug_status()->'pending') e), 'server');
select pg_temp.eq('shipping again is a no-op', (public.bug_shipped('web')->>'shipped'), '[]');
select pg_temp.eq('ships are logged', (select count(*)::text from t1_private.bug_ships), '2');
select pg_temp.rep('sentry:2', '{"platform": "web"}');
select pg_temp.eq('back after a shipped fix: reopened as new', (pg_temp.bug('sentry:2')).status || ' ' || (pg_temp.bug('sentry:2')).regressed, 'new true');
select pg_temp.triage('sentry:2', 'S3');
select pg_temp.eq('a regression is one level more urgent', (pg_temp.bug('sentry:2')).severity || ' ' || (pg_temp.bug('sentry:2')).severity_reason, 'S2 Came back after a shipped fix. test');
select pg_temp.eq('bug_shipped limited to ids', (select public.bug_shipped('server', null, array[999::bigint])->>'shipped'), '[]');

-- Builds: five low fixes on one platform are due; one S4 is not.
select pg_temp.rep('sentry:low' || g, '{"platform": "android"}') from generate_series(1, 5) g;
select pg_temp.triage('sentry:low' || g, 'S4') from generate_series(1, 5) g;
-- Fix n of the Android S4s; anything more severe the queue hands out first is set aside as wontfix.
create or replace function pg_temp.fix_low(p_n int) returns void language plpgsql as $$
declare v jsonb; n int := 0;
begin
  while n < p_n loop
    v := public.bug_next('S4', 'run-e');
    exit when v is null;
    if v->>'severity' = 'S4' and v->>'platform' = 'android' then
      perform public.bug_done((v->>'id')::bigint, '{"outcome": "fixed", "commit": "c1", "platforms": ["android"]}'); n := n + 1;
    else
      perform public.bug_done((v->>'id')::bigint, '{"outcome": "wontfix", "notes": "test"}');
    end if;
  end loop;
end $$;
select pg_temp.fix_low(2);
select pg_temp.eq('two S4 Android fixes are not a build yet',
  (select (e->>'due') from jsonb_array_elements(public.bug_status()->'pending') e where e->>'platform' = 'android'), 'false');
select pg_temp.fix_low(3);
select pg_temp.eq('five are', (select (e->>'fixes') || ':' || (e->>'due') from jsonb_array_elements(public.bug_status()->'pending') e where e->>'platform' = 'android'), '5:true');
select pg_temp.eq('and that pushes with the new summary',
  (select msg->'data'->>'summary' from pgmq.messages where msg->>'kind' = 'ops.build' order by msg_id desc limit 1), 'Android 5 (S4)');  -- the server fix reopened above and was set aside

select pg_temp.eq('the register hides closed and fully shipped bugs',
  (select count(*)::text from jsonb_array_elements(public.bug_list()) x where x->>'status' in ('wontfix', 'duplicate')), '0');
select pg_temp.eq('and lists by status', (select string_agg(distinct x->>'status', ',') from jsonb_array_elements(public.bug_list(array['fixed'])) x), 'fixed');
select pg_temp.eq('get returns the whole row', (public.bug_get((pg_temp.bug('sentry:1')).id) ? 'detail')::text, 'true');

-- Server sweep ------------------------------------------------------------------------------------------------
update t1_private.bug_state set cron_swept_to = now() - interval '1 hour';
insert into cron.job (jobname, schedule, command) values ('t1-cards-sync', '0 4 * * *', 'select 1');
insert into cron.job_run_details (jobid, status, return_message, start_time)
select jobid, 'failed', 'ERROR: canceling statement due to statement timeout (after ' || g || ' ms)', now() - interval '5 minutes'
  from cron.job, generate_series(1, 3) g where jobname = 't1-cards-sync';
insert into cron.job_run_details (jobid, status, return_message, start_time)
select jobid, 'succeeded', '1 row', now() from cron.job where jobname = 't1-cards-sync';
insert into net._http_response (id, status_code, content, timed_out, error_msg, created) values
  (1, 200, 'ok', false, null, now() - interval '5 minutes'), (2, 500, '{"error":"boom 42"}', false, null, now() - interval '5 minutes'),
  (3, 500, '{"error":"boom 43"}', false, null, now() - interval '5 minutes'),
  (4, null, null, true, 'Timeout of 30000 ms reached', now() - interval '5 minutes');
select pg_temp.eq('sweep files failed cron runs and failed calls', t1_private.bugs_sweep_server()::text, '6');
select pg_temp.eq('grouped by job and message', (select string_agg(left(title, 34) || ' x' || events, ' | ' order by title) from t1_private.bugs where source = 'server'),
  'Background call failed (HTTP 500): x2 | Background call failed (timed out) x1 | Cron job t1-cards-sync failed: ERR x3');
select pg_temp.eq('sweeping again files nothing new', t1_private.bugs_sweep_server()::text, '0');
select pg_temp.eq('server bugs are platform server', (select string_agg(distinct platform, ',') from t1_private.bugs where source = 'server'), 'server');
select t1_private.bugs_tick();
select pg_temp.eq('the tick kicks triage when bugs are new', (select count(*)::text from net.requests where url like '%/functions/v1/bugs'), '1');

-- Account deletion removes a watcher.
delete from auth.users where id = '00000000-0000-0000-0000-0000000000f1';
select pg_temp.eq('deleted accounts stop watching', (select count(*)::text from t1_private.bug_watchers), '0');
