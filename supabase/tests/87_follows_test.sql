-- Following decks, cubes and binders (contract/follows-2026-10-25.md).
\ir _helpers.sql

-- Ana shares; Ben is her friend (and deletes his account at the end); Cal is a stranger with a link.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com', '{"full_name": "Cal Reyes"}');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''
\set CAL '''00000000-0000-0000-0000-0000000000c1'''

insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000002', 'Opt', 'opt', 'normal', 'c1000000-0000-0000-0000-000000000002', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000003', 'Counterspell', 'counterspell', 'normal', 'c1000000-0000-0000-0000-000000000003', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil,foil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'xln', '65', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000003', 'mh2', '267', 'en', 'common', '{nonfoil}', 'normal', 'h');
\set BOLT '''c1000000-0000-0000-0000-000000000001'''
\set OPT '''c1000000-0000-0000-0000-000000000002'''
\set CS '''c1000000-0000-0000-0000-000000000003'''
\set DECK '''d1000000-0000-0000-0000-000000000001'''
\set CUBE '''d1000000-0000-0000-0000-000000000002'''
\set TRADES '''b1000000-0000-0000-0000-000000000001'''

-- Due now: as if the last change was 31 minutes ago (and, with `gap`, the last update 7 hours ago).
create or replace function pg_temp.settle(gap boolean default false) returns integer language sql as $$
  update t1_private.follow_items set dirty_last = dirty_last - interval '31 minutes' where dirty_last is not null;
  update t1_private.follow_items set announced_at = announced_at - interval '7 hours' where gap and announced_at is not null;
  select t1_private.follow_digest();
$$;
create or replace function pg_temp.pushes() returns text language sql as $$
  select coalesce(string_agg((select string_agg(right(u, 2), '+' order by u) from jsonb_array_elements_text(msg->'user_ids') u)
                             || ':' || (msg->'data'->>'added') || '-' || (msg->'data'->>'removed'), ',' order by msg_id), '')
    from pgmq.messages where msg->>'kind' = 'follow.updated';
$$;

set role authenticated;
select pg_temp.as_user(:BEN);
select public.friend_request(:ANA);
select pg_temp.as_user(:ANA);
select public.friend_respond(:BEN, true);
select public.binder_save(:TRADES, 'Trades', true);
select public.list_create(:DECK, 'deck', 'Burn', 'modern', jsonb_build_array(jsonb_build_array(:BOLT, 'main', 4)));
select public.list_create(:CUBE, 'cube', 'Pauper cube', 'cube', jsonb_build_array(jsonb_build_array(:OPT, 'main', 1)));
select public.sharing_set(jsonb_build_object('items', jsonb_build_array(
  jsonb_build_object('kind', 'deck', 'id', :DECK, 'visibility', 'friends'),
  jsonb_build_object('kind', 'binder', 'id', :TRADES, 'visibility', 'friends'))));
select (public.share_link_create('cube', :CUBE))->>'token' cube_tok \gset

-- Following -------------------------------------------------------------------------------------------------
select pg_temp.throws('your own deck', $$select public.follow_set('deck', 'd1000000-0000-0000-0000-000000000001', true)$$, '22023');
select pg_temp.throws('a part is not followable', $$select public.follow_set('wants', 'd1000000-0000-0000-0000-000000000001', true)$$, '22023');
select pg_temp.as_user(:BEN);
select pg_temp.eq('not following yet', public.follow_get('deck', :DECK)::text,
  '{"push": true, "unseen": 0, "following": false, "last_update": null}');
select pg_temp.eq('Ben follows the deck', public.follow_set('deck', :DECK, true)::text,
  '{"push": true, "unseen": 0, "following": true, "last_update": null}');
