-- Table 1 for Discord (20261029130000_discord, contract/discord-2026-10-29.md): links, acting as the account,
-- events posted in a server, sign-ups and drops through the bot, results, settings, decks, cards, grants.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'bea@example.com'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com'),
  ('00000000-0000-0000-0000-0000000000d1', 'dee@example.com'),
  ('00000000-0000-0000-0000-0000000000e1', 'eli@example.com'),
  ('00000000-0000-0000-0000-0000000000f1', 'fay@example.com');
\set A '''00000000-0000-0000-0000-0000000000a1'''
\set B '''00000000-0000-0000-0000-0000000000b1'''
\set C '''00000000-0000-0000-0000-0000000000c1'''
\set D '''00000000-0000-0000-0000-0000000000d1'''
\set E '''00000000-0000-0000-0000-0000000000e1'''
\set F '''00000000-0000-0000-0000-0000000000f1'''
update public.profiles set display_name = 'Ana' where id = :A;
update public.profiles set display_name = 'Bea' where id = :B;
update public.profiles set display_name = 'Dee' where id = :D;
update public.profiles set display_name = 'Eli' where id = :E;
update public.profiles set display_name = 'Fay' where id = :F;

-- Cards for /deck and /card.
insert into public.card_oracles (oracle_id, name, name_norm, layout, type_line, mana_cost, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'Instant', '{R}', 'c1000000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000002', 'Opt', 'opt', 'normal', 'Instant', '{U}', 'c1000000-0000-0000-0000-000000000002', 'a', 'h');
insert into public.card_names (name_norm, oracle_id) values
  ('lightning bolt', 'c0000000-0000-0000-0000-000000000001'), ('opt', 'c0000000-0000-0000-0000-000000000002');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash, image_ts) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil,foil}', 'normal', 'h', 1700000000),
  ('c1000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000001', 'sta', '42', 'en', 'rare', '{nonfoil,foil}', 'normal', 'h', 1700000001),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'xln', '65', 'en', 'common', '{nonfoil}', 'normal', 'h', null);
insert into public.card_prices (card_id, usd, usd_foil) values
  ('c1000000-0000-0000-0000-000000000001', 1.50, 9.00), ('c1000000-0000-0000-0000-000000000003', 4.00, 20.00);
\set BOLT '''c1000000-0000-0000-0000-000000000001'''
\set OPT '''c1000000-0000-0000-0000-000000000002'''

-- Linking ----------------------------------------------------------------------------------------------
select pg_temp.eq('an unknown Discord user is not linked', public.discord_me('100001')->>'linked', 'false');
select public.discord_link_start('100001') as s1 \gset
select pg_temp.eq('/link makes a token', (((:'s1'::jsonb)->>'linked')) || '|' || length(((:'s1'::jsonb)->>'token'))::text, 'false|32');
select pg_temp.eq('tokens are kept hashed', (select count(*)::text from t1_private.discord_link_tokens where token_hash = ((:'s1'::jsonb)->>'token')), '0');
select public.discord_link_start('100001') as s2 \gset
select pg_temp.eq('a new /link replaces the old token', (select count(*)::text from t1_private.discord_link_tokens where discord_user_id = '100001'), '1');
select pg_temp.throws('a bad Discord id is refused', $$select public.discord_link_start('not-an-id')$$, '22023');

set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.throws('the old token no longer works', format($$select public.discord_link_confirm(%L)$$, ((:'s1'::jsonb)->>'token')), '22023');
select public.discord_link_confirm(((:'s2'::jsonb)->>'token')) as c1 \gset
select pg_temp.eq('confirming links the signed-in account', ((:'c1'::jsonb)->>'linked'), 'true');
select pg_temp.throws('a token is single-use', format($$select public.discord_link_confirm(%L)$$, ((:'s2'::jsonb)->>'token')), '22023');
select pg_temp.eq('status says linked via /link', public.discord_link_status()->>'via', 'link');
reset role;
select pg_temp.eq('the bot now knows the account', public.discord_me('100001')->>'user_id', :A);
select pg_temp.eq('and how', public.discord_me('100001')->>'via', 'link');
select pg_temp.eq('linking is audited without the Discord id',
  (select count(*)::text || '|' || bool_and(coalesce(a.after::text, '') not like '%1001%')::text from public.account_audit a where a.actor = :A and a.action = 'discord.linked'), '1|true');
