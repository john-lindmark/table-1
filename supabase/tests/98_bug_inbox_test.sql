-- Bug inbox (contract/bug-pipeline-2026-10-18.md § Inbox): only watchers read or change bugs from the app, their
-- changes and notes are logged, retries don't double up, the runner sees John's notes, a bug being fixed keeps its
-- status, shipping from the app is idempotent, and ops pushes reach watchers only.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000000f1', 'ops@example.com', '{"full_name": "Ops Person"}');
insert into t1_private.bug_watchers (user_id, note) values ('00000000-0000-0000-0000-0000000000f1', 'test');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set OPS '''00000000-0000-0000-0000-0000000000f1'''

insert into t1_private.bugs (fingerprint, source, platform, title, severity, status, notes) values
  ('manual:1', 'manual', 'ios', 'Crash on standings', 'S2', 'open', null),
  ('manual:2', 'manual', 'ios', 'App hang at launch', 'S4', 'needs_john', E'Found nothing.\nQuestion: add dSYM upload?\n'),
  ('manual:3', 'manual', 'web', 'Old noise', 'S4', 'wontfix', null),
  ('manual:4', 'manual', 'ios', 'Being fixed', 'S3', 'fixing', null),
  ('manual:5', 'manual', 'ios', 'Untriaged', null, 'needs_john', null);
insert into t1_private.bugs (fingerprint, source, platform, title, severity, status, fix_commit, fix_platforms, fixed_at)
values ('manual:6', 'manual', 'ios', 'Fixed, waiting', 'S2', 'fixed', 'abc123', '{ios,server}', now());
select max(id) filter (where fingerprint = 'manual:1') b1, max(id) filter (where fingerprint = 'manual:2') b2,
       max(id) filter (where fingerprint = 'manual:4') b4, max(id) filter (where fingerprint = 'manual:5') b5,
       max(id) filter (where fingerprint = 'manual:6') b6 from t1_private.bugs \gset

-- Not a watcher ---------------------------------------------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('anyone else is told only that they aren''t a watcher', public.bugs_me()::text, '{"watcher": false}');
select pg_temp.throws('and can''t read the inbox', $$select public.bugs_inbox()$$, '42501');
select pg_temp.throws('or a bug', format('select public.bugs_detail(%s)', :b1), '42501');
select pg_temp.throws('or change one', format($q$select public.bugs_update(%s, '{"severity": "S1"}')$q$, :b1), '42501');
select pg_temp.throws('or mark builds shipped', $$select public.bugs_ship('ios')$$, '42501');
select pg_temp.throws('or ask who watches', $$select public.notify_ops_recipients(array[auth.uid()])$$, '42501');
select pg_temp.as_user(null);
reset role;
set role anon;
select pg_temp.throws('signed out cannot call it at all', $$select public.bugs_me()$$, '42501');
reset role;

-- A watcher ---------------------------------------------------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:OPS);
select pg_temp.eq('the watcher sees counts', (public.bugs_me() - 'watcher')::text, '{"open": 2, "to_ship": 2, "needs_you": 2}');
select pg_temp.eq('the inbox holds what isn''t settled, most urgent first',
  (select string_agg(x->>'title', ' | ' order by n) from jsonb_array_elements(public.bugs_inbox()->'bugs') with ordinality t(x, n)),
  'Fixed, waiting | Crash on standings | Being fixed | App hang at launch | Untriaged');
select pg_temp.eq('closed ones on request', (jsonb_array_length(public.bugs_inbox(true)->'bugs'))::text, '6');
select pg_temp.eq('a row carries the runner''s last line',
  (select x->>'last_note' from jsonb_array_elements(public.bugs_inbox()->'bugs') x where x->>'title' = 'App hang at launch'),
  'Question: add dSYM upload?');
select pg_temp.eq('pending per platform', (select string_agg(e->>'platform', ',') from jsonb_array_elements(public.bugs_inbox()->'pending') e), 'ios,server');
select pg_temp.eq('detail without the fingerprint', (public.bugs_detail(:b1) ? 'fingerprint')::text, 'false');