select pg_temp.eq('following again is no change', public.follow_set('deck', :DECK, true)->>'following', 'true');
select pg_temp.throws('the cube isn''t shared with Ben', $$select public.follow_set('cube', 'd1000000-0000-0000-0000-000000000002', true)$$, '42501');
select pg_temp.throws('a deck id is not a cube', $$select public.follow_set('cube', 'd1000000-0000-0000-0000-000000000001', true)$$, '42501');
select pg_temp.throws('something that doesn''t exist', $$select public.follow_set('deck', 'd1000000-0000-0000-0000-0000000000ff', true)$$, '42501');
select pg_temp.eq('unknown reads as not following', public.follow_get('deck', 'd1000000-0000-0000-0000-0000000000ff')->>'following', 'false');
select pg_temp.throws('no table reads', $$select count(*) from public.follows$$, '42501');
select pg_temp.as_user(:CAL);
select pg_temp.throws('Cal can''t see the deck', $$select public.follow_set('deck', 'd1000000-0000-0000-0000-000000000001', true)$$, '42501');
select pg_temp.throws('or the cube without its link', $$select public.follow_set('cube', 'd1000000-0000-0000-0000-000000000002', true)$$, '42501');
select pg_temp.eq('through the link he can', public.follow_set('cube', :CUBE, true, null, :'cube_tok')->>'following', 'true');
select pg_temp.as_user(null);
set role anon;
select pg_temp.throws('signed out cannot follow', $$select public.follow_set('cube', 'd1000000-0000-0000-0000-000000000002', true)$$);
select pg_temp.throws('or list', $$select public.follows_list()$$);
reset role;
select pg_temp.eq('audited once per follow', (select count(*)::text from public.account_audit where action = 'follow.set'), '2');
select pg_temp.eq('one row per followed item', (select count(*)::text from t1_private.follow_items), '2');

-- Changes are grouped -------------------------------------------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_edit(:DECK, jsonb_build_array(jsonb_build_object('card_id', :OPT, 'board', 'main', 'delta', 2)));
select public.list_edit(:DECK, jsonb_build_array(jsonb_build_object('card_id', :CS, 'board', 'side', 'delta', 1)));
select public.list_edit(:DECK, jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'board', 'main', 'delta', -1)));
select public.list_edit(:DECK, jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'board', 'maybe', 'delta', 1)));
reset role;
select pg_temp.eq('a change stamps the deck', (select (dirty_last is not null)::text from t1_private.follow_items where item_id = :DECK), 'true');
select pg_temp.eq('an unfollowed binder is not tracked', (select count(*)::text from t1_private.follow_items where item_id = :TRADES), '0');
select pg_temp.eq('nothing goes out while it''s still being edited', t1_private.follow_digest()::text, '0');
select pg_temp.eq('quiet for 30 minutes: one update', pg_temp.settle()::text, '1');
select pg_temp.eq('net of the edits, Considering left out',
  (select added || '-' || removed || ' ' || cards::text from t1_private.follow_updates where item_id = :DECK),
  '3-1 [["c1000000-0000-0000-0000-000000000002", "main", 2], ["c1000000-0000-0000-0000-000000000003", "side", 1], ["c1000000-0000-0000-0000-000000000001", "main", -1]]');
select pg_temp.eq('one push to Ben', pg_temp.pushes(), 'b1:3-1');
select pg_temp.eq('with names, most copies first',
  (select (msg->'data'->>'name') || '|' || (msg->'data'->>'owner_name') || '|' || (msg->'data'->'in')::text || (msg->'data'->>'in_n')
          || '|' || (msg->'data'->'out')::text || (msg->'data'->>'out_n') || '|' || (msg->'data'->>'kind')
     from pgmq.messages where msg->>'kind' = 'follow.updated'),
  'Burn|Ana Lind|["Opt", "Counterspell"]2|["Lightning Bolt"]1|deck');
select pg_temp.eq('the stamp is cleared', (select (dirty_last is null)::text from t1_private.follow_items where item_id = :DECK), 'true');

