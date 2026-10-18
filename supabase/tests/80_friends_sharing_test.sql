-- Friends, profiles, sharing and trade matches (contract/friends-sharing-2026-10-18.md).
\ir _helpers.sql

-- Ana (me), Ben (friend to be), Cal (played with Ana, not a friend), Dee (stranger), Eve (deleted), Zed (demo),
-- Fay (blocks Ana).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com', '{"full_name": "Cal Reyes"}'),
  ('00000000-0000-0000-0000-0000000000d1', 'dee@example.com', '{"full_name": "Dee Park"}'),
  ('00000000-0000-0000-0000-0000000000e1', 'eve@example.com', '{"full_name": "Eve Gone"}'),
  ('00000000-0000-0000-0000-0000000000a2', 'fay@example.com', '{"full_name": "Fay Moss"}');
update public.profiles set deleted_at = now(), display_name = 'Deleted player' where id = '00000000-0000-0000-0000-0000000000e1';
insert into public.profiles (id, display_name, is_demo, demo_owner) values
  ('00000000-0000-0000-0000-0000000000f1', 'Demo Zed', true, '00000000-0000-0000-0000-0000000000a1');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''
\set CAL '''00000000-0000-0000-0000-0000000000c1'''
\set DEE '''00000000-0000-0000-0000-0000000000d1'''
\set EVE '''00000000-0000-0000-0000-0000000000e1'''
\set ZED '''00000000-0000-0000-0000-0000000000f1'''
\set FAY '''00000000-0000-0000-0000-0000000000a2'''

-- Cards: Bolt (m10 nonfoil+foil, m11), Opt, Goyf.
insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000002', 'Opt', 'opt', 'normal', 'c1000000-0000-0000-0000-000000000002', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000003', 'Tarmogoyf', 'tarmogoyf', 'normal', 'c1000000-0000-0000-0000-000000000004', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil,foil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000001', 'm11', '149', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'xln', '65', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000003', 'fut', '153', 'en', 'rare', '{nonfoil}', 'normal', 'h');
insert into public.card_prices (card_id, usd, usd_foil) values
  ('c1000000-0000-0000-0000-000000000001', 2.00, 9.00),
  ('c1000000-0000-0000-0000-000000000003', 1.00, null),
  ('c1000000-0000-0000-0000-000000000002', 0.10, null),
  ('c1000000-0000-0000-0000-000000000004', 30.00, null);
\set BOLT '''c1000000-0000-0000-0000-000000000001'''
\set BOLT2 '''c1000000-0000-0000-0000-000000000003'''
\set OPT '''c1000000-0000-0000-0000-000000000002'''
\set GOYF '''c1000000-0000-0000-0000-000000000004'''
\set BOLT_O '''c0000000-0000-0000-0000-000000000001'''
\set OPT_O '''c0000000-0000-0000-0000-000000000002'''
\set GOYF_O '''c0000000-0000-0000-0000-000000000003'''

-- Ana and Cal played an event last week; Ana and Dee never did.
insert into public.events (id, short_code, name, created_by, status) values
  ('e1000000-0000-0000-0000-000000000001', 'FRND01', 'Friday draft', :ANA, 'completed'),
  ('e1000000-0000-0000-0000-000000000002', 'FRND02', 'Next draft', :ANA, 'setup');
insert into public.event_members (event_id, user_id, role) values
  ('e1000000-0000-0000-0000-000000000001', :ANA, 'owner'), ('e1000000-0000-0000-0000-000000000002', :ANA, 'owner');
insert into public.participants (event_id, user_id, display_name, seat) values
  ('e1000000-0000-0000-0000-000000000001', :ANA, 'Ana Lind', 1),
  ('e1000000-0000-0000-0000-000000000001', :CAL, 'Cal Reyes', 2);

create or replace function pg_temp.j(v jsonb, path text[]) returns text language sql as $$ select v #>> path $$;
-- friend.request pushes from one account to another.
create or replace function pg_temp.pushes(p_from uuid, p_to uuid) returns text language sql as $$
  select count(*)::text from pgmq.messages
   where msg->>'kind' = 'friend.request' and msg->'data'->>'user_id' = p_from::text and msg->'user_ids' ? p_to::text $$;
-- Sent (outgoing) as email-or-name:has-user_id, newest first.
create or replace function pg_temp.sent(v jsonb) returns text language sql as $$
  select coalesce(string_agg(coalesce(o->>'email', o->>'display_name') || ':' || (o ? 'user_id')::text, ',' order by ord), '')
    from jsonb_array_elements(v->'outgoing') with ordinality x(o, ord) $$;

set role authenticated;

