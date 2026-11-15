-- Insights → Rankings, your friends' rankings (20261114200000_rankings_friends.sql; contract/main-nav-2026-11-14.md
-- § Rankings): shared rankings of accepted friends only, a cube ranking only when its cube reaches the viewer, never
-- Only me, never your own, newest first; signed out refused.
\ir _helpers.sql

-- Ana ranks; Ben is her friend; Cal is a stranger.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000082a1', 'ana2@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000082b1', 'ben2@example.com', '{"full_name": "Ben Ortiz"}'),
  ('00000000-0000-0000-0000-0000000082c1', 'cal2@example.com', '{"full_name": "Cal Reyes"}');
\set ANA '''00000000-0000-0000-0000-0000000082a1'''
\set BEN '''00000000-0000-0000-0000-0000000082b1'''
\set CAL '''00000000-0000-0000-0000-0000000082c1'''

insert into public.mtg_sets (code, name, set_type, released_at, card_count) values
  ('nrf', 'New Friends Set', 'expansion', current_date - 5, 300);
insert into public.card_oracles (oracle_id, name, name_norm, layout, type_line, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-0000000082a1', 'Rank Drake', 'rank drake', 'normal', 'Creature — Drake', 'c1000000-0000-0000-0000-0000000082a1', 'a', 'h'),
  ('c0000000-0000-0000-0000-0000000082a2', 'Rank Bolt', 'rank bolt', 'normal', 'Instant', 'c1000000-0000-0000-0000-0000000082a2', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-0000000082a1', 'c0000000-0000-0000-0000-0000000082a1', 'nrf', '12', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-0000000082a2', 'c0000000-0000-0000-0000-0000000082a2', 'nrf', '140', 'en', 'common', '{nonfoil}', 'normal', 'h');

-- Two cubes of Ana's: one only she sees, one shared with friends.
insert into public.card_lists (id, user_id, kind, name, format, visibility, seq) values
  ('e8200000-0000-0000-0000-000000000001', :ANA, 'cube', 'Secret Cube', 'vintage', 'private', 1),
  ('e8200000-0000-0000-0000-000000000002', :ANA, 'cube', 'Friends Cube', 'vintage', 'friends', 1);
insert into public.card_list_entries (list_id, card_id, board, finish, qty)
select l, 'c1000000-0000-0000-0000-0000000082a1', 'main', 'nonfoil', 1
  from unnest(array['e8200000-0000-0000-0000-000000000001', 'e8200000-0000-0000-0000-000000000002']::uuid[]) l;

\set RSET '''f8200000-0000-0000-0000-000000000001'''
\set RPRIV '''f8200000-0000-0000-0000-000000000002'''
\set RSECRET '''f8200000-0000-0000-0000-000000000003'''
\set RCUBE '''f8200000-0000-0000-0000-000000000004'''

select pg_temp.as_user(:ANA);
select public.friend_request(:BEN);
select pg_temp.as_user(:BEN);
select public.friend_respond(:ANA, true);

select pg_temp.as_user(:ANA);
select public.cube_ranking_create(:RSET, p_set => 'NRF');
select public.cube_ranking_create(:RPRIV, p_set => 'NRF', p_sharing => 'private');
select public.cube_ranking_create(:RSECRET, 'e8200000-0000-0000-0000-000000000001');
select public.cube_ranking_create(:RCUBE, 'e8200000-0000-0000-0000-000000000002');

-- Cal also ranks the set, shared, but Cal is nobody's friend.
select pg_temp.as_user(:CAL);
select public.cube_ranking_create('f8200000-0000-0000-0000-000000000005', p_set => 'NRF');
update public.cube_rankings set updated_at = now() - (substr(id::text, 36)::int || ' minutes')::interval
 where id::text like 'f8200000-%';

create or replace function pg_temp.ids() returns text language sql as $$
  select coalesce(string_agg(right(r->>'id', 1) || ':' || (r->'cube'->>'name'), ',' order by i), '')
    from jsonb_array_elements(public.rankings_friends()) with ordinality t(r, i);
$$;

select pg_temp.as_user(:BEN);
select pg_temp.eq('a friend: Ana''s shared set and friends-cube rankings, newest first; not Only me, not the private cube''s, not a stranger''s',
  pg_temp.ids(), '1:New Friends Set,4:Friends Cube');
select pg_temp.eq('rows read as someone else''s, with who made them',
  (select (r->>'mine') || ' ' || (r->'by'->>'user_id') from jsonb_array_elements(public.rankings_friends()) r limit 1),
  'false 00000000-0000-0000-0000-0000000082a1');
select pg_temp.eq('a limit', jsonb_array_length(public.rankings_friends(1))::text, '1');

select pg_temp.as_user(:ANA);
select pg_temp.eq('never your own', pg_temp.ids(), '');

select pg_temp.as_user(:CAL);
select pg_temp.eq('a stranger has no friends'' rankings', pg_temp.ids(), '');

-- A deleted cube's ranking leaves the list.
update public.card_lists set deleted_at = now() where id = 'e8200000-0000-0000-0000-000000000002';
select pg_temp.as_user(:BEN);
select pg_temp.eq('a deleted cube''s ranking is gone', pg_temp.ids(), '1:New Friends Set');

-- Unfriending (a block ends it too) takes them away.
select pg_temp.as_user(:BEN);
select public.friend_remove(:ANA);
select pg_temp.eq('no longer friends: nothing', pg_temp.ids(), '');

select pg_temp.as_user(null);
select pg_temp.throws('signed out', 'select public.rankings_friends()', '28000');