select pg_temp.eq('/link for a linked user says so', public.discord_link_start('100001')->>'display_name', 'Ana');

-- An expired token.
insert into t1_private.discord_link_tokens (token_hash, discord_user_id, expires_at)
values (encode(extensions.digest('expired-token', 'sha256'), 'hex'), '100009', now() - interval '1 minute');
set role authenticated;
select pg_temp.as_user(:C);
select pg_temp.throws('an expired token is refused', $$select public.discord_link_confirm('expired-token')$$, '22023');
reset role;

-- Another account can't take a Discord user that's already linked.
select public.discord_link_start('100001') as s3 \gset
insert into t1_private.discord_link_tokens (token_hash, discord_user_id, expires_at)
values (encode(extensions.digest('taken-token', 'sha256'), 'hex'), '100001', now() + interval '5 minutes');
set role authenticated;
select pg_temp.as_user(:C);
select pg_temp.throws('a Discord user linked elsewhere is refused', $$select public.discord_link_confirm('taken-token')$$, '23505');
reset role;

-- Signing in with Discord links by itself (the identity's provider_id is the Discord user id).
insert into auth.identities (user_id, provider, provider_id) values (:B, 'discord', '100002'), (:D, 'discord', '100004'),
  (:E, 'discord', '100005'), (:F, 'discord', '100006');
select pg_temp.eq('a Discord sign-in identity counts as linked', (public.discord_me('100002')->>'user_id') || '|' || (public.discord_me('100002')->>'via'), :B || '|sign_in');
select pg_temp.eq('a sign-in identity is not unlinkable', (public.discord_unlink('100002')->>'unlinked') || '|' || (public.discord_unlink('100002')->>'via'), 'false|sign_in');
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.eq('status for a Discord sign-in', public.discord_link_status()->>'via', 'sign_in');
reset role;

-- Events through the bot -----------------------------------------------------------------------------------
select public.discord_event_create('100001', '20001', '30001', 'modern', 'Friday Modern', now() + interval '2 days',
  'The Shop', 4, 8, null, null, null, '2026-11-06') as ev1 \gset
select pg_temp.eq('the event is the linked account''s', (select (created_by = :A)::text || '|' || auto_rounds::text || '|' || top_cut || '|' || capacity || '|' || name from public.events where id = (:'ev1'::jsonb->>'event_id')::uuid),
  'true|true|8|4|Friday Modern');
select pg_temp.eq('the organizer is seated and the card shows it', ((:'ev1'::jsonb)->>'players') || '|' || ((:'ev1'::jsonb)->'player_names')::text || '|' || ((:'ev1'::jsonb)->>'organizer_name'), '1|["Ana"]|Ana');
select pg_temp.eq('the card carries the server and the link', ((:'ev1'::jsonb)->>'guild_id') || '|' || ((:'ev1'::jsonb)->>'channel_id') || '|' || ((:'ev1'::jsonb)->>'link'),
  '20001|30001|https://table-1.site/s/' || (((:'ev1'::jsonb)->>'event_id')));
select pg_temp.eq('sign-ups are open', ((:'ev1'::jsonb)->>'sign_up') || '|' || ((:'ev1'::jsonb)->>'status'), 'open|setup');
select pg_temp.eq('posting is audited', (select count(*)::text from public.audit_log where event_id = (:'ev1'::jsonb->>'event_id')::uuid and action = 'discord.posted'), '1');
select ((:'ev1'::jsonb)->>'event_id') as ev1_id \gset
select pg_temp.throws('an unlinked Discord user can''t create events', $$select public.discord_event_create('100003', '20001', '30001', 'modern')$$, '28000');
select pg_temp.throws('team formats aren''t offered', $$select public.discord_event_create('100001', '20001', '30001', 'team_draft')$$, '22023');
select pg_temp.throws('rounds are 1 to 15', $$select public.discord_event_create('100001', '20001', '30001', 'modern', p_rounds => 20)$$, '22023');
select public.discord_event_create('100001', '20001', '30001', 'draft', null, null, null, null, 0, 3, 'm10', null, '2026-11-06') as ev2 \gset
select pg_temp.eq('a draft with a set code and fixed rounds', (select set_code || '|' || auto_rounds::text || '|' || number_of_rounds from public.events where id = (:'ev2'::jsonb->>'event_id')::uuid), 'm10|false|3');

select pg_temp.eq('the server''s open events, soonest first', (select string_agg(x->>'name', ',') from jsonb_array_elements(public.discord_events_list('20001')) x), 'Friday Modern,Draft · M10 · Fri 6 Nov');
select pg_temp.eq('another server sees nothing', public.discord_events_list('20002')::text, '[]');
select pg_temp.eq('autocomplete filters by name', jsonb_array_length(public.discord_events_list('20001', 'open', 'frid'))::text, '1');
select pg_temp.eq('the card by server', public.discord_event_card('20001', :'ev1_id')->>'name', 'Friday Modern');
select pg_temp.throws('the card is only for the event''s server', format($$select public.discord_event_card('20002', %L)$$, :'ev1_id'), '42501');

-- Sign up and drop.
select public.discord_event_sign_up('100002', '20001', :'ev1_id') as su1 \gset
select pg_temp.eq('Bea signs up', ((:'su1'::jsonb)->>'result') || '|' || ((:'su1'::jsonb)->>'players') || '|' || ((:'su1'::jsonb)->'player_names')::text, 'joined|2|["Ana", "Bea"]');
select pg_temp.eq('signing up again is idempotent', public.discord_event_sign_up('100002', '20001', :'ev1_id')->>'result', 'already_joined');
select pg_temp.throws('not linked, no sign-up', format($$select public.discord_event_sign_up('100003', '20001', %L)$$, :'ev1_id'), '28000');
select pg_temp.throws('another server can''t sign people up', format($$select public.discord_event_sign_up('100004', '20002', %L)$$, :'ev1_id'), '42501');
select pg_temp.eq('the participant is linked to the right account', (select count(*)::text from public.participants where event_id = :'ev1_id' and user_id = :B), '1');
select public.discord_event_sign_up('100004', '20001', :'ev1_id');
select public.discord_event_sign_up('100005', '20001', :'ev1_id') as su4 \gset
select pg_temp.eq('the cap is reached', ((:'su4'::jsonb)->>'players') || '|' || ((:'su4'::jsonb)->>'sign_up'), '4|full');
select public.discord_event_sign_up('100006', '20001', :'ev1_id') as su5 \gset
select pg_temp.eq('the fifth goes on the waitlist', ((:'su5'::jsonb)->>'result') || '|' || ((:'su5'::jsonb)->>'position') || '|' || ((:'su5'::jsonb)->'waitlist_names')::text, 'waitlisted|1|["Fay"]');
select public.discord_event_drop('100004', '20001', :'ev1_id') as dr1 \gset
select pg_temp.eq('a drop frees the place and moves Fay up', ((:'dr1'::jsonb)->>'result') || '|' || ((:'dr1'::jsonb)->>'players') || '|' || ((:'dr1'::jsonb)->>'waitlist') || '|' || ((:'dr1'::jsonb)->'player_names')::text,
  'left|4|0|["Ana", "Bea", "Eli", "Fay"]');
select pg_temp.eq('dropping when not in', public.discord_event_drop('100004', '20001', :'ev1_id')->>'result', 'not_in');
select pg_temp.eq('sign-ups and drops are audited as the account', (select string_agg(action, ',' order by at) from public.audit_log where event_id = :'ev1_id' and actor_user = :D and (action = 'participant.left' or after->>'via' = 'link')), 'participant.joined,participant.left');

select pg_temp.eq('the posted message id is stored', public.discord_event_posted(:'ev1_id', 'event', '40001')->>'ok', 'true');
select pg_temp.eq('and the card carries it', public.discord_event_card('20001', :'ev1_id')->>'message_id', '40001');

-- Results.
select pg_temp.throws('nothing to post before round 1', format($$select public.discord_event_results('100002', '20001', %L)$$, :'ev1_id'), '55000');
insert into public.rounds (event_id, number, status) values (:'ev1_id', 1, 'active');
update public.events set status = 'in_progress', current_round = 1 where id = :'ev1_id';
select pg_temp.throws('a player can''t post standings mid-event', format($$select public.discord_event_results('100002', '20001', %L)$$, :'ev1_id'), '42501');
select pg_temp.eq('the organizer posts standings so far', public.discord_event_results('100001', '20001', :'ev1_id')->>'final', 'false');
update public.events set status = 'completed' where id = :'ev1_id';
select pg_temp.eq('anyone linked posts final results', public.discord_event_results('100002', '20001', :'ev1_id')->>'final', 'true');
select pg_temp.throws('not linked, no results', format($$select public.discord_event_results('100003', '20001', %L)$$, :'ev1_id'), '28000');
select pg_temp.eq('a finished event is in the done list, not the open one',
  jsonb_array_length(public.discord_events_list('20001', 'done'))::text || '|' || jsonb_array_length(public.discord_events_list('20001', 'open'))::text, '1|1');
select pg_temp.eq('sign-ups read closed', public.discord_event_card('20001', :'ev1_id')->>'sign_up', 'closed');

-- Attach an event made in the app.
set role authenticated;
select pg_temp.as_user(:A);
select (public.create_event_v2(p_format_name => 'pauper', p_rounds => 3, p_local_date => '2026-11-07')->>'event_id') as app_ev \gset
reset role;
select pg_temp.throws('only the organizer can post an app event', format($$select public.discord_event_attach('100002', '20001', '30002', %L)$$, :'app_ev'), '42501');
select pg_temp.eq('the organizer posts it', public.discord_event_attach('100001', '20001', '30002', :'app_ev')->>'channel_id', '30002');
select pg_temp.eq('attaching again moves the card', public.discord_event_attach('100001', '20001', '30003', :'app_ev')->>'channel_id', '30003');
set role authenticated;
select pg_temp.as_user(:A);
select public.cancel_event(:'app_ev', 'test');
reset role;
select pg_temp.throws('a cancelled event can''t be posted', format($$select public.discord_event_attach('100001', '20001', '30002', %L)$$, :'app_ev'), '22023');

-- Settings.
select pg_temp.eq('no zone yet reads UTC', (public.discord_guild_timezone('20001')->>'timezone') || '|' || (public.discord_guild_timezone('20001')->>'set'), 'UTC|false');
select pg_temp.eq('a zone is set', public.discord_guild_timezone('20001', 'Europe/Stockholm')->>'timezone', 'Europe/Stockholm');
select pg_temp.throws('an unknown zone is refused', $$select public.discord_guild_timezone('20001', 'Nowhere/Land')$$, '22023');
select pg_temp.throws('a numeric offset is refused', $$select public.discord_guild_timezone('20001', '+02')$$, '22023');
select pg_temp.eq('the zone is kept', public.discord_guild_timezone('20001')->>'timezone', 'Europe/Stockholm');

-- Decks and cards -------------------------------------------------------------------------------------------
\set DECK '''d0000000-0000-0000-0000-000000000001'''
set role authenticated;
select pg_temp.as_user(:A);
select public.list_create(:DECK, 'deck', 'Burn', 'modern', jsonb_build_array(
  jsonb_build_array(:BOLT, 'main', 4), jsonb_build_array(:OPT, 'main', 2), jsonb_build_array(:OPT, 'side', 3)));
reset role;
select pg_temp.eq('my decks for autocomplete', (select x->>'name' || '|' || (x->>'cards') || '|' || (x->>'shared') from jsonb_array_elements(public.discord_my_decks('100001')) x), 'Burn|9|false');
select pg_temp.eq('a search that misses', public.discord_my_decks('100001', 'zzz')::text, '[]');
select pg_temp.eq('no link yet: the bot asks first', public.discord_deck_share('100001', :DECK)->>'needs_confirm', 'true');
select pg_temp.eq('nothing was shared by asking', (select count(*)::text from public.share_links where item_id = :DECK), '0');
select public.discord_deck_share('100001', :DECK, true) as dk \gset
select pg_temp.eq('confirmed: a share link is made', ((:'dk'::jsonb)->>'new_link') || '|' || ((:'dk'::jsonb)->>'main') || '|' || ((:'dk'::jsonb)->>'side') || '|' || (((:'dk'::jsonb)->>'url') like 'https://table-1.site/l/%')::text, 'true|6|3|true');
select pg_temp.eq('the link is the live share link', (select 'https://table-1.site/l/' || token from public.share_links where item_id = :DECK and revoked_at is null), ((:'dk'::jsonb)->>'url'));
select pg_temp.eq('the hero is a card of the deck with art', ((:'dk'::jsonb)->'hero'->>'name'), 'Lightning Bolt');
select pg_temp.eq('sharing again reuses the link', (public.discord_deck_share('100001', :DECK)->>'new_link') || '|' || (public.discord_deck_share('100001', :DECK)->>'needs_confirm'), 'false|false');
select pg_temp.eq('my decks now show shared', (select x->>'shared' from jsonb_array_elements(public.discord_my_decks('100001')) x), 'true');
select pg_temp.throws('someone else''s deck is refused', format($$select public.discord_deck_share('100002', %L, true)$$, :DECK), '42501');

select public.discord_card('lightning') as cd \gset
select pg_temp.eq('/card finds the card with its cheapest prices', ((:'cd'::jsonb)->>'name') || '|' || ((:'cd'::jsonb)->>'usd') || '|' || ((:'cd'::jsonb)->>'usd_foil') || '|' || ((:'cd'::jsonb)->>'printings'), 'Lightning Bolt|1.50|9.00|2');
select pg_temp.eq('/card with no match', coalesce(public.discord_card('zzzzzz')::text, 'null'), 'null');
select pg_temp.eq('/card needs two characters', coalesce(public.discord_card('l')::text, 'null'), 'null');

-- Unlinking and deletion ---------------------------------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:A);
select pg_temp.eq('unlink from the web', public.discord_unlink_me()->>'unlinked', 'true');
select pg_temp.eq('status after', public.discord_link_status()->>'linked', 'false');
reset role;
select pg_temp.eq('the bot no longer knows the account', public.discord_me('100001')->>'linked', 'false');
select pg_temp.eq('unlinking nobody', public.discord_unlink('100001')->>'unlinked', 'false');
insert into t1_private.discord_links (discord_user_id, user_id) values ('100003', :C);
select pg_temp.eq('unlink from the bot', public.discord_unlink('100003')->>'unlinked', 'true');
insert into t1_private.discord_links (discord_user_id, user_id) values ('100003', :C);
delete from auth.users where id = :C;
select pg_temp.eq('account deletion removes the link', (select count(*)::text from t1_private.discord_links where discord_user_id = '100003'), '0');

-- Grants -----------------------------------------------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.throws('clients can''t call the bot''s functions', $$select public.discord_me('100002')$$);
select pg_temp.throws('clients can''t create events as others', $$select public.discord_event_create('100002', '20001', '30001', 'modern')$$);
select pg_temp.throws('clients can''t sign others up', format($$select public.discord_event_sign_up('100002', '20001', %L)$$, :'ev1_id'));
select pg_temp.throws('clients can''t share decks as others', format($$select public.discord_deck_share('100002', %L, true)$$, :DECK));
select pg_temp.throws('clients can''t read the server''s events', $$select public.discord_events_list('20001')$$);
reset role;
set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('anon can''t confirm links', $$select public.discord_link_confirm('x')$$);
select pg_temp.throws('anon can''t read link status', $$select public.discord_link_status()$$);
reset role;
select pg_temp.eq('the acting claims don''t leak past the call', coalesce(current_setting('request.jwt.claim.sub', true), ''), '');