-- Friends ------------------------------------------------------------------------
select pg_temp.as_user(:ANA);
select pg_temp.eq('ask Ben', public.friend_request(:BEN)->>'status', 'requested');
select pg_temp.eq('asking again is the same answer', public.friend_request(:BEN)->>'status', 'requested');
select pg_temp.throws('cannot add yourself', $$select public.friend_request('00000000-0000-0000-0000-0000000000a1')$$, '22023');
select pg_temp.throws('deleted account refused', $$select public.friend_request('00000000-0000-0000-0000-0000000000e1')$$, 'P0002');
select pg_temp.throws('demo account refused', $$select public.friend_request('00000000-0000-0000-0000-0000000000f1')$$, 'P0002');
select pg_temp.throws('unknown account refused', $$select public.friend_request(gen_random_uuid())$$, 'P0002');
select pg_temp.eq('outgoing lists Ben', pg_temp.j(public.friends_list(), '{outgoing,0,display_name}'), 'Ben Ortiz');
select pg_temp.throws('Ana cannot accept her own request', $$select public.friend_respond('00000000-0000-0000-0000-0000000000b1', true)$$, 'P0002');

select pg_temp.as_user(:BEN);
select pg_temp.eq('Ben sees the request', pg_temp.j(public.friends_list(), '{incoming,0,user_id}'), '00000000-0000-0000-0000-0000000000a1');
select pg_temp.eq('Ben sees relation incoming', public.profile_view(:ANA)->>'relation', 'incoming');
select pg_temp.eq('Ben accepts', public.friend_respond(:ANA, true)->>'status', 'friends');
select pg_temp.eq('accepting again is the same answer', public.friend_respond(:ANA, true)->>'status', 'friends');
select pg_temp.eq('Ben has one friend', jsonb_array_length(public.friends_list()->'friends')::text, '1');
select pg_temp.eq('asking a friend says friends', public.friend_request(:ANA)->>'status', 'friends');

-- Decline is quiet; asking back makes friends.
select pg_temp.as_user(:DEE);
select public.friend_request(:CAL);
select pg_temp.as_user(:CAL);
select pg_temp.eq('Cal declines', public.friend_respond(:DEE, false)->>'status', 'declined');
select pg_temp.eq('declined leaves Cal''s incoming', jsonb_array_length(public.friends_list()->'incoming')::text, '0');
select pg_temp.as_user(:DEE);
select pg_temp.eq('Dee still sees Requested', public.profile_view(:CAL)->>'relation', 'requested');
select pg_temp.eq('Dee asking again changes nothing', public.friend_request(:CAL)->>'status', 'requested');
select pg_temp.eq('Dee cancels', public.friend_remove(:CAL)->>'removed', 'true');
select pg_temp.eq('cancel twice: nothing to remove', public.friend_remove(:CAL)->>'removed', 'false');
select public.friend_request(:CAL);
select pg_temp.as_user(:CAL);
select public.friend_respond(:DEE, false);
select pg_temp.eq('Cal asking Dee after declining makes friends', public.friend_request(:DEE)->>'status', 'friends');
select pg_temp.eq('Cal unfriends Dee', public.friend_remove(:DEE)->>'removed', 'true');
select pg_temp.eq('Dee is no longer a friend', public.profile_view(:DEE)->>'relation', 'none');

-- Email: the same answer either way; a match sends a request.
select pg_temp.as_user(:DEE);
select pg_temp.eq('email with no account', public.friend_request_by_email('nobody@example.com')->>'ok', 'true');
select pg_temp.eq('email of an account', public.friend_request_by_email(' ANA@example.com ')->>'ok', 'true');
select pg_temp.throws('bad email refused', $$select public.friend_request_by_email('nope')$$, '22023');
select pg_temp.as_user(:CAL);
select public.friend_request_by_email('nobody' || g || '@example.com') from generate_series(1, 20) g;
select pg_temp.throws('20 email lookups an hour', $$select public.friend_request_by_email('one-more@example.com')$$, '53400');
select pg_temp.as_user(:DEE);
select pg_temp.as_user(:ANA);
select pg_temp.eq('the email request reached Ana', pg_temp.j(public.friends_list(), '{incoming,0,display_name}'), 'Dee Park');

-- Asking by email never tells the asker whose address it was (privacy fix 1).
select pg_temp.as_user(:DEE);
select pg_temp.eq('Sent shows both emails alike, no Person', pg_temp.sent(public.friends_list()),
  'ana@example.com:false,nobody@example.com:false');
select pg_temp.eq('Sent email rows are {email, at} only',
  (select string_agg(k, ',' order by k) from jsonb_object_keys(public.friends_list()->'outgoing'->0) k), 'at,email');
select pg_temp.eq('Ana''s profile reads none, not requested', public.profile_view(:ANA)->>'relation', 'none');
select pg_temp.eq('friend_remove by a guessed id finds nothing', public.friend_remove(:ANA)->>'removed', 'false');
select pg_temp.throws('friend_respond by a guessed id: gone', $$select public.friend_respond('00000000-0000-0000-0000-0000000000a1', true)$$, 'P0002');
select pg_temp.eq('cancel by email: an address with no account', public.friend_cancel_email('nobody@example.com')->>'removed', 'true');
select pg_temp.eq('cancel by email: Ana''s address', public.friend_cancel_email('Ana@example.com ')->>'removed', 'true');
select pg_temp.eq('cancel twice: nothing to cancel', public.friend_cancel_email('ana@example.com')->>'removed', 'false');
select pg_temp.eq('Sent is empty', pg_temp.sent(public.friends_list()), '');
select pg_temp.as_user(:ANA);
select pg_temp.eq('Dee''s request is gone from Ana''s Requests', jsonb_array_length(public.friends_list()->'incoming')::text, '0');
-- Ana asks Cal (played with) by email: search says none; asking from the profile names it; accepting clears it.
select public.friend_request_by_email('cal@example.com');
select pg_temp.eq('search: an email request reads none',
  (select r->>'relation' from jsonb_array_elements(public.friend_search(null)) r where r->>'display_name' = 'Cal Reyes'), 'none');
