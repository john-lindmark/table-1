-- Cube rankings (contract/cube-rankings-2026-10-21.md): who can rank and see, the log (append, undo, redo, conflicts,
-- retries), validation, cube deletion, and moderation of shared names.
\ir _helpers.sql

-- Ana owns the cube; Ben is her friend; Cal is a stranger; Dee blocks Ben.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000000b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com', '{"full_name": "Cal Reyes"}'),
  ('00000000-0000-0000-0000-0000000000d1', 'dee@example.com', '{"full_name": "Dee Park"}');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set BEN '''00000000-0000-0000-0000-0000000000b1'''
\set CAL '''00000000-0000-0000-0000-0000000000c1'''
\set DEE '''00000000-0000-0000-0000-0000000000d1'''

insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000001', 'Lightning Bolt', 'lightning bolt', 'normal', 'c1000000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000002', 'Opt', 'opt', 'normal', 'c1000000-0000-0000-0000-000000000002', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000003', 'Tarmogoyf', 'tarmogoyf', 'normal', 'c1000000-0000-0000-0000-000000000003', 'a', 'h'),
  ('c0000000-0000-0000-0000-000000000004', 'Brainstorm', 'brainstorm', 'normal', 'c1000000-0000-0000-0000-000000000004', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'm10', '146', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000005', 'c0000000-0000-0000-0000-000000000001', 'm11', '149', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'xln', '65', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000003', 'fut', '153', 'en', 'rare', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000004', 'ice', '61', 'en', 'common', '{nonfoil}', 'normal', 'h');
\set CUBE '''e7000000-0000-0000-0000-000000000001'''
\set R1 '''f7000000-0000-0000-0000-000000000001'''
\set R2 '''f7000000-0000-0000-0000-000000000002'''
\set R3 '''f7000000-0000-0000-0000-000000000003'''
\set OP1 '''a7000000-0000-0000-0000-000000000001'''

create or replace function pg_temp.screen(s text, variadic o text[]) returns jsonb language sql as $$
  select jsonb_build_object('s', s, 'o', to_jsonb(o)) $$;
\set BOLT '''c0000000-0000-0000-0000-000000000001'''
\set OPT '''c0000000-0000-0000-0000-000000000002'''
\set GOYF '''c0000000-0000-0000-0000-000000000003'''
\set STORM '''c0000000-0000-0000-0000-000000000004'''

set role authenticated;
select pg_temp.as_user(:ANA);
-- Two Bolt printings, Opt and Goyf in the main; Brainstorm only considered.
select public.list_create(:CUBE, 'cube', 'Pauper cube', 'vintage', jsonb_build_array(
  jsonb_build_array('c1000000-0000-0000-0000-000000000001', 'main', 1),
  jsonb_build_array('c1000000-0000-0000-0000-000000000005', 'main', 1),
  jsonb_build_array('c1000000-0000-0000-0000-000000000002', 'main', 1),
  jsonb_build_array('c1000000-0000-0000-0000-000000000003', 'main', 1),
  jsonb_build_array('c1000000-0000-0000-0000-000000000004', 'maybe', 1)));
select public.friend_request(:BEN);
select pg_temp.as_user(:BEN);
select public.friend_respond(:ANA, true);
select pg_temp.as_user(:DEE);
select public.user_block(:BEN, true);

-- Making one --------------------------------------------------------------------------------------------------
select pg_temp.as_user(:ANA);
select pg_temp.eq('a ranking starts empty, top half, top 100, shared with the cube',
  (select r->>'name' || '/' || (r->>'depth') || '/' || (r->>'top') || '/' || (r->>'sharing') || '/' || (r->>'screens') || '/' || (r->>'rev')
     from public.cube_ranking_create(:R1, :CUBE, '  Ana''s picks  ') r), 'Ana''s picks/half/100/cube/0/0');
select pg_temp.eq('creating again returns it', public.cube_ranking_create(:R1, :CUBE, 'Other')->>'name', 'Ana''s picks');
select pg_temp.throws('bad depth', $$select public.cube_ranking_create(gen_random_uuid(), 'e7000000-0000-0000-0000-000000000001', 'x', 'third')$$, '22023');
select pg_temp.throws('bad top', $$select public.cube_ranking_create(gen_random_uuid(), 'e7000000-0000-0000-0000-000000000001', 'x', 'half', 30)$$, '22023');
select pg_temp.eq('a blank name gets one', public.cube_ranking_create(:R3, :CUBE, '', 'full', 50, 'private')->>'name', 'My ranking');

-- The cube is private, so only Ana can rank it.
select pg_temp.as_user(:BEN);
select pg_temp.eq('a friend''s private cube is not listed', jsonb_array_length(public.rankable_cubes())::text, '0');
select pg_temp.throws('a private cube can''t be ranked by a friend', $$select public.cube_ranking_create('f7000000-0000-0000-0000-000000000002', 'e7000000-0000-0000-0000-000000000001')$$, '42501');
select pg_temp.throws('nor listed', $$select public.cube_rankings('e7000000-0000-0000-0000-000000000001')$$, '42501');
select pg_temp.throws('nor read', $$select public.cube_ranking_get('f7000000-0000-0000-0000-000000000001')$$, '42501');

-- Shared with friends: Ben can rank and see Ana's shared ranking (not her private one).
select pg_temp.as_user(:ANA);
select public.sharing_set(jsonb_build_object('items', jsonb_build_array(
  jsonb_build_object('kind', 'cube', 'id', 'e7000000-0000-0000-0000-000000000001', 'visibility', 'friends'))));
select pg_temp.as_user(:BEN);
select pg_temp.eq('a friend ranks a shared cube', public.cube_ranking_create(:R2, :CUBE, 'Ben run', 'full', 50)->>'mine', 'true');
select pg_temp.eq('the friend sees their own and Ana''s shared ranking, theirs first',
  (select string_agg(x->>'name' || ':' || (x->>'mine'), ',' order by n)
     from jsonb_array_elements(public.cube_rankings(:CUBE)->'rankings') with ordinality y(x, n)), 'Ben run:true,Ana''s picks:false');
select pg_temp.eq('and can rank it', (public.cube_rankings(:CUBE)->>'can_rank'), 'true');
select pg_temp.eq('the cube says whose it is', public.cube_rankings(:CUBE)->'cube'->'owner'->>'display_name', 'Ana Lind');
select pg_temp.throws('a private ranking stays private', $$select public.cube_ranking_get('f7000000-0000-0000-0000-000000000003')$$, '42501');
select pg_temp.eq('the cube''s main cards come with a ranking, one per card',
  (public.cube_ranking_get(:R1)->'cube'->'cards')::text,
  '["c0000000-0000-0000-0000-000000000001", "c0000000-0000-0000-0000-000000000002", "c0000000-0000-0000-0000-000000000003"]');
select pg_temp.eq('and the printing the cube holds of each (two of a card: the lowest card id)',
  (public.cube_ranking_get(:R1)->'cube'->'printings')::text,
  '{"c0000000-0000-0000-0000-000000000001": "c1000000-0000-0000-0000-000000000001", "c0000000-0000-0000-0000-000000000002": "c1000000-0000-0000-0000-000000000002", "c0000000-0000-0000-0000-000000000003": "c1000000-0000-0000-0000-000000000003"}');
select pg_temp.eq('a friend''s shared cube is listed as one to rank',
  (select x->>'name' || '/' || (x->'owner'->>'display_name') || '/' || (x->>'cards') || '/' || (x->>'rankings') || '/' || (x->>'mine')
     from jsonb_array_elements(public.rankable_cubes()) x), 'Pauper cube/Ana Lind/3/2/1');
select pg_temp.as_user(:ANA);
select pg_temp.eq('your own cubes are not in the list', jsonb_array_length(public.rankable_cubes())::text, '0');
select pg_temp.eq('the owner sees everyone''s', jsonb_array_length(public.cube_rankings(:CUBE)->'rankings')::text, '3');
select pg_temp.as_user(:CAL);
select pg_temp.throws('a stranger sees nothing', $$select public.cube_rankings('e7000000-0000-0000-0000-000000000001')$$, '42501');

-- Public: Cal can see, Dee (who blocked Ben) sees Ana's but not Ben's.
select pg_temp.as_user(:ANA);
select public.sharing_set('{"profile": "public"}');
select public.sharing_set(jsonb_build_object('items', jsonb_build_array(
  jsonb_build_object('kind', 'cube', 'id', 'e7000000-0000-0000-0000-000000000001', 'visibility', 'public'))));
select pg_temp.as_user(:CAL);
select pg_temp.eq('a stranger''s public cube is not listed (it''s reached through their profile)', jsonb_array_length(public.rankable_cubes())::text, '0');
reset role;
insert into public.events (id, short_code, name, created_by, status) values
  ('e1000000-0000-0000-0000-000000000097', 'RANK97', 'Cube night', :ANA, 'completed');
insert into public.event_members (event_id, user_id, role) values ('e1000000-0000-0000-0000-000000000097', :ANA, 'owner');
insert into public.participants (event_id, user_id, display_name, seat) values
  ('e1000000-0000-0000-0000-000000000097', :ANA, 'Ana Lind', 1), ('e1000000-0000-0000-0000-000000000097', :CAL, 'Cal Reyes', 2);
set role authenticated;
select pg_temp.as_user(:CAL);
select pg_temp.eq('once they''ve played together, her public cube is listed', jsonb_array_length(public.rankable_cubes())::text, '1');
select pg_temp.eq('but a stranger can rank a public cube', public.cube_ranking_create('f7000000-0000-0000-0000-000000000004', 'e7000000-0000-0000-0000-000000000001', 'Cal run')->>'mine', 'true');
select pg_temp.eq('anyone sees a public cube''s shared rankings', jsonb_array_length(public.cube_rankings(:CUBE)->'rankings')::text, '3');
select pg_temp.as_user(:DEE);
select pg_temp.eq('blocks hide the blocked person''s ranking',
  (select string_agg(x->>'name', ',' order by x->>'name') from jsonb_array_elements(public.cube_rankings(:CUBE)->'rankings') x), 'Ana''s picks,Cal run');

-- The log ---------------------------------------------------------------------------------------------------------
select pg_temp.as_user(:ANA);
select pg_temp.eq('append a screen', (select r->>'screens' || '/' || (r->>'rev') from public.cube_ranking_push(:R1, 0, 0,
  jsonb_build_array(pg_temp.screen('R', :BOLT, :OPT) || '{"t": 1}'), 1, 3, 0, :OP1) r), '1/1');
select pg_temp.eq('a retried push is answered, not refused', (public.cube_ranking_push(:R1, 0, 0,
  jsonb_build_array(pg_temp.screen('R', :BOLT, :OPT)), 1, 3, 0, :OP1))->>'rev', '1');
select pg_temp.throws('an old rev is a conflict PostgREST won''t retry', $$select public.cube_ranking_push('f7000000-0000-0000-0000-000000000001', 0, 1, '[]')$$, 'PT409');
select public.cube_ranking_push(:R1, 1, 1, jsonb_build_array(pg_temp.screen('U', :OPT, :GOYF), pg_temp.screen('F', :GOYF, :BOLT, :OPT)), 2, 3, 3);
select pg_temp.eq('three screens, kept in order with their times',
  (public.cube_ranking_get(:R1)->'log')::text,
  '[{"o": ["c0000000-0000-0000-0000-000000000001", "c0000000-0000-0000-0000-000000000002"], "s": "R", "t": 1}, '
  '{"o": ["c0000000-0000-0000-0000-000000000002", "c0000000-0000-0000-0000-000000000003"], "s": "U"}, '
  '{"o": ["c0000000-0000-0000-0000-000000000003", "c0000000-0000-0000-0000-000000000001", "c0000000-0000-0000-0000-000000000002"], "s": "F"}]');
select pg_temp.eq('undo keeps all but the last', (public.cube_ranking_push(:R1, 2, 2, '[]'))->>'screens', '2');
select pg_temp.eq('redo of the first: keep none, re-send the rest',
  (select r->>'screens' || '/' || (r->>'sorted') || '/' || (r->>'ranked')
     from public.cube_ranking_push(:R1, 3, 0, jsonb_build_array(pg_temp.screen('U', :OPT, :GOYF)), 1, 3, 2) r), '1/1/2');
select pg_temp.eq('the log now starts with the re-sent screen', public.cube_ranking_get(:R1)->'log'->0->>'s', 'U');
select pg_temp.eq('progress shows in the list', (select x->>'sorted' || ' of ' || (x->>'categories') || ', ' || (x->>'ranked')
  from jsonb_array_elements(public.cube_rankings(:CUBE)->'rankings') x where x->>'id' = 'f7000000-0000-0000-0000-000000000001'), '1 of 3, 2');

-- Validation.
select pg_temp.throws('one card is not a screen', $$select public.cube_ranking_push('f7000000-0000-0000-0000-000000000001', 4, 1,
  jsonb_build_array(pg_temp.screen('W', 'c0000000-0000-0000-0000-000000000001')))$$, '22023');
select pg_temp.throws('five cards are too many', $$select public.cube_ranking_push('f7000000-0000-0000-0000-000000000001', 4, 1,
  jsonb_build_array(pg_temp.screen('W', 'c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002',
  'c0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000005')))$$, '22023');
select pg_temp.throws('a card twice', $$select public.cube_ranking_push('f7000000-0000-0000-0000-000000000001', 4, 1,
  jsonb_build_array(pg_temp.screen('W', 'c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001')))$$, '22023');
select pg_temp.throws('unknown session', $$select public.cube_ranking_push('f7000000-0000-0000-0000-000000000001', 4, 1,
  jsonb_build_array(pg_temp.screen('X', 'c0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002')))$$, '22023');
select pg_temp.throws('unknown card', $$select public.cube_ranking_push('f7000000-0000-0000-0000-000000000001', 4, 1,
  jsonb_build_array(pg_temp.screen('W', 'c0000000-0000-0000-0000-000000000001', gen_random_uuid()::text)))$$, '22023');
select pg_temp.throws('not a uuid', $$select public.cube_ranking_push('f7000000-0000-0000-0000-000000000001', 4, 1,
  jsonb_build_array(pg_temp.screen('W', 'c0000000-0000-0000-0000-000000000001', 'bolt')))$$, '22023');
select pg_temp.eq('a P1P1 pick is the picked card, then its pack', (public.cube_ranking_push(:R1, 4, 1,
  jsonb_build_array(pg_temp.screen('P', :GOYF, :BOLT, :OPT, :STORM)), null, null, null, null,
  jsonb_build_array(jsonb_build_object('s', 'F', 'c', :GOYF, 'f', null, 'to', 1, 'by', 'pick', 't', 5, 'n', 2),
                    jsonb_build_object('s', 'F', 'c', :BOLT, 'f', 1, 'to', 2, 'by', 'pick'))))->>'screens', '2');
select pg_temp.eq('the change log keeps what moved', (public.cube_ranking_get(:R1)->'changes')::text,
  '[{"c": "c0000000-0000-0000-0000-000000000003", "n": 2, "s": "F", "t": 5, "by": "pick", "to": 1}, '
  '{"c": "c0000000-0000-0000-0000-000000000001", "f": 1, "s": "F", "by": "pick", "to": 2}]');
select pg_temp.throws('a pick with 16 cards', $$select public.cube_ranking_push('f7000000-0000-0000-0000-000000000001', 5, 2,
  jsonb_build_array(jsonb_build_object('s', 'P', 'o', (select jsonb_agg(gen_random_uuid()) from generate_series(1, 16)))))$$, '22023');
select pg_temp.throws('a bad change', $$select public.cube_ranking_push('f7000000-0000-0000-0000-000000000001', 5, 2, '[]',
  null, null, null, null, '[{"s": "F", "c": "bolt", "to": 1}]')$$, '22023');
select pg_temp.throws('keep past the end', $$select public.cube_ranking_push('f7000000-0000-0000-0000-000000000001', 5, 3, '[]')$$, '22023');
select pg_temp.eq('nothing was written by a refusal', public.cube_ranking_get(:R1)->>'rev', '5');

-- Only the maker writes.
select pg_temp.as_user(:BEN);
select pg_temp.throws('someone else can''t push', $$select public.cube_ranking_push('f7000000-0000-0000-0000-000000000001', 5, 1, '[]')$$, '42501');
select pg_temp.throws('or rename', $$select public.cube_ranking_update('f7000000-0000-0000-0000-000000000001', 'Mine now')$$, '42501');
select pg_temp.throws('or delete', $$select public.cube_ranking_delete('f7000000-0000-0000-0000-000000000001')$$, '42501');
select pg_temp.eq('a watcher reads the log', jsonb_array_length(public.cube_ranking_get(:R1)->'log')::text, '2');
select pg_temp.eq('settings change', (select r->>'depth' || '/' || (r->>'top') || '/' || (r->>'sharing')
  from public.cube_ranking_update(:R2, null, 'half', 100, 'private') r), 'half/100/private');
select pg_temp.as_user(:CAL);
select pg_temp.throws('a private ranking leaves the list', $$select public.cube_ranking_get('f7000000-0000-0000-0000-000000000002')$$, '42501');
select pg_temp.as_user(:BEN);
select pg_temp.eq('my rankings across cubes', (select string_agg(x->>'name' || '@' || (x->'cube'->>'name'), ',')
  from jsonb_array_elements(public.cube_rankings()->'rankings') x), 'Ben run@Pauper cube');
select pg_temp.as_user(null);
select pg_temp.throws('signed out', $$select public.cube_rankings()$$, '28000');
select pg_temp.throws('signed out, no list to rank', $$select public.rankable_cubes()$$, '28000');
select pg_temp.throws('no direct reads', $$select * from public.cube_rankings$$, '42501');

-- Moderation: a shared name is checked; a block makes the ranking private, and a revert shares it again ------------
reset role;
select pg_temp.eq('shared names are queued, private ones are not',
  (select string_agg(content, ',' order by content) from public.moderation_checks where subject_kind = 'ranking_name'),
  'Ana''s picks,Ben run,Cal run');
update public.moderation_checks set status = 'block', category = 'hate', decided_at = now()
 where subject_kind = 'ranking_name' and content = 'Ben run';
select t1_private.moderation_enforce((select id from public.moderation_checks where subject_kind = 'ranking_name' and content = 'Ben run'));
select pg_temp.eq('already private: stays private',
  (select sharing from public.cube_rankings where id = 'f7000000-0000-0000-0000-000000000002'), 'private');
update public.cube_rankings set sharing = 'cube' where id = 'f7000000-0000-0000-0000-000000000002';
select pg_temp.eq('sharing it again doesn''t re-ask for the same words', (select count(*)::text from public.moderation_checks where subject_kind = 'ranking_name'), '3');
delete from public.moderation_actions;
select t1_private.moderation_enforce((select id from public.moderation_checks where subject_kind = 'ranking_name' and content = 'Ben run'));
select pg_temp.eq('a blocked name unshares the ranking', (select sharing from public.cube_rankings where id = 'f7000000-0000-0000-0000-000000000002'), 'private');
select pg_temp.eq('the maker is told', (select label || '/' || action from public.moderation_actions where subject_kind = 'ranking_name'), 'Ranking Ben run/unshare');
select t1_private.moderation_revert((select id from public.moderation_actions where subject_kind = 'ranking_name'));
select pg_temp.eq('a revert shares it again', (select sharing from public.cube_rankings where id = 'f7000000-0000-0000-0000-000000000002'), 'cube');

-- The cube changes; telling the owner (2026-10-22) ----------------------------------------------------------------
select pg_temp.eq('the owner hears when a friend and a stranger share rankings of her cube, never of her own',
  (select string_agg((msg->'data'->>'from_name') || ' on ' || (msg->'data'->>'cube_name'), ', ' order by msg_id)
     from pgmq.messages where msg->>'kind' = 'ranking.started' and msg->'user_ids' ? '00000000-0000-0000-0000-0000000000a1'),
  'Ben Ortiz on Pauper cube, Cal Reyes on Pauper cube');
set role authenticated;
select pg_temp.as_user(:BEN);
select public.cube_ranking_create('f7000000-0000-0000-0000-000000000005', :CUBE, 'Ben again') is not null as again \gset
select public.cube_ranking_create('f7000000-0000-0000-0000-000000000006', :CUBE, 'Ben quiet', 'half', 100, 'private') is not null as quiet \gset
select public.cube_ranking_update('f7000000-0000-0000-0000-000000000006', p_sharing := 'cube') is not null as shared \gset
reset role;
select pg_temp.eq('at most one a week per person and cube, and none for Only me',
  (select count(*)::text from pgmq.messages where msg->>'kind' = 'ranking.started'), '2');
update t1_private.ranking_notices set sent_at = now() - interval '8 days';
set role authenticated;
select pg_temp.as_user(:BEN);
select public.cube_ranking_update('f7000000-0000-0000-0000-000000000006', p_sharing := 'private') is not null as hid \gset
select public.cube_ranking_update('f7000000-0000-0000-0000-000000000006', p_sharing := 'cube') is not null as reshared \gset
reset role;
select pg_temp.eq('a week later, sharing an Only me ranking with the cube tells her',
  (select count(*)::text from pgmq.messages where msg->>'kind' = 'ranking.started'), '3');
select pg_temp.eq('the push says which ranking to open',
  (select (msg->'data'->>'ranking_id') || '/' || (msg->'data'->>'list_id') from pgmq.messages
    where msg->>'kind' = 'ranking.started' order by msg_id desc limit 1),
  'f7000000-0000-0000-0000-000000000006/e7000000-0000-0000-0000-000000000001');

set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('a ranking remembers the cube it started from',
  (public.cube_ranking_get(:R1)->'baseline')::text, (public.cube_ranking_get(:R1)->'cube'->'cards')::text);
select public.list_edit(:CUBE, jsonb_build_array(jsonb_build_object('card_id', 'c1000000-0000-0000-0000-000000000004', 'board', 'main', 'delta', 1),
                                                   jsonb_build_object('card_id', 'c1000000-0000-0000-0000-000000000003', 'board', 'main', 'qty', 0))) is not null as edited \gset
select pg_temp.eq('after the cube changes, the cube''s cards and the baseline differ: Brainstorm in, Goyf out',
  (select (d->'baseline')::text || ' -> ' || (d->'cube'->'cards')::text from public.cube_ranking_get(:R1) d),
  '["c0000000-0000-0000-0000-000000000001", "c0000000-0000-0000-0000-000000000002", "c0000000-0000-0000-0000-000000000003"] -> ["c0000000-0000-0000-0000-000000000001", "c0000000-0000-0000-0000-000000000002", "c0000000-0000-0000-0000-000000000004"]');
select pg_temp.as_user(:BEN);
select pg_temp.throws('only the maker catches a ranking up', $$select public.cube_ranking_catch_up('f7000000-0000-0000-0000-000000000001')$$, '42501');
select pg_temp.as_user(:ANA);
select pg_temp.eq('catching up takes the cube as it is now',
  (public.cube_ranking_catch_up(:R1)->'baseline')::text, (public.cube_ranking_get(:R1)->'cube'->'cards')::text);
select pg_temp.eq('and is harmless again', (public.cube_ranking_catch_up(:R1)->'baseline')::text, (public.cube_ranking_get(:R1)->'baseline')::text);
reset role;

-- Deleting ----------------------------------------------------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:BEN);
select pg_temp.eq('delete my ranking', public.cube_ranking_delete(:R2)->>'deleted', 'true');
select pg_temp.eq('deleting again is harmless', public.cube_ranking_delete(:R2)->>'deleted', 'false');
reset role;
insert into public.ranking_briefs (a, b, list, input_hash, brief, model) values
  ('f7000000-0000-0000-0000-000000000001', 'f7000000-0000-0000-0000-000000000004', 'F', 'h', 'Both love Bolt.', 'test');
set role authenticated;
select pg_temp.as_user(:BEN);
select pg_temp.throws('briefs are not readable directly', $$select * from public.ranking_briefs$$, '42501');
select pg_temp.as_user(:ANA);
select public.list_delete(:CUBE);
reset role;
select pg_temp.eq('deleting the cube deletes its rankings', (select count(*)::text from public.cube_rankings), '0');
select pg_temp.eq('and their briefs', (select count(*)::text from public.ranking_briefs), '0');
