-- A cube followed through its share link can be ranked (contract/owned-by-card-2026-10-31.md § 3).
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com', '{"full_name": "Cal Reyes"}'),
  ('00000000-0000-0000-0000-0000000000d1', 'dee@example.com', '{"full_name": "Dee Park"}');
\set ANA '''00000000-0000-0000-0000-0000000000a1'''
\set CAL '''00000000-0000-0000-0000-0000000000c1'''
\set DEE '''00000000-0000-0000-0000-0000000000d1'''
insert into public.card_oracles (oracle_id, name, name_norm, layout, source_card_id, source_rank, content_hash) values
  ('c0000000-0000-0000-0000-000000000002', 'Opt', 'opt', 'normal', 'c1000000-0000-0000-0000-000000000002', 'a', 'h');
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash) values
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'xln', '65', 'en', 'common', '{nonfoil}', 'normal', 'h');
\set OPT '''c1000000-0000-0000-0000-000000000002'''
\set CUBE '''d1000000-0000-0000-0000-000000000002'''
\set R1 '''e1000000-0000-0000-0000-000000000001'''
\set R2 '''e1000000-0000-0000-0000-000000000002'''

set role authenticated;
select pg_temp.as_user(:ANA);
select public.list_create(:CUBE, 'cube', 'Pauper cube', 'cube', jsonb_build_array(jsonb_build_array(:OPT, 'main', 1)));
select (public.share_link_create('cube', :CUBE))->>'token' cube_tok \gset

-- Cal opened the link: he can't rank it until he follows through it.
select pg_temp.as_user(:CAL);
select pg_temp.throws('a link alone doesn''t rank', $$select public.cube_rankings('d1000000-0000-0000-0000-000000000002')$$, '42501');
select pg_temp.throws('or create a ranking', $$select public.cube_ranking_create('e1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000002')$$, '42501');
select public.follow_set('cube', :CUBE, true, null, :'cube_tok');
select pg_temp.eq('following through the link, he can', public.cube_rankings(:CUBE)->>'can_rank', 'true');
select pg_temp.eq('and rank it', public.cube_ranking_create(:R1, :CUBE)->>'id', 'e1000000-0000-0000-0000-000000000001');

-- Dee follows through the same link; Ana stops the link: neither sees it any more.
select pg_temp.as_user(:DEE);
select public.follow_set('cube', :CUBE, true, null, :'cube_tok');
select pg_temp.eq('Dee can rank too', public.cube_rankings(:CUBE)->>'can_rank', 'true');
select pg_temp.as_user(:ANA);
select public.share_link_revoke('cube', :CUBE);
select pg_temp.as_user(:DEE);
select pg_temp.throws('a stopped link closes it', $$select public.cube_rankings('d1000000-0000-0000-0000-000000000002')$$, '42501');
select pg_temp.as_user(:CAL);
select pg_temp.eq('Cal still reads his own ranking''s cube', public.cube_rankings(:CUBE)->>'can_rank', 'false');

-- A new link Cal follows again: unfollowing closes it.
select pg_temp.as_user(:ANA);
select (public.share_link_create('cube', :CUBE, true))->>'token' tok2 \gset
select pg_temp.as_user(:DEE);
select public.follow_set('cube', :CUBE, true, null, :'tok2');
select pg_temp.eq('the new link opens it', public.cube_rankings(:CUBE)->>'can_rank', 'true');
select public.follow_set('cube', :CUBE, false);
select pg_temp.throws('unfollowed, closed again', $$select public.cube_ranking_create('e1000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000002')$$, '42501');

-- Blocked by the owner: closed whatever the link.
select public.follow_set('cube', :CUBE, true, null, :'tok2');
select pg_temp.as_user(:ANA);
select public.user_block(:DEE, true);
select pg_temp.as_user(:DEE);
select pg_temp.throws('a block closes it', $$select public.cube_rankings('d1000000-0000-0000-0000-000000000002')$$, '42501');
reset role;