select pg_temp.eq('Sent: the email only', pg_temp.sent(public.friends_list()), 'cal@example.com:false');
select pg_temp.eq('asking Cal by id answers requested', public.friend_request(:CAL)->>'status', 'requested');
select pg_temp.eq('… and now reads requested', public.profile_view(:CAL)->>'relation', 'requested');
select pg_temp.eq('… Sent shows Cal and still the email', pg_temp.sent(public.friends_list()), 'cal@example.com:false,Cal Reyes:true');
reset role;
select pg_temp.eq('one push to Cal for both asks', pg_temp.pushes(:ANA, :CAL), '1');
set role authenticated;
select pg_temp.as_user(:CAL);
select pg_temp.eq('Cal sees Ana''s request', pg_temp.j(public.friends_list(), '{incoming,0,display_name}'), 'Ana Lind');
select pg_temp.eq('Cal accepts', public.friend_respond(:ANA, true)->>'status', 'friends');
select pg_temp.as_user(:ANA);
select pg_temp.eq('accepted: the email leaves Sent', pg_temp.sent(public.friends_list()), '');
select pg_temp.as_user(:CAL);
select pg_temp.eq('Cal unfriends Ana', public.friend_remove(:ANA)->>'removed', 'true');
select pg_temp.as_user(:ANA);
select pg_temp.eq('unfriended: the email does not come back', pg_temp.sent(public.friends_list()), '');

-- A decline is remembered: cancelling and asking again sends no push (privacy fix 2).
select pg_temp.as_user(:CAL);
select pg_temp.eq('Cal asks Dee', public.friend_request(:DEE)->>'status', 'requested');
select pg_temp.as_user(:DEE);
select public.friend_respond(:CAL, false);
select pg_temp.as_user(:CAL);
select pg_temp.eq('Cal cancels the declined request', public.friend_remove(:DEE)->>'removed', 'true');
select pg_temp.eq('Cal asks again', public.friend_request(:DEE)->>'status', 'requested');
select pg_temp.eq('… it still reads requested', public.profile_view(:DEE)->>'relation', 'requested');
select public.friend_remove(:DEE);
select public.friend_request(:DEE);
reset role;
select pg_temp.eq('only the first ask pushed to Dee', pg_temp.pushes(:CAL, :DEE), '1');
set role authenticated;
select pg_temp.as_user(:DEE);
select pg_temp.eq('… and nothing waits in Dee''s Requests', jsonb_array_length(public.friends_list()->'incoming')::text, '0');
select pg_temp.eq('Dee asking back still makes friends', public.friend_request(:CAL)->>'status', 'friends');
select public.friend_remove(:CAL);
-- At most 3 request pushes to one person in 30 days, however often you cancel and ask.
select pg_temp.as_user(:BEN);
select public.friend_request(:CAL), public.friend_remove(:CAL) from generate_series(1, 5);
reset role;
select pg_temp.eq('per-person push cap', pg_temp.pushes(:BEN, :CAL), '3');
set role authenticated;
select pg_temp.as_user(:BEN);
select pg_temp.eq('… the request itself still goes in', public.friend_request(:CAL)->>'status', 'requested');
select public.friend_remove(:CAL);
select pg_temp.as_user(:ANA);

-- Block: drops the request, hides everything, the blocked side gets the usual answers.
select pg_temp.eq('Ana blocks Dee', public.user_block(:DEE, true)->>'blocked', 'true');
select pg_temp.eq('blocking drops the request', jsonb_array_length(public.friends_list()->'incoming')::text, '0');
select pg_temp.eq('blocked list', pg_temp.j(public.friends_list(), '{blocked,0,display_name}'), 'Dee Park');
select pg_temp.throws('Ana must unblock to ask', $$select public.friend_request('00000000-0000-0000-0000-0000000000d1')$$, '22023');
select pg_temp.as_user(:DEE);
select pg_temp.eq('Dee asking Ana answers requested', public.friend_request(:ANA)->>'status', 'requested');
reset role;
select pg_temp.eq('… and writes nothing', (select count(*)::text from public.friendships
  where '00000000-0000-0000-0000-0000000000d1' in (user_lo, user_hi) and '00000000-0000-0000-0000-0000000000a1' in (user_lo, user_hi)), '0');
set role authenticated;
select pg_temp.eq('Dee sees no relation', public.profile_view(:ANA)->>'relation', 'none');

