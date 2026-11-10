-- Rankings on profiles (20261110120000_profile_rankings.sql; contract/friends-sharing-2026-10-18.md § Rankings on
-- profiles): the Rankings part (default friends, capped by the profile), which rankings show (shared ones the viewer
-- may open; never Only me; a cube ranking only to people who see its cube), set rankings reaching whoever the part
-- reaches, settings and audits.
\ir _helpers.sql

-- Ana ranks; Ben is her friend; Cal is a stranger.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000081a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000081b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}'),
  ('00000000-0000-0000-0000-0000000081c1', 'cal@example.com', '{"full_name": "Cal Reyes"}');
\set ANA '''00000000-0000-0000-0000-0000000081a1'''
\set BEN '''00000000-0000-0000-0000-0000000081b1'''
\set CAL '''00000000-0000-0000-0000-0000000081c1'''

insert into public.mtg_sets (code, name, set_type, released_at, card_count) values
  ('nrk', 'New Rankings', 'expansion', current_date - 5, 300);
insert into public.card_oracles (oracle_id, name, name_norm, layout, type_line, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-0000000081a1', 'Rank Drake', 'rank drake', 'normal', 'Creature — Drake', 'c1000000-0000-0000-0000-0000000081a1', 'a', 'h'),
  ('c0000000-0000-0000-0000-0000000081a2', 'Rank Bolt', 'rank bolt', 'normal', 'Instant', 'c1000000-0000-0000-0000-0000000081a2', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-0000000081a1', 'c0000000-0000-0000-0000-0000000081a1', 'nrk', '12', 'en', 'common', '{nonfoil}', 'normal', 'h'),
  ('c1000000-0000-0000-0000-0000000081a2', 'c0000000-0000-0000-0000-0000000081a2', 'nrk', '140', 'en', 'common', '{nonfoil}', 'normal', 'h');

-- Two cubes of Ana's: one only she sees, one shared with friends.
insert into public.card_lists (id, user_id, kind, name, format, visibility, seq) values
  ('e8100000-0000-0000-0000-000000000001', :ANA, 'cube', 'Secret Cube', 'vintage', 'private', 1),
  ('e8100000-0000-0000-0000-000000000002', :ANA, 'cube', 'Friends Cube', 'vintage', 'friends', 1);
insert into public.card_list_entries (list_id, card_id, board, finish, qty)
select l, 'c1000000-0000-0000-0000-0000000081a1', 'main', 'nonfoil', 1
  from unnest(array['e8100000-0000-0000-0000-000000000001', 'e8100000-0000-0000-0000-000000000002']::uuid[]) l;

\set RSET '''f8100000-0000-0000-0000-000000000001'''
\set RPRIV '''f8100000-0000-0000-0000-000000000002'''
\set RSECRET '''f8100000-0000-0000-0000-000000000003'''
\set RCUBE '''f8100000-0000-0000-0000-000000000004'''

select pg_temp.as_user(:ANA);
select public.friend_request(:BEN);
select pg_temp.as_user(:BEN);
select public.friend_respond(:ANA, true);

select pg_temp.as_user(:ANA);
select public.cube_ranking_create(:RSET, p_set => 'NRK');
select public.cube_ranking_create(:RPRIV, p_set => 'NRK', p_sharing => 'private');
select public.cube_ranking_create(:RSECRET, 'e8100000-0000-0000-0000-000000000001');
select public.cube_ranking_create(:RCUBE, 'e8100000-0000-0000-0000-000000000002');

-- The rankings a viewer gets on Ana's profile, newest first, as "<subject kind>:<subject name>".
create or replace function pg_temp.rows(p_owner uuid) returns text language sql as $$
  select coalesce(string_agg((r->'subject'->>'kind') || ':' || (r->'subject'->>'name'), ',' order by i), '')
    from jsonb_array_elements(public.profile_view(p_owner)->'sections'->'rankings') with ordinality t(r, i);
$$;
create or replace function pg_temp.has(p_owner uuid) returns text language sql as $$
  select (public.profile_view(p_owner)->'sections' ? 'rankings')::text;
$$;
-- Order by creation: the newest updated first.
update public.cube_rankings set updated_at = now() - (substr(id::text, 36)::int || ' minutes')::interval
 where id in (:RSET, :RPRIV, :RSECRET, :RCUBE);
select pg_temp.as_user(:ANA);

-- ==================================================================== defaults
select pg_temp.eq('the part defaults to friends', public.sharing_get()->>'rankings', 'friends');
select pg_temp.eq('your own profile lists all of yours, Only me too, newest first',
  pg_temp.rows(:ANA), 'set:New Rankings,set:New Rankings,list:Secret Cube,list:Friends Cube');
select pg_temp.eq('a row carries the ranking as Rankings lists it',
  (select (r->>'id') || ' ' || (r->>'sharing') || ' ' || (r->>'mine') || ' ' || (r->'subject'->>'id')
     from jsonb_array_elements(public.profile_view(:ANA)->'sections'->'rankings') r where r->>'id' = :RSET),
  'f8100000-0000-0000-0000-000000000001 cube true set:NRK');

select pg_temp.as_user(:BEN);
select pg_temp.eq('a friend: shared ones only, and a cube ranking only when the cube reaches them',
  pg_temp.rows(:ANA), 'set:New Rankings,list:Friends Cube');
select pg_temp.eq('rows read as someone else''s', (public.profile_view(:ANA)->'sections'->'rankings'->0->>'mine'), 'false');

select pg_temp.as_user(:CAL);
select pg_temp.eq('a stranger: a friends profile shows no section', pg_temp.has(:ANA), 'false');

-- ==================================================================== to anyone
select pg_temp.as_user(:ANA);
select public.sharing_set('{"profile": "public", "rankings": "public"}');
select pg_temp.eq('the change is audited', (select count(*)::text from public.account_audit
  where actor = :ANA and action = 'sharing.set' and after->>'rankings' = 'public'), '1');
select pg_temp.as_user(:CAL);
select pg_temp.eq('anyone: the shared set ranking reaches them now; the friends cube''s ranking still doesn''t',
  pg_temp.rows(:ANA), 'set:New Rankings');
select pg_temp.eq('and they can open it', public.cube_ranking_get(:RSET)->>'id', 'f8100000-0000-0000-0000-000000000001');
select pg_temp.throws('never the Only me one', format('select public.cube_ranking_get(%L)', :RPRIV), '42501');

-- ==================================================================== narrowing
select pg_temp.as_user(:ANA);
select public.sharing_set('{"rankings": "private"}');
select pg_temp.as_user(:BEN);
select pg_temp.eq('a private part: no section for a friend', pg_temp.has(:ANA), 'false');
select pg_temp.eq('a friend still opens the shared set ranking from its set (as before)',
  public.cube_ranking_get(:RSET)->>'id', 'f8100000-0000-0000-0000-000000000001');
select pg_temp.as_user(:CAL);
select pg_temp.throws('a stranger no longer opens it', format('select public.cube_ranking_get(%L)', :RSET), '42501');

select pg_temp.as_user(:ANA);
select public.sharing_set('{"profile": "private", "rankings": "public"}');
select pg_temp.as_user(:BEN);
select pg_temp.eq('a private profile caps the part', pg_temp.has(:ANA), 'false');
select pg_temp.as_user(:ANA);
select pg_temp.eq('your own profile still has it', pg_temp.has(:ANA), 'true');

-- ==================================================================== settings
select pg_temp.throws('rankings needs a value', $$select public.sharing_set('{"rankings": null}')$$, '22023');
select pg_temp.throws('and one of the three', $$select public.sharing_set('{"rankings": "everyone"}')$$, '22023');
select pg_temp.eq('other parts keep their values', (select (s->>'friends') || ',' || (s->>'listed') || ',' || (s->>'profile')
  from public.sharing_get() s), 'friends,friends,private');

-- A restricted account shares nothing.
select pg_temp.eq('before: the part as set', (t1_private.share_of(:ANA::uuid)).rankings, 'public');
insert into public.moderation_restrictions (user_id, until, reason, by_user) values (:ANA, now() + interval '1 day', 'test', :BEN);
select pg_temp.eq('restricted: rankings private', (t1_private.share_of(:ANA::uuid)).rankings, 'private');
