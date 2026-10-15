-- Table 1 — demo testers (2026-10-12). Applied live as migration zz_demo_testers.
-- Accounts listed here always see their own demo data on any build (TestFlight detection is client-side and
-- can fail). Add an account in the SQL Editor:
--   insert into t1_private.demo_testers (user_id, note) select id, 'name' from auth.users where email = '...';
create table if not exists t1_private.demo_testers (
  user_id uuid primary key,
  note text,
  created_at timestamptz not null default now()
);
revoke all on t1_private.demo_testers from anon, authenticated, public;

create or replace function t1_private.is_demo_tester()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from t1_private.demo_testers t where t.user_id = auth.uid())
$$;

-- events_home, account_overview and suggested_players: p_include_demo is also true for testers.
do $mig$
declare
  r record;
  v_def text;
begin
  for r in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('events_home', 'account_overview', 'suggested_players')
  loop
    v_def := pg_get_functiondef(r.oid);
    if position('is_demo_tester' in v_def) = 0 then
      v_def := regexp_replace(v_def, E'\nbegin\n',
        E'\nbegin\n  p_include_demo := coalesce(p_include_demo, false) or t1_private.is_demo_tester();\n');
      execute v_def;
    end if;
  end loop;
end $mig$;