-- Invites and new-event alerts skip blocks either way, with the usual answers (privacy fix 3).
select pg_temp.as_user(:FAY);
select public.user_block(:ANA, true);
select pg_temp.as_user(:ANA);
select pg_temp.eq('inviting someone Ana blocked: the usual answer',
  public.invite_players('e1000000-0000-0000-0000-000000000002', array['00000000-0000-0000-0000-0000000000d1'::uuid])::text,
  '{"ok": true, "invited": 1}');
select pg_temp.eq('inviting someone who blocked Ana: the usual answer',
  public.invite_players('e1000000-0000-0000-0000-000000000002', array['00000000-0000-0000-0000-0000000000a2'::uuid])->>'invited', '1');
select pg_temp.eq('by email: the usual answer', public.invite_by_email('e1000000-0000-0000-0000-000000000002', 'dee@example.com')->>'ok', 'true');
select pg_temp.eq('… by email the other way', public.invite_by_email('e1000000-0000-0000-0000-000000000002', 'fay@example.com')->>'ok', 'true');
reset role;
select pg_temp.eq('… and no invitation written', (select count(*)::text from public.event_invites
  where event_id = 'e1000000-0000-0000-0000-000000000002'), '0');
select pg_temp.eq('… or pushed', (select count(*)::text from pgmq.messages where msg->>'kind' = 'event.invite'), '0');
select pg_temp.eq('new event alerts the regular (Cal)', public._send_regulars_alert('e1000000-0000-0000-0000-000000000002')::text, '1');
insert into public.user_blocks (user_id, blocked_id) values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a1');
select pg_temp.eq('… not once Cal blocked Ana', public._send_regulars_alert('e1000000-0000-0000-0000-000000000002')::text, '0');
update public.user_blocks set user_id = blocked_id, blocked_id = user_id where user_id = '00000000-0000-0000-0000-0000000000c1';
select pg_temp.eq('… nor once Ana blocked Cal', public._send_regulars_alert('e1000000-0000-0000-0000-000000000002')::text, '0');
delete from public.user_blocks where blocked_id = '00000000-0000-0000-0000-0000000000c1';
select pg_temp.eq('event.new pushes: only the first', (select count(*)::text from pgmq.messages where msg->>'kind' = 'event.new'), '1');
set role authenticated;

