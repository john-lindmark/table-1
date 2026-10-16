-- Demo data: seeded and shown only for accounts in t1_private.demo_testers, never in real records.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000d1', 'tess@example.com'),
  ('00000000-0000-0000-0000-0000000000d2', 'rita@example.com');
\set TESS '''00000000-0000-0000-0000-0000000000d1'''
\set RITA '''00000000-0000-0000-0000-0000000000d2'''
insert into t1_private.demo_testers (user_id, note) values (:TESS, 'test');

set role authenticated;
select pg_temp.as_user(:RITA);
select pg_temp.throws('non-tester cannot seed demo data', 'select public.demo_seed()', '42501');

select pg_temp.as_user(:TESS);
select public.demo_seed();
reset role;
select pg_temp.eq('tester gets demo events', (select (count(*) > 0)::text from public.events where is_demo and demo_owner = :TESS), 'true');
select pg_temp.eq('demo never reaches player_records',
  (select count(*)::text from public.player_records r join public.profiles p on p.id = r.user_id where p.is_demo), '0');
select pg_temp.eq('real accounts have no demo results in records', (select count(*)::text from public.player_records where user_id = :RITA), '0');
set role authenticated;

select pg_temp.eq('tester home shows demo events',
  (select (jsonb_array_length(public.events_home(false)->'events') > 0)::text), 'true');
select pg_temp.as_user(:RITA);
select pg_temp.eq('non-tester home hides demo even when asking for it',
  (select jsonb_array_length(public.events_home(true)->'events')::text), '0');

select pg_temp.as_user(:TESS);
select public.demo_remove();
reset role;
select pg_temp.eq('demo_remove clears every demo event', (select count(*)::text from public.events where is_demo and demo_owner = :TESS), '0');
