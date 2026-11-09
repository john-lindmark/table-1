-- Friends on profiles (20261109210000_profile_friends.sql; contract/friends-sharing-2026-10-18.md § Friends on
-- profiles): who sees a friends list (the owner's `friends`, capped by the profile), who shows in it (each friend's
-- `listed`, capped by their profile), mutual friends first, blocks, deleted and demo accounts, settings and audits.
\ir _helpers.sql

-- Ana owns the list. Her friends: Ben, Cal, Dee, Eve (deleted later), Zed (demo). Viewers: Ben (her friend, Cal's
-- friend too), Vic (a stranger, Dee's friend), Fay (blocks Ana... later).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000080a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000080b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}'),
  ('00000000-0000-0000-0000-0000000080c1', 'cal@example.com', '{"full_name": "Cal Reyes"}'),
  ('00000000-0000-0000-0000-0000000080d1', 'dee@example.com', '{"full_name": "Dee Park"}'),
  ('00000000-0000-0000-0000-0000000080e1', 'eve@example.com', '{"full_name": "Eve Gone"}'),
  ('00000000-0000-0000-0000-0000000080f1', 'vic@example.com', '{"full_name": "Vic Hale"}'),
  ('00000000-0000-0000-0000-0000000080a2', 'fay@example.com', '{"full_name": "Fay Moss"}');
insert into public.profiles (id, display_name, is_demo, demo_owner) values
  ('00000000-0000-0000-0000-0000000080f9', 'Demo Zed', true, '00000000-0000-0000-0000-0000000080a1');
\set ANA '''00000000-0000-0000-0000-0000000080a1'''
\set BEN '''00000000-0000-0000-0000-0000000080b1'''
\set CAL '''00000000-0000-0000-0000-0000000080c1'''
\set DEE '''00000000-0000-0000-0000-0000000080d1'''
\set EVE '''00000000-0000-0000-0000-0000000080e1'''
\set VIC '''00000000-0000-0000-0000-0000000080f1'''
\set FAY '''00000000-0000-0000-0000-0000000080a2'''
\set ZED '''00000000-0000-0000-0000-0000000080f9'''

create or replace function pg_temp.befriend(a uuid, b uuid) returns void language sql as $$
  insert into public.friendships (user_lo, user_hi, requested_by, status, responded_at)
  values (least(a, b), greatest(a, b), a, 'accepted', now());
$$;
select pg_temp.befriend(:ANA, :BEN), pg_temp.befriend(:ANA, :CAL), pg_temp.befriend(:ANA, :DEE),
       pg_temp.befriend(:ANA, :EVE), pg_temp.befriend(:ANA, :ZED), pg_temp.befriend(:ANA, :FAY),
       pg_temp.befriend(:BEN, :CAL), pg_temp.befriend(:VIC, :DEE);
-- A pending request isn't a friend.
insert into public.friendships (user_lo, user_hi, requested_by, status)
values (least(:ANA::uuid, :VIC::uuid), greatest(:ANA::uuid, :VIC::uuid), :VIC, 'pending');

-- Names of the rows a viewer gets, in order.
create or replace function pg_temp.names(p_owner uuid) returns text language sql as $$
  select string_agg(r->>'display_name', ',' order by i)
    from jsonb_array_elements(public.profile_friends(p_owner)->'rows') with ordinality t(r, i);
$$;
create or replace function pg_temp.section(p_owner uuid) returns text language sql as $$
  select (public.profile_view(p_owner)->'sections'->'friends')::text;
$$;

-- ==================================================================== defaults
select pg_temp.as_user(:ANA);
select pg_temp.eq('defaults: friends private, listed friends',
  (select (public.sharing_get()->>'friends') || ',' || (public.sharing_get()->>'listed')), 'private,friends');
select pg_temp.eq('your own profile has the section', pg_temp.section(:ANA), '{"mutual": 0}');
select pg_temp.eq('you see every live friend, Fay too, by name', pg_temp.names(:ANA), 'Ben Ortiz,Cal Reyes,Dee Park,Eve Gone,Fay Moss');

