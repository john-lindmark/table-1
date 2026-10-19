-- Sharing UX: reporting an account, new decks private (contract/friends-sharing-2026-10-18.md § UX rules).
\ir _helpers.sql

-- Ana reports; Ben is reported; Eve is deleted; Zed is a demo account.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}'),
  ('00000000-0000-0000-0000-0000000000e1', 'eve@example.com', '{"full_name": "Eve Gone"}');
update public.profiles set deleted_at = now(), display_name = 'Deleted player' where id = '00000000-0000-0000-0000-0000000000e1';
insert into public.profiles (id, display_name, is_demo, demo_owner) values
  ('00000000-0000-0000-0000-0000000000f1', 'Demo Zed', true, '00000000-0000-0000-0000-0000000000a1');
update public.profiles set handle = 'benny' where id = '00000000-0000-0000-0000-0000000000b1';
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''
\set EVE '''00000000-0000-0000-0000-0000000000e1'''
\set ZED '''00000000-0000-0000-0000-0000000000f1'''

set role authenticated;

-- New decks start private; cubes follow their group ------------------------------------
select pg_temp.as_user(:BEN);
select public.sharing_set('{"library": "friends"}');
select public.list_create('d1000000-0000-0000-0000-000000000001', 'deck', 'Slur deck', 'modern', '[]'::jsonb);
select public.list_create('d1000000-0000-0000-0000-000000000002', 'cube', 'Vintage cube', 'cube', '[]'::jsonb);
select public.binder_save('b1000000-0000-0000-0000-000000000001', 'Trades', true);
select pg_temp.eq('new deck is private on its own setting',
  (select string_agg(i->>'kind' || ':' || coalesce(i->>'visibility', 'same'), ',' order by i->>'kind')
     from jsonb_array_elements(public.sharing_get()->'items') i), 'binder:same,cube:same,deck:private');
select pg_temp.as_user(:ANA);
select pg_temp.eq('a friend-level default does not open a new deck to strangers',
  (select count(*)::text from jsonb_array_elements(public.profile_view(:BEN)->'sections'->'decks')), '0');
select pg_temp.as_user(:BEN);
select public.sharing_set(jsonb_build_object('items', jsonb_build_array(
  jsonb_build_object('kind', 'deck', 'id', 'd1000000-0000-0000-0000-000000000001', 'visibility', null))));
select pg_temp.eq('the owner can put it back on Same',
  (select coalesce(i->>'visibility', 'same') from jsonb_array_elements(public.sharing_get()->'items') i where i->>'kind' = 'deck'), 'same');

-- Reports -------------------------------------------------------------------------------
select pg_temp.as_user(:ANA);
select pg_temp.eq('report Ben', public.user_report(:BEN, 'offensive_content', '  rude deck name  ',
  jsonb_build_object('from', 'profile', 'kind', 'deck', 'id', 'd1000000-0000-0000-0000-000000000001'))::text,
  '{"ok": true, "blocked": false}');
select pg_temp.throws('no reporting yourself', $$select public.user_report('00000000-0000-0000-0000-0000000000a1', 'spam')$$, '22023');
select pg_temp.throws('no reporting a deleted account', $$select public.user_report('00000000-0000-0000-0000-0000000000e1', 'spam')$$, 'P0002');
select pg_temp.throws('no reporting a demo account', $$select public.user_report('00000000-0000-0000-0000-0000000000f1', 'spam')$$, 'P0002');
select pg_temp.throws('a reason is required', $$select public.user_report('00000000-0000-0000-0000-0000000000b1', 'meh')$$, '22023');
select pg_temp.throws('the note has a limit', $$select public.user_report('00000000-0000-0000-0000-0000000000b1', 'other', repeat('x', 501))$$, '22023');
select pg_temp.throws('the context is checked', $$select public.user_report('00000000-0000-0000-0000-0000000000b1', 'other', null, '{"from": "email"}')$$, '22023');
select pg_temp.throws('a bad item id is refused', $$select public.user_report('00000000-0000-0000-0000-0000000000b1', 'other', null, '{"kind": "deck", "id": "nope"}')$$, '22023');
select pg_temp.throws('reports are not readable by accounts', $$select count(*) from public.user_reports$$, '42501');
reset role;
select pg_temp.eq('the report keeps a snapshot of what was reported',
  (select format('%s|%s|%s|%s|%s', reason, note, snapshot->>'display_name', snapshot->>'handle', snapshot->>'item_name')
     from public.user_reports where reporter = :ANA), 'offensive_content|rude deck name|Ben Ortiz|benny|Slur deck');
select pg_temp.eq('audited without the note', (select after::text from public.account_audit where action = 'user.reported'),
  '{"reason": "offensive_content"}');
update public.card_lists set name = 'Renamed' where id = 'd1000000-0000-0000-0000-000000000001';
select pg_temp.eq('a rename later keeps the evidence', (select snapshot->>'item_name' from public.user_reports), 'Slur deck');
set role authenticated;

-- Someone else's item id doesn't land in the snapshot.
select pg_temp.as_user(:ANA);
select public.list_create('d2000000-0000-0000-0000-000000000001', 'deck', 'Ana deck', 'modern', '[]'::jsonb);
select public.user_report(:BEN, 'other', null, jsonb_build_object('kind', 'deck', 'id', 'd2000000-0000-0000-0000-000000000001'));
reset role;
select pg_temp.eq('only their own item is named', (select coalesce(snapshot->>'item_name', 'none') from public.user_reports order by id desc limit 1), 'none');
set role authenticated;

-- Report and block in one step.
select pg_temp.as_user(:ANA);
select pg_temp.eq('report and block', public.user_report(:BEN, 'harassment', null, '{"from": "request"}', true)->>'blocked', 'true');
select pg_temp.eq('Ben is blocked', (select count(*)::text from jsonb_array_elements(public.friends_list()->'blocked')), '1');

-- 20 a day.
select public.user_report(:BEN, 'spam') from generate_series(1, 17);
select pg_temp.throws('20 reports a day', $$select public.user_report('00000000-0000-0000-0000-0000000000b1', 'spam')$$, '53400');

-- Signed out: refused.
reset role;
set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('anon cannot report', $$select public.user_report('00000000-0000-0000-0000-0000000000b1', 'spam')$$);
reset role;

-- Deleting your account clears your id from the reports you made; reports about you stay.
set role authenticated;
select pg_temp.as_user(:ANA);
select public.delete_account();
reset role;
select pg_temp.eq('reporter cleared', (select count(*)::text from public.user_reports where reporter is not null), '0');
select pg_temp.eq('reports kept', (select count(*)::text from public.user_reports where reported = :BEN), '20');