set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_edit(:DECK, jsonb_build_array(jsonb_build_object('card_id', :OPT, 'board', 'main', 'delta', 1)));
reset role;
select pg_temp.eq('within 6 hours of the last update it waits', pg_temp.settle()::text, '0');
select pg_temp.eq('and stays stamped', (select (dirty_last is not null)::text from t1_private.follow_items where item_id = :DECK), 'true');
set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_edit(:DECK, jsonb_build_array(jsonb_build_object('card_id', :CS, 'board', 'main', 'delta', 2)));
reset role;
select pg_temp.eq('6 hours later the waiting changes go as one', pg_temp.settle(true)::text, '1');
select pg_temp.eq('the second update', (select added || '-' || removed from t1_private.follow_updates where item_id = :DECK order by id desc limit 1), '3-0');
select pg_temp.eq('second push', pg_temp.pushes(), 'b1:3-1,b1:3-0');

set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_edit(:DECK, jsonb_build_array(jsonb_build_object('card_id', :OPT, 'board', 'main', 'delta', 1)));
select public.list_edit(:DECK, jsonb_build_array(jsonb_build_object('card_id', :OPT, 'board', 'main', 'delta', -1)));
reset role;
select pg_temp.eq('edits that cancel out send nothing', pg_temp.settle(true)::text, '0');
select pg_temp.eq('but clear the stamp', (select (dirty_last is null)::text from t1_private.follow_items where item_id = :DECK), 'true');

-- Reading --------------------------------------------------------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:BEN);
select pg_temp.eq('two unseen', (select (s->>'unseen') || '|' || (s->'last_update'->>'added') || '-' || (s->'last_update'->>'removed')
  from public.follow_get('deck', :DECK) s), '2|3-0');
select pg_temp.eq('Following: the deck through her profile',
  (select (i->>'name') || '|' || (i->>'format') || '|' || (i->>'cards') || '|' || (i->'owner'->>'display_name') || '|' || (i->>'user_id')
          || '|' || (i ? 'token')::text || '|' || (i->>'unseen') || '|' || (i->>'available')
     from jsonb_array_elements(public.follows_list()->'items') i),
  'Burn|modern|9|Ana Lind|00000000-0000-0000-0000-0000000000a1|false|2|true');
select pg_temp.eq('Changes: newest first, with the cards',
  (select string_agg((u->>'added') || '-' || (u->>'removed') || ':' || jsonb_array_length(u->'cards'), ',')
     from jsonb_array_elements(public.follow_changes('deck', :DECK)->'updates') u), '3-0:2,3-1:3');
select pg_temp.eq('opening them marks them seen', public.follow_get('deck', :DECK)->>'unseen', '0');
select pg_temp.throws('changes need a follow', $$select public.follow_changes('cube', 'd1000000-0000-0000-0000-000000000002')$$, '42501');
select pg_temp.as_user(:CAL);
select pg_temp.eq('Cal''s cube opens through his link, never her id',
  (select (i->>'name') || '|' || (i ? 'user_id')::text || '|' || ((i->>'token') = :'cube_tok')::text
     from jsonb_array_elements(public.follows_list()->'items') i), 'Pauper cube|false|true');
select pg_temp.eq('Cal sees no history from before he followed', jsonb_array_length(public.follow_changes('cube', :CUBE)->'updates')::text, '0');

-- Pushes off, links stopped, blocks and narrowing ---------------------------------------------------------------
select pg_temp.as_user(:BEN);
select pg_temp.eq('pushes off', public.follow_set('deck', :DECK, true, false)->>'push', 'false');
select public.follow_set('binder', :TRADES, true);
select pg_temp.as_user(:ANA);
select public.list_edit(:DECK, jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'board', 'main', 'delta', 1)));
select public.list_edit(:CUBE, jsonb_build_array(jsonb_build_object('card_id', :CS, 'board', 'main', 'delta', 1)));
select public.collection_apply(jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'delta', 2, 'binder_id', :TRADES)),
  'manual', null, 'e2000000-0000-0000-0000-000000000001');