select public.bugs_update(:b1, '{"severity": "S1", "note": "Seen at FNM too", "key": "11111111-1111-1111-1111-111111111111"}');
select pg_temp.eq('severity changes and both are logged',
  (select (d->>'severity') || ' ' || (d->>'severity_by') || ' | ' || (select string_agg((l->>'kind') || ':' || (l->>'body'), ' / ') from jsonb_array_elements(d->'log') l)
     from (select public.bugs_detail(:b1) d) t),
  'S1 john | change:Severity S2 → S1 / note:Seen at FNM too');
select pg_temp.eq('a retry with the same key changes nothing', jsonb_array_length(public.bugs_detail(:b1)->'log')::text, '2');
select public.bugs_update(:b1, '{"severity": "S1"}');
select pg_temp.eq('an unchanged severity logs nothing', jsonb_array_length(public.bugs_detail(:b1)->'log')::text, '2');
select pg_temp.eq('the detail shows the log', (jsonb_array_length(public.bugs_detail(:b1)->'log'))::text, '2');

select public.bugs_update(:b2, '{"status": "open", "note": "Yes, add the upload step", "key": "22222222-2222-2222-2222-222222222222"}');
select pg_temp.eq('answering sends it back to the runner', public.bugs_detail(:b2)->>'status', 'open');
select pg_temp.throws('a bug being fixed keeps its status', format($q$select public.bugs_update(%s, '{"status": "wontfix"}')$q$, :b4), 'PT409');
select public.bugs_update(:b4, '{"note": "Check Android too"}');
select pg_temp.eq('but takes notes', jsonb_array_length(public.bugs_detail(:b4)->'log')::text, '1');
select pg_temp.throws('a bug needs a severity before the runner gets it', format($q$select public.bugs_update(%s, '{"status": "open"}')$q$, :b5), '22023');
select pg_temp.throws('bad severity', format($q$select public.bugs_update(%s, '{"severity": "S0"}')$q$, :b1), '22023');
select pg_temp.throws('bad status', format($q$select public.bugs_update(%s, '{"status": "fixed"}')$q$, :b1), '22023');
select pg_temp.throws('bad key', format($q$select public.bugs_update(%s, '{"note": "x", "key": "nope"}')$q$, :b1), '22023');
select pg_temp.throws('no such bug', $$select public.bugs_update(999999, '{"note": "x"}')$$, 'P0002');

select pg_temp.eq('ship iOS from the app', (public.bugs_ship('ios')->'shipped')::text, format('[%s]', :b6));
select pg_temp.eq('again ships nothing', (public.bugs_ship('ios')->'shipped')::text, '[]');
select pg_temp.eq('the server still waits', (select string_agg(e->>'platform', ',') from jsonb_array_elements(public.bugs_inbox()->'pending') e), 'server');
select pg_temp.throws('bad platform', $$select public.bugs_ship('mac')$$, '22023');
select pg_temp.as_user(null);
reset role;

-- The runner and the push gate ------------------------------------------------------------------------------
set role service_role;
select pg_temp.eq('the runner claims the bug with John''s notes',
  (select (x->>'title') || ' | ' || (x->'john_notes'->0->>'body') from (select public.bug_next('S1', 'test') x) t),
  'Crash on standings | Seen at FNM too');
select pg_temp.eq('and reads them with bug_get', (public.bug_get(:b2)->'john_notes'->0->>'body'), 'Yes, add the upload step');
select pg_temp.eq('ops pushes keep only watchers',
  (public.notify_ops_recipients(array[:ANA::uuid, :OPS::uuid]))::text, '{00000000-0000-0000-0000-0000000000f1}');
select pg_temp.eq('nobody, if none are', (public.notify_ops_recipients(array[:ANA::uuid]))::text, '{}');
reset role;
