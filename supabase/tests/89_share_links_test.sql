-- Share links: "Anyone with the link" (contract/share-links-2026-10-23.md).
\ir _helpers.sql

-- Ana shares; Ben is a stranger; Fay blocks Ana; Eve is deleted.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}'),
  ('00000000-0000-0000-0000-0000000000a2', 'fay@example.com', '{"full_name": "Fay Moss"}'),
  ('00000000-0000-0000-0000-0000000000e1', 'eve@example.com', '{"full_name": "Eve Gone"}');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''
\set FAY '''00000000-0000-0000-0000-0000000000a2'''
\set EVE '''00000000-0000-0000-0000-0000000000e1'''

insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000002', 'Opt', 'opt', 'normal', 'c1000000-0000-0000-0000-000000000002', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil,foil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'xln', '65', 'en', 'common', '{nonfoil}', 'normal', 'h');
insert into public.card_prices (card_id, usd) values ('c1000000-0000-0000-0000-000000000001', 2.00);
\set BOLT '''c1000000-0000-0000-0000-000000000001'''
\set OPT '''c1000000-0000-0000-0000-000000000002'''
\set OPT_O '''c0000000-0000-0000-0000-000000000002'''
\set DECK '''d1000000-0000-0000-0000-000000000001'''
\set CUBE '''d1000000-0000-0000-0000-000000000002'''
\set TRADES '''b1000000-0000-0000-0000-000000000001'''
\set BOX '''b1000000-0000-0000-0000-000000000002'''

create or replace function pg_temp.tok(v jsonb) returns text language sql as $$ select v->>'token' $$;

set role authenticated;
select pg_temp.as_user(:ANA);
-- Everything private, the profile too.
select public.sharing_set('{"profile": "private"}');
select public.binder_save(:TRADES, 'Trades', true);
select public.binder_save(:BOX, 'Box', false);
select public.collection_apply(jsonb_build_array(
  jsonb_build_object('card_id', :BOLT, 'delta', 3, 'binder_id', :TRADES),
  jsonb_build_object('card_id', :BOLT, 'finish', 'foil', 'delta', 1, 'binder_id', :BOX),
  jsonb_build_object('card_id', :OPT, 'delta', 2)), 'manual', null, 'e2000000-0000-0000-0000-000000000001');
select public.wants_apply(jsonb_build_array(jsonb_build_object('oracle_id', :OPT_O, 'qty', 4, 'max_usd', 0.05)),
  'e2000000-0000-0000-0000-000000000002');
select public.list_create(:DECK, 'deck', 'Burn', 'modern',
  jsonb_build_array(jsonb_build_array(:BOLT, 'main', 4), jsonb_build_array(:OPT, 'maybe', 1)));
select public.list_create(:CUBE, 'cube', 'Pauper cube', 'cube', jsonb_build_array(jsonb_build_array(:OPT, 'main', 1)));

-- Making links ---------------------------------------------------------------------------------
select pg_temp.tok(public.share_link_create('deck', :DECK)) deck_tok \gset
select pg_temp.eq('a link is 22 url-safe characters', (:'deck_tok' ~ '^[A-Za-z0-9_-]{22}$')::text, 'true');
select pg_temp.eq('asking again returns the same link', pg_temp.tok(public.share_link_create('deck', :DECK)), :'deck_tok');
select pg_temp.tok(public.share_link_create('all_cards')) all_tok \gset
select pg_temp.tok(public.share_link_create('for_trade')) trade_tok \gset
select pg_temp.tok(public.share_link_create('wants')) wants_tok \gset
select pg_temp.tok(public.share_link_create('binder', :BOX)) box_tok \gset
select pg_temp.eq('sharing_get lists the live links',
  (select string_agg(l->>'part', ',' order by l->>'part') from jsonb_array_elements(public.sharing_get()->'links') l),
  'all_cards,binder,deck,for_trade,wants');
select pg_temp.eq('the settings are untouched', (public.sharing_get()->>'profile') || '/' ||
  (select coalesce(i->>'visibility', 'same') from jsonb_array_elements(public.sharing_get()->'items') i where i->>'id' = :DECK),
  'private/private');