select public.share_link_revoke('cube', :CUBE);
reset role;
select pg_temp.eq('three updates', pg_temp.settle(true)::text, '3');
select pg_temp.eq('only the binder pushes: deck pushes are off, Cal''s link is gone', pg_temp.pushes(), 'b1:3-1,b1:3-0,b1:2-0');
select pg_temp.eq('binders compare by printing, no board',
  (select cards::text from t1_private.follow_updates where item_id = :TRADES), '[["c1000000-0000-0000-0000-000000000001", null, 2]]');
set role authenticated;
select pg_temp.as_user(:BEN);
select pg_temp.eq('the deck still shows its update', public.follow_get('deck', :DECK)->>'unseen', '1');
select pg_temp.as_user(:CAL);
select pg_temp.eq('Cal: not available, nothing else said', ((select i::text from jsonb_array_elements(public.follows_list()->'items') i
  where i->>'id' = :CUBE) ~ '^\{"id": "d1000000-0000-0000-0000-000000000002", "kind": "cube", "push": true, "unseen": 0, "available": false, "followed_at": ".*"\}$')::text, 'true');
select pg_temp.throws('and no changes', $$select public.follow_changes('cube', 'd1000000-0000-0000-0000-000000000002')$$, '42501');
select pg_temp.eq('Cal unfollows what he can''t see', public.follow_set('cube', :CUBE, false)->>'following', 'false');
reset role;
select pg_temp.eq('the last follower leaving drops the item and its history',
  (select count(*)::text from t1_private.follow_items where item_id = :CUBE) || (select count(*)::text from t1_private.follow_updates where item_id = :CUBE), '00');

set role authenticated;
select pg_temp.as_user(:ANA);
select public.user_block(:BEN, true);
select pg_temp.as_user(:BEN);
select pg_temp.eq('blocked: nothing available', (select string_agg(i->>'available', ',') from jsonb_array_elements(public.follows_list()->'items') i), 'false,false');
select pg_temp.as_user(:ANA);
select public.user_block(:BEN, false);
select pg_temp.as_user(:BEN);
select pg_temp.eq('unblocked but no longer friends: still hidden', (select string_agg(i->>'available', ',') from jsonb_array_elements(public.follows_list()->'items') i), 'false,false');
select public.friend_request(:ANA);
select pg_temp.as_user(:ANA);
select public.friend_respond(:BEN, true);
select pg_temp.as_user(:BEN);
select pg_temp.eq('friends again: both back', (select string_agg(i->>'available', ',') from jsonb_array_elements(public.follows_list()->'items') i), 'true,true');
select pg_temp.as_user(:ANA);
select public.sharing_set(jsonb_build_object('items', jsonb_build_array(jsonb_build_object('kind', 'deck', 'id', :DECK, 'visibility', 'private'))));
select public.list_edit(:DECK, jsonb_build_array(jsonb_build_object('card_id', :BOLT, 'board', 'main', 'delta', 1)));
select pg_temp.as_user(:BEN);
select pg_temp.throws('Ben can''t turn pushes on for a deck made private', $$select public.follow_set('deck', 'd1000000-0000-0000-0000-000000000001', true, true)$$, '42501');
reset role;
update public.follows set push = true where item_id = :DECK;
select pg_temp.eq('narrowed: the update is kept, nobody is told', pg_temp.settle(true)::text || '|' || pg_temp.pushes(), '1|b1:3-1,b1:3-0,b1:2-0');

-- Account deletion ------------------------------------------------------------------------------------------------
update public.profiles set deleted_at = now() where id = :BEN;
select pg_temp.eq('a deleted account''s follows go, and items nobody else follows with them',
  (select count(*)::text from public.follows) || (select count(*)::text from t1_private.follow_items), '00');
