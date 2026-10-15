-- Table 1 — demo data for listed testers only (2026-10-16).
-- Before: any TestFlight build asked for demo data (p_include_demo) and could seed it from Account.
-- Now: only accounts in t1_private.demo_testers see or seed demo data, whatever the build says.
-- Add a tester in the SQL Editor:
--   insert into t1_private.demo_testers (user_id, note) select id, 'name' from auth.users where email = '...';

insert into t1_private.demo_testers (user_id, note)
select id, 'John' from auth.users where email = 'lindmarkjohn@gmail.com'
on conflict (user_id) do nothing;

-- Whether the caller is a demo tester (the app shows the Developer section only then).
create or replace function public.demo_tester()
returns boolean language sql stable security definer set search_path = '' as $$
  select t1_private.is_demo_tester()
$$;
revoke all on function public.demo_tester() from public, anon;
grant execute on function public.demo_tester() to authenticated;

-- events_home, account_overview, suggested_players: the client's p_include_demo no longer counts.
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
    v_def := replace(v_def,
      'p_include_demo := coalesce(p_include_demo, false) or t1_private.is_demo_tester();',
      'p_include_demo := t1_private.is_demo_tester();');
    if position('p_include_demo := t1_private.is_demo_tester();' in v_def) = 0 then
      v_def := regexp_replace(v_def, E'\nbegin\n', E'\nbegin\n  p_include_demo := t1_private.is_demo_tester();\n');
    end if;
    execute v_def;
  end loop;

  -- demo_seed: testers only.
  select p.oid into r from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'demo_seed';
  v_def := pg_get_functiondef(r.oid);
  if position('is_demo_tester' in v_def) = 0 then
    v_def := regexp_replace(v_def, E'\nbegin\n',
      E'\nbegin\n  if not t1_private.is_demo_tester() then raise exception ''Demo data is for testers only'' using errcode = ''42501''; end if;\n');
    execute v_def;
  end if;
end $mig$;

-- Clear demo data already seeded on accounts that are not testers.
do $mig$
declare
  v_owner uuid;
begin
  for v_owner in
    select distinct demo_owner from public.profiles
     where is_demo and demo_owner is not null
       and demo_owner not in (select user_id from t1_private.demo_testers)
    union
    select distinct demo_owner from public.events
     where is_demo and demo_owner is not null
       and demo_owner not in (select user_id from t1_private.demo_testers)
  loop
    delete from public.events where is_demo and demo_owner = v_owner;
    delete from public.event_invites where invited_by in (select id from public.profiles where is_demo and demo_owner = v_owner);
    delete from public.head_to_head
     where opponent_id in (select id from public.profiles where is_demo and demo_owner = v_owner)
        or user_id in (select id from public.profiles where is_demo and demo_owner = v_owner);
    delete from public.player_records where user_id in (select id from public.profiles where is_demo and demo_owner = v_owner);
    delete from public.profiles where is_demo and demo_owner = v_owner;
  end loop;
end $mig$;