reset role;
select pg_temp.eq('audited', (select count(*)::text from public.account_audit where action = 'sharing.link'), '5');
set role authenticated;

select pg_temp.throws('a part takes no id', $$select public.share_link_create('wants', 'd1000000-0000-0000-0000-000000000001')$$, '22023');
select pg_temp.throws('an item needs its id', $$select public.share_link_create('deck')$$, '22023');
select pg_temp.throws('unknown part', $$select public.share_link_create('record')$$, '22023');
select pg_temp.throws('a deck is not a cube', $$select public.share_link_create('cube', 'd1000000-0000-0000-0000-000000000001')$$, '42501');
select pg_temp.as_user(:BEN);
select pg_temp.throws('not your deck', $$select public.share_link_create('deck', 'd1000000-0000-0000-0000-000000000001')$$, '42501');
select pg_temp.eq('revoking someone else''s link does nothing',
  public.share_link_revoke('deck', :DECK)->>'revoked', 'false');
select pg_temp.throws('no table reads', $$select count(*) from public.share_links$$, '42501');

-- Opening links: a stranger, then signed out ----------------------------------------------------
select pg_temp.throws('the profile is private to Ben', $$select public.profile_cards('00000000-0000-0000-0000-0000000000a1', 'deck', 'd1000000-0000-0000-0000-000000000001')$$, '42501');
select pg_temp.eq('but the link opens the deck for him',
  (select v->>'part' || '|' || (v->>'name') || '|' || (v->>'format') || '|' || (v->>'cards') || '|' || (v->'owner'->>'display_name') || '|' || (v->>'mine')
     from public.shared_view(:'deck_tok') v), 'deck|Burn|modern|4|Ana Lind|false');
select pg_temp.eq('no owner id, handle or value', (select (v ? 'user_id')::text || (v->'owner' ? 'user_id')::text || (v->'owner' ? 'handle')::text
  from public.shared_view(:'all_tok') v), 'falsefalsefalse');
select pg_temp.eq('deck cards in profile_cards'' shape', public.shared_cards(:'deck_tok')::text,
  '{"more": false, "rows": [["c1000000-0000-0000-0000-000000000001", "main", 4], ["c1000000-0000-0000-0000-000000000002", "maybe", 1]]}');
select pg_temp.as_user(null);
set role anon;
select pg_temp.eq('signed out sees it too', public.shared_view(:'deck_tok')->>'name', 'Burn');
select pg_temp.eq('all cards: every copy, no value', (select (v->>'cards') || '|' || (v ? 'value_usd')::text from public.shared_view(:'all_tok') v), '6|false');
select pg_temp.eq('all cards rows', jsonb_array_length(public.shared_cards(:'all_tok')->'rows')::text, '3');
select pg_temp.eq('for trade: only for-trade binders', public.shared_cards(:'trade_tok')->'rows'->0->>4 || '/' ||
  jsonb_array_length(public.shared_cards(:'trade_tok')->'rows'), '3/1');
select pg_temp.eq('wants without max prices', public.shared_cards(:'wants_tok')::text,
  '{"more": false, "rows": [["c0000000-0000-0000-0000-000000000002", null, null, 4]]}');
select pg_temp.eq('a binder that isn''t for trade', (select (v->>'name') || '|' || (v->>'for_trade') || '|' || (v->>'cards')
  from public.shared_view(:'box_tok') v), 'Box|false|1');
select pg_temp.eq('paged', public.shared_cards(:'all_tok', 2, 2)::text,
  '{"more": false, "rows": [["c1000000-0000-0000-0000-000000000002", "nonfoil", 2]]}');
select pg_temp.throws('a made-up link', $$select public.shared_view('AAAAAAAAAAAAAAAAAAAAAA')$$, '42501');
select pg_temp.throws('the cube has no link', $$select public.profile_cards('00000000-0000-0000-0000-0000000000a1', 'cube', 'd1000000-0000-0000-0000-000000000002')$$);
select pg_temp.throws('anon cannot make links', $$select public.share_link_create('all_cards')$$);
select pg_temp.throws('anon cannot read sharing', $$select public.sharing_get()$$);
set role authenticated;