select pg_temp.as_user(:BEN);
select pg_temp.eq('a private list: no section for a friend', pg_temp.section(:ANA), null);
select pg_temp.throws('a private list: profile_friends refused', $$select public.profile_friends('00000000-0000-0000-0000-0000000080a1')$$, '42501');

-- ==================================================================== list to friends
select pg_temp.as_user(:ANA);
select public.sharing_set('{"friends": "friends"}');
select pg_temp.eq('the change is audited', (select count(*)::text from public.account_audit
  where actor = :ANA and action = 'sharing.set' and after->>'friends' = 'friends'), '1');
select public.sharing_set('{"friends": "friends"}');
select pg_temp.eq('the same value writes no audit row', (select count(*)::text from public.account_audit
  where actor = :ANA and action = 'sharing.set'), '1');

select pg_temp.as_user(:BEN);
-- Ben is friends with Cal (mutual, first) and himself; Dee and Fay are listed to friends only, and they aren't his.
select pg_temp.eq('a friend: mutual first, themselves, nobody whose listing stops at their friends', pg_temp.names(:ANA), 'Cal Reyes,Ben Ortiz');
select pg_temp.eq('a friend: the mutual count', pg_temp.section(:ANA), '{"mutual": 1}');
select pg_temp.eq('rows carry relation and mutual',
  (select (r->>'relation') || '/' || (r->>'mutual') from jsonb_array_elements(public.profile_friends(:ANA)->'rows') r
    where r->>'display_name' = 'Cal Reyes'), 'friend/true');
select pg_temp.eq('your own row reads self',
  (select r->>'relation' from jsonb_array_elements(public.profile_friends(:ANA)->'rows') r
    where r->>'display_name' = 'Ben Ortiz'), 'self');

select pg_temp.as_user(:VIC);
select pg_temp.eq('a stranger: a friends-only list has no section', pg_temp.section(:ANA), null);
select pg_temp.throws('a stranger: refused', $$select public.profile_friends('00000000-0000-0000-0000-0000000080a1')$$, '42501');

-- ==================================================================== listed
-- Dee lists herself to anyone, but her profile is friends: Ben still doesn't see her (the profile caps it).
select pg_temp.as_user(:DEE);
select public.sharing_set('{"listed": "public"}');
select pg_temp.as_user(:BEN);
select pg_temp.eq('listed public under a friends profile is capped', pg_temp.names(:ANA), 'Cal Reyes,Ben Ortiz');
select pg_temp.as_user(:DEE);
select public.sharing_set('{"profile": "public"}');
select pg_temp.as_user(:BEN);
select pg_temp.eq('listed public on a public profile shows to anyone who sees the list', pg_temp.names(:ANA), 'Cal Reyes,Ben Ortiz,Dee Park');

-- Cal hides himself: gone from Ben's view of Ana's list, still on Ana's own.
select pg_temp.as_user(:CAL);
select public.sharing_set('{"listed": "private"}');
select pg_temp.as_user(:BEN);
select pg_temp.eq('listed private hides you from others', pg_temp.names(:ANA), 'Ben Ortiz,Dee Park');
select pg_temp.eq('and from the mutual count', pg_temp.section(:ANA), '{"mutual": 0}');
select pg_temp.as_user(:ANA);
select pg_temp.eq('the owner still sees a hidden friend', pg_temp.names(:ANA), 'Ben Ortiz,Cal Reyes,Dee Park,Eve Gone,Fay Moss');
select pg_temp.as_user(:CAL);
select pg_temp.eq('a hidden friend sees themselves', pg_temp.names(:ANA), 'Ben Ortiz,Cal Reyes,Dee Park');

-- ==================================================================== list to anyone
select pg_temp.as_user(:ANA);
select public.sharing_set('{"friends": "public"}');
select pg_temp.as_user(:VIC);
select pg_temp.eq('anyone, but Ana''s profile is friends: still capped', pg_temp.section(:ANA), null);
select pg_temp.as_user(:ANA);
select public.sharing_set('{"profile": "public"}');
select pg_temp.as_user(:VIC);
-- Vic is Dee's friend (mutual), and Dee lists to anyone; Ben lists to friends only (Vic isn't his).
select pg_temp.eq('a stranger sees who lists to anyone, mutual first', pg_temp.names(:ANA), 'Dee Park');
select pg_temp.eq('a stranger''s mutual count', pg_temp.section(:ANA), '{"mutual": 1}');

