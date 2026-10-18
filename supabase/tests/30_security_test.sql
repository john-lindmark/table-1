-- Schema-wide invariants. These check every table and function, so a new migration that forgets
-- RLS, a search_path or a grant fails here without anyone writing a test for it.
\ir _helpers.sql

-- Every public table has RLS on.
select pg_temp.eq('every public table has RLS',
  (select coalesce(string_agg(c.relname, ',' order by c.relname), '') from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity), '');

-- Claim tokens: RLS on, no policy, so only security definer functions read them.
select pg_temp.eq('participant_tokens has no policy',
  (select count(*)::text from pg_policies where schemaname = 'public' and tablename = 'participant_tokens'), '0');
-- Exact event locations and join secrets are not readable by clients.
select pg_temp.eq('event_locations / event_join_secrets have no select policy for clients',
  (select coalesce(string_agg(tablename || ':' || policyname, ','), '') from pg_policies
    where schemaname = 'public' and tablename in ('event_join_secrets') and cmd in ('SELECT', 'ALL')), '');

-- Event tables are written only by security definer RPCs and the service role: no client write policy,
-- no client write grant. (20261017120000_rpc_only_event_writes; a new write path needs an RPC.)
select pg_temp.eq('no client write policies on event tables',
  (select coalesce(string_agg(tablename || ':' || policyname, ',' order by tablename, policyname), '') from pg_policies
    where schemaname = 'public' and cmd <> 'SELECT'
      and tablename in ('events', 'event_members', 'event_teams', 'pods', 'participants', 'rounds', 'matches',
                        'match_sides', 'audit_log', 'participant_tokens')), '');
select pg_temp.eq('no client write grants on event tables',
  (select coalesce(string_agg(table_name || ':' || grantee || ':' || privilege_type, ',' order by 1), '')
     from information_schema.role_table_grants
    where table_schema = 'public' and grantee in ('anon', 'authenticated')
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
      and table_name in ('events', 'event_members', 'event_teams', 'pods', 'participants', 'rounds', 'matches',
                         'match_sides', 'audit_log')), '');

-- Every security definer function pins its search_path (otherwise a caller's schema can hijack it).
select pg_temp.eq('security definer functions set search_path',
  (select coalesce(string_agg(n.nspname || '.' || p.proname, ',' order by p.proname), '') from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     left join pg_depend d on d.objid = p.oid and d.deptype = 'e'
    where n.nspname in ('public', 't1_private') and p.prosecdef and d.objid is null
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')), '');

-- t1_private is never reachable from clients.
select pg_temp.eq('t1_private not usable by anon/authenticated',
  (select has_schema_privilege('anon', 't1_private', 'usage')::text || has_schema_privilege('authenticated', 't1_private', 'usage')::text),
  'falsefalse');

-- Signed-out callers can't run account functions. Each must refuse anon (insufficient_privilege or a sign-in error).
set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('anon cannot create events', $$select public.create_event_v2('x', 'modern', 3, 3000, null, null, null, null, null, null, '{}', true, true, current_date)$$);
select pg_temp.throws('anon cannot write the collection', $$select public.collection_apply('[]'::jsonb, 'manual', null, gen_random_uuid())$$);
select pg_temp.throws('anon cannot save trades', $$select public.trade_save(null, 'x', null, '[]'::jsonb, '[]'::jsonb)$$);
select pg_temp.throws('anon cannot seed demo data', $$select public.demo_seed()$$);
select pg_temp.eq('anon reads no tokens', (select count(*)::text from public.participant_tokens), '0');
reset role;

-- Trigger-only and internal functions are not callable as RPCs by clients.
select pg_temp.eq('trigger functions not executable by anon',
  (select coalesce(string_agg(p.proname, ',' order by p.proname), '') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prorettype = 'trigger'::regtype and p.prosecdef
      and has_function_privilege('anon', p.oid, 'execute')), '');