-- Blocks still win when signed in ----------------------------------------------------------------
select pg_temp.as_user(:FAY);
select public.user_block(:ANA, true);
select pg_temp.throws('Fay blocked Ana: the link is closed to Fay', format('select public.shared_view(%L)', :'deck_tok'), '42501');
select pg_temp.as_user(:ANA);
select pg_temp.eq('the owner sees her own link as hers', public.shared_view(:'deck_tok')->>'mine', 'true');

-- New link and Stop sharing ------------------------------------------------------------------------
select pg_temp.tok(public.share_link_create('deck', :DECK, true)) deck_tok2 \gset
select pg_temp.eq('a new link is a different one', (:'deck_tok2' <> :'deck_tok')::text, 'true');
select pg_temp.throws('the old one stops working', format('select public.shared_view(%L)', :'deck_tok'), '42501');
select pg_temp.eq('the new one works', public.shared_view(:'deck_tok2')->>'name', 'Burn');
select pg_temp.eq('still one live deck link', (select count(*)::text from jsonb_array_elements(public.sharing_get()->'links') l
  where l->>'part' = 'deck'), '1');
select pg_temp.eq('stop sharing', public.share_link_revoke('deck', :DECK)->>'revoked', 'true');
select pg_temp.eq('stopping again is no change', public.share_link_revoke('deck', :DECK)->>'revoked', 'false');
select pg_temp.throws('stopped means closed', format('select public.shared_cards(%L)', :'deck_tok2'), '42501');
reset role;
select pg_temp.eq('one audit row per change', (select count(*)::text from public.account_audit where action = 'sharing.link'), '7');
set role authenticated;

-- Deleted parts close their links ----------------------------------------------------------------
select public.binder_delete(:BOX);
select pg_temp.throws('a deleted binder', format('select public.shared_view(%L)', :'box_tok'), '42501');
select pg_temp.eq('and it leaves sharing_get', (select count(*)::text from jsonb_array_elements(public.sharing_get()->'links') l
  where l->>'part' = 'binder'), '0');

-- Moderation ------------------------------------------------------------------------------------------
reset role;
select pg_temp.eq('a private cube''s name is not checked',
  (select count(*)::text from public.moderation_checks where subject_id = :CUBE), '0');
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.tok(public.share_link_create('cube', :CUBE)) cube_tok \gset
reset role;
select pg_temp.eq('a link queues the name', (select string_agg(subject_kind || ':' || content, ',') from public.moderation_checks
  where subject_id = :CUBE), 'list_name:Pauper cube');
select pg_temp.eq('item_visible counts the link', t1_private.item_visible('list', :CUBE)::text, 'true');
-- Moderation unshares the cube: the link stops showing it until the action is reverted or the cube is renamed.
insert into public.moderation_actions (check_id, owner, subject_kind, subject_id, action, category, label, before, replaced)
select id, :ANA, 'list_name', :CUBE, 'unshare', 'hate', 'Cube Pauper cube', '{}', '{}'
  from public.moderation_checks where subject_id = :CUBE;
set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('unshared by moderation', format('select public.shared_view(%L)', :'cube_tok'), '42501');
reset role;
update public.card_lists set name = 'Peasant cube' where id = :CUBE;
set role anon;
select pg_temp.eq('a new name shows again (and is checked again)', public.shared_view(:'cube_tok')->>'name', 'Peasant cube');
reset role;
select pg_temp.eq('the rename was queued', (select count(*)::text from public.moderation_checks where subject_id = :CUBE), '2');

-- Account deletion removes links; a deleted owner reads the same as a bad link ---------------------------
update public.profiles set deleted_at = now() where id = :ANA;
select pg_temp.eq('links removed', (select count(*)::text from public.share_links where user_id = :ANA), '0');
set role anon;
select pg_temp.throws('closed after deletion', format('select public.shared_view(%L)', :'all_tok'), '42501');