-- ==================================================================== blocks, deleted, demo
-- Fay lists to anyone on a public profile, then blocks Vic: Vic never sees her.
select pg_temp.as_user(:FAY);
select public.sharing_set('{"listed": "public", "profile": "public"}');
select pg_temp.as_user(:VIC);
select pg_temp.eq('before the block Fay shows', pg_temp.names(:ANA), 'Dee Park,Fay Moss');
select pg_temp.as_user(:FAY);
select public.user_block(:VIC, true);
select pg_temp.as_user(:VIC);
select pg_temp.eq('a friend who blocked you never shows', pg_temp.names(:ANA), 'Dee Park');
-- Ana blocks Vic: nothing of her list reaches him.
select pg_temp.as_user(:ANA);
select public.user_block(:VIC, true);
select pg_temp.as_user(:VIC);
select pg_temp.throws('blocked by the owner: refused', $$select public.profile_friends('00000000-0000-0000-0000-0000000080a1')$$, '42501');
select pg_temp.as_user(:ANA);
select public.user_block(:VIC, false);

update public.profiles set deleted_at = now(), display_name = 'Deleted player' where id = :EVE;
select pg_temp.as_user(:ANA);
select pg_temp.eq('deleted and demo accounts never show', pg_temp.names(:ANA), 'Ben Ortiz,Cal Reyes,Dee Park,Fay Moss');
select pg_temp.throws('a deleted account''s list: refused', $$select public.profile_friends('00000000-0000-0000-0000-0000000080e1')$$, '42501');

-- ==================================================================== paging and settings
select pg_temp.eq('paging: one row and more',
  (select (jsonb_array_length(public.profile_friends(:ANA, 0, 1)->'rows'))::text || ',' || (public.profile_friends(:ANA, 0, 1)->>'more')), '1,true');
select pg_temp.eq('paging: the second page',
  (select public.profile_friends(:ANA, 1, 1)->'rows'->0->>'display_name'), 'Cal Reyes');
select pg_temp.eq('paging: the last page has no more',
  (select public.profile_friends(:ANA, 3, 10)->>'more'), 'false');
select pg_temp.throws('friends needs a value', $$select public.sharing_set('{"friends": null}')$$, '22023');
select pg_temp.throws('listed takes a visibility', $$select public.sharing_set('{"listed": "everyone"}')$$, '22023');
select pg_temp.eq('old settings untouched by the new keys',
  (select public.sharing_get()->>'record' || ',' || (public.sharing_get()->>'library')), 'private,private');

-- A restricted account lists nowhere (share_of reads every part private), and its own list reaches no one.
insert into public.moderation_restrictions (user_id, until, reason, by_user) values (:DEE, now() + interval '7 days', 'test', :ANA);
select pg_temp.as_user(:BEN);
select pg_temp.eq('a restricted friend is hidden', pg_temp.names(:ANA), 'Ben Ortiz,Fay Moss');
delete from public.moderation_restrictions where user_id = :DEE;
insert into public.moderation_restrictions (user_id, until, reason, by_user) values (:ANA, now() + interval '7 days', 'test', :BEN);
select pg_temp.throws('a restricted owner''s list: refused', $$select public.profile_friends('00000000-0000-0000-0000-0000000080a1')$$, '42501');
delete from public.moderation_restrictions where user_id = :ANA;

select pg_temp.as_user(null);
select pg_temp.throws('signed out: refused', $$select public.profile_friends('00000000-0000-0000-0000-0000000080a1')$$, '28000');
select pg_temp.eq('anon can''t execute it',
  has_function_privilege('anon', 'public.profile_friends(uuid, integer, integer)', 'execute')::text, 'false');
select pg_temp.eq('clients can''t reach friends_shown',
  has_function_privilege('authenticated', 't1_private.friends_shown(uuid, uuid)', 'execute')::text, 'false');