-- Clients can't touch the tables.
select pg_temp.throws('no direct read of friendships', $$select * from public.friendships$$, '42501');
select pg_temp.throws('no direct insert into friendships',
  $$insert into public.friendships (user_lo, user_hi, requested_by, status) values ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d1', 'accepted')$$, '42501');
select pg_temp.throws('no direct write of share_settings',
  $$insert into public.share_settings (user_id, profile) values ('00000000-0000-0000-0000-0000000000a1', 'public')$$, '42501');
select pg_temp.throws('no direct update of binder visibility', $$update public.binders set visibility = 'public'$$, '42501');

-- Search: played-with suggestions; public profiles by name.
select pg_temp.as_user(:ANA);
select pg_temp.eq('suggestions are people Ana played with', pg_temp.j(public.friend_search(null), '{0,display_name}'), 'Cal Reyes');
select pg_temp.eq('suggestion counts shared events', pg_temp.j(public.friend_search(null), '{0,shared_events}'), '1');
select pg_temp.eq('private profiles are not found by name', jsonb_array_length(public.friend_search('ben'))::text, '0');

-- Library: Ben (friend) and Cal (played with) each have a trade binder and wants; Ana too. --------------------
select pg_temp.as_user(:BEN);
select public.binder_save('b1000000-0000-0000-0000-000000000001', 'Ben trades', true);
select public.binder_save('b1000000-0000-0000-0000-000000000002', 'Ben box', false);
select public.collection_apply(jsonb_build_array(
  jsonb_build_object('card_id', :BOLT, 'delta', 3, 'binder_id', 'b1000000-0000-0000-0000-000000000001'),
  jsonb_build_object('card_id', :BOLT, 'finish', 'foil', 'delta', 1, 'binder_id', 'b1000000-0000-0000-0000-000000000001'),
  jsonb_build_object('card_id', :BOLT2, 'delta', 2, 'binder_id', 'b1000000-0000-0000-0000-000000000001'),
  jsonb_build_object('card_id', :GOYF, 'delta', 1, 'binder_id', 'b1000000-0000-0000-0000-000000000001'),
  jsonb_build_object('card_id', :GOYF, 'delta', 2, 'binder_id', 'b1000000-0000-0000-0000-000000000002')),
  'manual', null, 'e2000000-0000-0000-0000-000000000001');
select public.wants_apply(jsonb_build_array(jsonb_build_object('oracle_id', :OPT_O, 'qty', 4, 'max_usd', 0.05)),
  'e2000000-0000-0000-0000-000000000002');
select public.list_create('d1000000-0000-0000-0000-000000000001', 'deck', 'Ben burn', 'modern',
  jsonb_build_array(jsonb_build_array(:BOLT, 'main', 4), jsonb_build_array(:OPT, 'maybe', 1)));

select pg_temp.as_user(:CAL);
select public.binder_save('b2000000-0000-0000-0000-000000000001', 'Cal trades', true);
select public.collection_apply(jsonb_build_array(
  jsonb_build_object('card_id', :GOYF, 'delta', 2, 'binder_id', 'b2000000-0000-0000-0000-000000000001')),
  'manual', null, 'e2000000-0000-0000-0000-000000000003');

select pg_temp.as_user(:ANA);
select public.binder_save('b3000000-0000-0000-0000-000000000001', 'Ana trades', true);
select public.collection_apply(jsonb_build_array(
  jsonb_build_object('card_id', :OPT, 'delta', 6, 'binder_id', 'b3000000-0000-0000-0000-000000000001'),
  jsonb_build_object('card_id', :OPT, 'delta', 2)),
  'manual', null, 'e2000000-0000-0000-0000-000000000004');
-- Ana wants: Bolt m10 foil ×1 (exact), Bolt m10 any finish ×2 (printing), Bolt any ×4 (any), Goyf ×1 max $20.
select public.wants_apply(jsonb_build_array(
  jsonb_build_object('card_id', :BOLT, 'finish', 'foil', 'qty', 1),
  jsonb_build_object('card_id', :BOLT, 'qty', 2),
  jsonb_build_object('oracle_id', :BOLT_O, 'qty', 4),
  jsonb_build_object('oracle_id', :GOYF_O, 'qty', 1, 'max_usd', 20)),
  'e2000000-0000-0000-0000-000000000005');

-- Visibility: everything private by default ---------------------------------------------------------
select pg_temp.eq('owner sees every part of her own profile',
  (select string_agg(k, ',' order by k) from jsonb_object_keys(public.profile_view(:ANA)->'sections') k),
  'all_cards,binders,cubes,decks,for_trade,record,wants');
select pg_temp.eq('friend sees the profile (friends default)', public.profile_view(:BEN)->>'visible', 'true');
select pg_temp.eq('… but nothing in it', (public.profile_view(:BEN)->'sections')::text,
  '{"cubes": [], "decks": [], "binders": []}');
select pg_temp.eq('stranger: profile not visible', public.profile_view(:CAL)->>'visible', 'false');
select pg_temp.eq('… only name and avatar', public.profile_view(:CAL)->>'display_name', 'Cal Reyes');
select pg_temp.throws('private for-trade list refused', $$select public.profile_cards('00000000-0000-0000-0000-0000000000b1', 'for_trade')$$, '42501');
select pg_temp.throws('private binder refused', $$select public.profile_cards('00000000-0000-0000-0000-0000000000b1', 'binder', 'b1000000-0000-0000-0000-000000000001')$$, '42501');
select pg_temp.throws('unknown binder reads the same', $$select public.profile_cards('00000000-0000-0000-0000-0000000000b1', 'binder', gen_random_uuid())$$, '42501');
select pg_temp.throws('unknown section', $$select public.profile_cards('00000000-0000-0000-0000-0000000000b1', 'trades')$$, '22023');
select pg_temp.eq('no matches while everything is private', jsonb_array_length(public.trade_matches()->'people')::text, '0');
select pg_temp.throws('deleted profile', $$select public.profile_view('00000000-0000-0000-0000-0000000000e1')$$, 'P0002');
select pg_temp.throws('demo profile', $$select public.profile_view('00000000-0000-0000-0000-0000000000f1')$$, 'P0002');

-- Sharing settings ---------------------------------------------------------------------------------
select pg_temp.as_user(:BEN);
select pg_temp.eq('defaults', (public.sharing_get() - 'items')::text,
  '{"cubes": null, "decks": null, "wants": null, "record": "private", "binders": null, "library": "private", "profile": "friends", "all_cards": null, "for_trade": null}');
select pg_temp.eq('items list binders and decks', jsonb_array_length(public.sharing_get()->'items')::text, '3');
select pg_temp.throws('bad value refused', $$select public.sharing_set('{"wants": "everyone"}')$$, '22023');
select pg_temp.throws('unknown key refused', $$select public.sharing_set('{"trades": "public"}')$$, '22023');
select pg_temp.throws('profile needs a value', $$select public.sharing_set('{"profile": null}')$$, '22023');
select pg_temp.throws('someone else''s binder refused',
  $$select public.sharing_set('{"items": [{"kind": "binder", "id": "b3000000-0000-0000-0000-000000000001", "visibility": "public"}]}')$$, '42501');
select pg_temp.throws('a deck id as a cube refused',
  $$select public.sharing_set('{"items": [{"kind": "cube", "id": "d1000000-0000-0000-0000-000000000001", "visibility": "public"}]}')$$, '42501');
-- Ben shares For trade and Wants with friends, his trade binder publicly.
select pg_temp.eq('set for_trade + wants', public.sharing_set('{"for_trade": "friends", "wants": "friends"}')->>'wants', 'friends');
select public.sharing_set('{"items": [{"kind": "binder", "id": "b1000000-0000-0000-0000-000000000001", "visibility": "public"}]}');
reset role;
select pg_temp.eq('settings audited once each', (select count(*)::text from public.account_audit
  where actor = '00000000-0000-0000-0000-0000000000b1' and action in ('sharing.set', 'sharing.item')), '2');
set role authenticated;
select public.sharing_set('{"for_trade": "friends", "wants": "friends"}');
reset role;
select pg_temp.eq('same values: no new audit row', (select count(*)::text from public.account_audit
  where actor = '00000000-0000-0000-0000-0000000000b1' and action in ('sharing.set', 'sharing.item')), '2');
set role authenticated;

-- Friend (Ana) vs stranger (Cal) vs owner (Ben).
select pg_temp.as_user(:ANA);
select pg_temp.eq('friend sees for trade + wants + the public binder',
  (select string_agg(k, ',' order by k) from jsonb_object_keys(public.profile_view(:BEN)->'sections') k),
  'binders,cubes,decks,for_trade,wants');
select pg_temp.eq('friend sees one binder', jsonb_array_length(public.profile_view(:BEN)->'sections'->'binders')::text, '1');
select pg_temp.eq('for-trade copies counted', pg_temp.j(public.profile_view(:BEN), '{sections,for_trade,cards}'), '7');
select pg_temp.eq('friend reads for trade', jsonb_array_length(public.profile_cards(:BEN, 'for_trade')->'rows')::text, '4');
select pg_temp.eq('wants rows never carry max price', (public.profile_cards(:BEN, 'wants')->'rows'->0)::text,
  '["c0000000-0000-0000-0000-000000000002", null, null, 4]');
select pg_temp.throws('friend: Ben box still private', $$select public.profile_cards('00000000-0000-0000-0000-0000000000b1', 'binder', 'b1000000-0000-0000-0000-000000000002')$$, '42501');
select pg_temp.throws('friend: all cards still private', $$select public.profile_cards('00000000-0000-0000-0000-0000000000b1', 'all_cards')$$, '42501');
select pg_temp.throws('friend: deck still private', $$select public.profile_cards('00000000-0000-0000-0000-0000000000b1', 'deck', 'd1000000-0000-0000-0000-000000000001')$$, '42501');
select pg_temp.as_user(:CAL);
select pg_temp.eq('stranger: the friends-only profile caps the public binder', public.profile_view(:BEN)->>'visible', 'false');
select pg_temp.throws('stranger: public binder still capped', $$select public.profile_cards('00000000-0000-0000-0000-0000000000b1', 'binder', 'b1000000-0000-0000-0000-000000000001')$$, '42501');
select pg_temp.as_user(:BEN);
select public.sharing_set('{"profile": "public"}');
select pg_temp.as_user(:CAL);
select pg_temp.eq('stranger: public profile shows only the public binder',
  (select string_agg(k || ':' || jsonb_array_length(case jsonb_typeof(v) when 'array' then v else '[]' end), ',' order by k)
     from jsonb_each(public.profile_view(:BEN)->'sections') x(k, v)), 'binders:1,cubes:0,decks:0,for_trade:0');
select pg_temp.eq('stranger: for trade = the public trade binder only',
  pg_temp.j(public.profile_view(:BEN), '{sections,for_trade,cards}'), '7');
select pg_temp.throws('stranger: wants are friends only', $$select public.profile_cards('00000000-0000-0000-0000-0000000000b1', 'wants')$$, '42501');
select pg_temp.as_user(:DEE);
select pg_temp.eq('public profiles are found by name', pg_temp.j(public.friend_search('ort'), '{0,display_name}'), 'Ben Ortiz');
select pg_temp.eq('… by the start of a word only', jsonb_array_length(public.friend_search('rtiz'))::text, '0');

-- Inherit chain: Decks → Library; a deck's own setting wins.
select pg_temp.as_user(:BEN);
select public.sharing_set('{"library": "friends"}');
select pg_temp.as_user(:ANA);
select pg_temp.eq('Library friends: friend sees all cards', pg_temp.j(public.profile_view(:BEN), '{sections,all_cards,cards}'), '9');
select pg_temp.eq('… but not their value (privacy fix 4)',
  (select string_agg(k, ',' order by k) from jsonb_object_keys(public.profile_view(:BEN)->'sections'->'all_cards') k), 'cards,printings');
select pg_temp.as_user(:BEN);
select pg_temp.eq('the owner sees the value', pg_temp.j(public.profile_view(:BEN), '{sections,all_cards,value_usd}'), '107.00');
select pg_temp.as_user(:ANA);
select pg_temp.eq('… and the deck', pg_temp.j(public.profile_view(:BEN), '{sections,decks,0,cards}'), '4');
select pg_temp.eq('deck rows include considering', jsonb_array_length(public.profile_cards(:BEN, 'deck', 'd1000000-0000-0000-0000-000000000001')->'rows')::text, '2');
select pg_temp.eq('all cards rows per printing and finish', jsonb_array_length(public.profile_cards(:BEN, 'all_cards')->'rows')::text, '4');
select pg_temp.eq('paging', public.profile_cards(:BEN, 'all_cards', null, 0, 3)->>'more', 'true');
select pg_temp.as_user(:BEN);
select public.sharing_set('{"decks": "private"}');
select pg_temp.as_user(:ANA);
select pg_temp.eq('Decks private hides the deck', jsonb_array_length(public.profile_view(:BEN)->'sections'->'decks')::text, '0');
select pg_temp.as_user(:BEN);
select public.sharing_set('{"items": [{"kind": "deck", "id": "d1000000-0000-0000-0000-000000000001", "visibility": "friends"}]}');
select pg_temp.as_user(:ANA);
select pg_temp.eq('the deck''s own setting wins', jsonb_array_length(public.profile_view(:BEN)->'sections'->'decks')::text, '1');
select pg_temp.as_user(:CAL);
select pg_temp.throws('stranger: friends deck refused', $$select public.profile_cards('00000000-0000-0000-0000-0000000000b1', 'deck', 'd1000000-0000-0000-0000-000000000001')$$, '42501');
select pg_temp.as_user(:BEN);
select public.sharing_set('{"library": "private", "items": [{"kind": "deck", "id": "d1000000-0000-0000-0000-000000000001", "visibility": null}]}');

-- Record
select public.sharing_set('{"record": "friends"}');
select pg_temp.as_user(:ANA);
select pg_temp.eq('friend sees the record', pg_temp.j(public.profile_view(:BEN), '{sections,record,match_wins}'), '0');
select pg_temp.as_user(:CAL);
select pg_temp.eq('stranger does not', ((public.profile_view(:BEN)->'sections') ? 'record')::text, 'false');

-- Trade matches -------------------------------------------------------------------------------------
-- Ana's wants vs Ben's visible for-trade copies (Bolt m10 ×3 nonfoil, ×1 foil, m11 ×2, Goyf ×1 in trades; Goyf ×2 in box).
-- Exact foil want takes the foil; printing want (m10 ×2) takes 2 m10 nonfoil; any-printing want (×4) takes
-- the last m10 nonfoil and both m11 (cheaper first after NM). Goyf ×1 from the trade binder only, over Ana's $20 max.
-- Ben wants Opt ×4 (max hidden): Ana's trade binder has 6.
select pg_temp.as_user(:ANA);
select public.trade_matches() as m \gset
select pg_temp.eq('one person matches (Ben, a friend)', jsonb_array_length((:'m'::jsonb)->'people')::text, '1');
select pg_temp.eq('it is Ben, as a friend', pg_temp.j(:'m'::jsonb, '{people,0,display_name}') || '/' || pg_temp.j(:'m'::jsonb, '{people,0,friend}'), 'Ben Ortiz/true');
select pg_temp.eq('Ben has 7 copies Ana wants', pg_temp.j(:'m'::jsonb, '{people,0,have_copies}'), '7');
select pg_temp.eq('Ben wants 4 of Ana''s', pg_temp.j(:'m'::jsonb, '{people,0,want_copies}'), '4');
select pg_temp.eq('lines (card/finish/qty/want tier)',
  (select string_agg(l->>'card_id' || ':' || (l->>'finish') || ':' || (l->>'qty') || ':' ||
                     case when l->'want'->>'finish' is not null then 'exact' when l->'want'->>'card_id' is not null then 'printing' else 'any' end
                     || case when (l->>'over_max')::boolean then ':over' else '' end, ' ' order by l->>'card_id', l->>'finish')
     from jsonb_array_elements((:'m'::jsonb)->'people'->0->'they_have') l),
  'c1000000-0000-0000-0000-000000000001:foil:1:exact c1000000-0000-0000-0000-000000000001:nonfoil:3:printing c1000000-0000-0000-0000-000000000003:nonfoil:2:any c1000000-0000-0000-0000-000000000004:nonfoil:1:any:over');
select pg_temp.eq('have value skips over-max lines', pg_temp.j(:'m'::jsonb, '{people,0,have_usd}'), '17.00');
select pg_temp.eq('they want: Opt ×4 from Ana''s trade binder',
  (select l->>'card_id' || ':' || (l->>'qty') || ':' || (l->>'binder_id') from jsonb_array_elements((:'m'::jsonb)->'people'->0->'they_want') l),
  'c1000000-0000-0000-0000-000000000002:4:b3000000-0000-0000-0000-000000000001');
select pg_temp.eq('Ben''s max price never shows', (((:'m'::jsonb)->'people'->0->'they_want'->0->'want') ? 'max_usd')::text, 'false');

-- Cal (played with, not a friend) matches only once his For trade is public.
select pg_temp.as_user(:CAL);
select public.sharing_set('{"profile": "public", "for_trade": "public"}');
select pg_temp.as_user(:ANA);
select pg_temp.eq('played-with + public: Cal matches too', jsonb_array_length(public.trade_matches()->'people')::text, '2');
select pg_temp.eq('Cal has Goyf', pg_temp.j(public.trade_matches(:CAL), '{people,0,they_have,0,card_id}'), 'c1000000-0000-0000-0000-000000000004');
select pg_temp.as_user(:DEE);
select pg_temp.eq('Dee (blocked by Ana) never matches Ana', jsonb_array_length(public.trade_matches(:ANA)->'people')::text, '0');
select pg_temp.eq('Dee sees Cal''s public trades only on asking', jsonb_array_length(public.trade_matches()->'people')::text, '0');
select public.wants_apply(jsonb_build_array(jsonb_build_object('oracle_id', :GOYF_O, 'qty', 1)), 'e2000000-0000-0000-0000-000000000006');
select pg_temp.eq('Dee asks about Cal (public)', pg_temp.j(public.trade_matches(:CAL), '{people,0,have_copies}'), '1');

-- Starting a trade from a match.
select pg_temp.as_user(:ANA);
select public.trade_match_start(:BEN, 'f3000000-0000-0000-0000-000000000001') as t \gset
select pg_temp.eq('draft with Ben', (:'t'::jsonb)->>'partner' || '/' || ((:'t'::jsonb)->>'partner_id') || '/' || ((:'t'::jsonb)->>'status'),
  'Ben Ortiz/00000000-0000-0000-0000-0000000000b1/draft');
select pg_temp.eq('gets = they have', jsonb_array_length((:'t'::jsonb)->'gets')::text, '4');
select pg_temp.eq('gives carry the binder', pg_temp.j(:'t'::jsonb, '{gives,0,binder_id}'), 'b3000000-0000-0000-0000-000000000001');
select pg_temp.eq('same key: same draft', public.trade_match_start(:BEN, 'f3000000-0000-0000-0000-000000000001')->>'duplicate', 'true');
reset role;
select pg_temp.eq('one draft written', (select count(*)::text from public.trades where user_id = '00000000-0000-0000-0000-0000000000a1'), '1');
set role authenticated;
select pg_temp.eq('trade_save keeps partner_id',
  public.trade_save('f3000000-0000-0000-0000-000000000001', 'Ben', null, '[]'::jsonb, (:'t'::jsonb)->'gets')->>'partner_id',
  '00000000-0000-0000-0000-0000000000b1');
select pg_temp.as_user(:BEN);
select pg_temp.throws('someone else''s key refused', $$select public.trade_match_start('00000000-0000-0000-0000-0000000000a1', 'f3000000-0000-0000-0000-000000000001')$$, '22023');
select pg_temp.as_user(:CAL);
select pg_temp.throws('nothing to trade', $$select public.trade_match_start('00000000-0000-0000-0000-0000000000b1', gen_random_uuid())$$, '22023');
select pg_temp.as_user(:DEE);
select pg_temp.throws('blocked: refused', $$select public.trade_match_start('00000000-0000-0000-0000-0000000000a1', gen_random_uuid())$$, '42501');

-- Add players: friends first.
select pg_temp.as_user(:ANA);
select pg_temp.eq('friends first, then played with',
  (select string_agg(display_name || ':' || friend || ':' || shared_events, ',' order by ord)
     from (select *, row_number() over () ord from public.suggested_players('e1000000-0000-0000-0000-000000000002')) s),
  'Ben Ortiz:true:0,Cal Reyes:false:1');
select pg_temp.eq('search narrows friends too', (select string_agg(display_name, ',') from public.suggested_players('e1000000-0000-0000-0000-000000000002', 'ben')), 'Ben Ortiz');

-- Signed out: refused.
set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('anon cannot ask', $$select public.friend_request('00000000-0000-0000-0000-0000000000b1')$$);
select pg_temp.throws('anon cannot view profiles', $$select public.profile_view('00000000-0000-0000-0000-0000000000b1')$$);
select pg_temp.throws('anon cannot match', $$select public.trade_matches()$$);
select pg_temp.throws('anon cannot read sharing', $$select public.sharing_get()$$);
reset role;

-- Account deletion clears friendships, blocks, sharing and audit rows; other people's drafts lose partner_id.
set role authenticated;
select pg_temp.as_user(:BEN);
select public.delete_account();
reset role;
select pg_temp.eq('friendships gone', (select count(*)::text from public.friendships where '00000000-0000-0000-0000-0000000000b1' in (user_lo, user_hi)), '0');
select pg_temp.eq('sharing gone', (select count(*)::text from public.share_settings where user_id = '00000000-0000-0000-0000-0000000000b1'), '0');
select pg_temp.eq('audit gone', (select count(*)::text from public.account_audit where '00000000-0000-0000-0000-0000000000b1' in (actor, target_user)), '0');
select pg_temp.eq('Ana''s draft keeps the name, not the id', (select coalesce(partner_id::text, 'null') from public.trades where id = 'f3000000-0000-0000-0000-000000000001'), 'null');
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('Ana no longer matches Ben', jsonb_array_length(public.trade_matches(:BEN)->'people')::text, '0');
select pg_temp.as_user(:DEE);
select pg_temp.as_user(:ANA);
select pg_temp.eq('Ana unblocks Dee', public.user_block(:DEE, false)->>'blocked', 'false');
reset role;
