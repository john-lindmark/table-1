-- Ranking a Limited set (20261030140000_limited_rankings.sql), new sets' cards from Scryfall's search
-- (20261030150000_catalog_new_sets.sql) and "New in Insights" pushes (20261030160000_insights_news.sql).
\ir _helpers.sql

-- Ana ranks; Ben is her friend; Cal is a stranger.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000057a1', 'ana@example.com', '{"full_name": "Ana Lind"}'),
  ('00000000-0000-0000-0000-0000000057b1', 'ben@example.com', '{"full_name": "Ben Ortiz"}'),
  ('00000000-0000-0000-0000-0000000057c1', 'cal@example.com', '{"full_name": "Cal Reyes"}');
\set ANA '''00000000-0000-0000-0000-0000000057a1'''
\set BEN '''00000000-0000-0000-0000-0000000057b1'''
\set CAL '''00000000-0000-0000-0000-0000000057c1'''

-- Set NEW (out in 5 days): two cards, one in two frames, a basic and a token; OLD (two years ago) isn't offered.
insert into public.mtg_sets (code, name, set_type, released_at, card_count) values
  ('new', 'New Horizons', 'expansion', current_date + 5, 300),
  ('old', 'Old Times', 'expansion', current_date - 800, 250),
  ('dig', 'Arena Only', 'alchemy', current_date - 10, 50),
  ('cmd', 'New Commander', 'commander', current_date + 5, 100);
update public.mtg_sets set digital = true where code = 'dig';
create or replace function pg_temp.card(p_n int, p_name text, p_type text, p_set text, p_num text, p_layout text default 'normal')
returns void language sql as $$
  insert into public.card_oracles (oracle_id, name, name_norm, layout, type_line, source_card_id, source_rank, content_hash)
  values (('c0000000-0000-0000-0000-' || lpad(p_n::text, 12, '0'))::uuid, p_name, lower(p_name), p_layout, p_type,
          ('c1000000-0000-0000-0000-' || lpad(p_n::text, 12, '0'))::uuid, 'a', 'h')
  on conflict do nothing;
  insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash)
  values (('c1000000-0000-0000-' || lpad(p_num, 4, '0') || '-' || lpad(p_n::text, 12, '0'))::uuid,
          ('c0000000-0000-0000-0000-' || lpad(p_n::text, 12, '0'))::uuid, p_set, p_num, 'en', 'common', '{nonfoil}', p_layout, 'h');
$$;
select pg_temp.card(1, 'Horizon Drake', 'Creature — Drake', 'new', '12'),
       pg_temp.card(1, 'Horizon Drake', 'Creature — Drake', 'new', '301'),
       pg_temp.card(2, 'Dawn Bolt', 'Instant', 'new', '140'),
       pg_temp.card(3, 'Plains', 'Basic Land — Plains', 'new', '262'),
       pg_temp.card(4, 'Spirit', 'Token Creature — Spirit', 'new', '1', 'token'),
       pg_temp.card(5, 'Old Bear', 'Creature — Bear', 'old', '7');
\set DRAKE '''c0000000-0000-0000-0000-000000000001'''
\set BOLT '''c0000000-0000-0000-0000-000000000002'''
\set R1 '''f5700000-0000-0000-0000-000000000001'''
\set R2 '''f5700000-0000-0000-0000-000000000002'''
\set R3 '''f5700000-0000-0000-0000-000000000003'''

-- What a set ranks ----------------------------------------------------------------------------------------------
select pg_temp.eq('a set ranks its cards once each, no basics or tokens, in their lowest number',
  (select string_agg(o.name || ' ' || c.collector_number, ', ' order by o.name)
     from t1_private.limited_set_printings('NEW') p join public.card_oracles o on o.oracle_id = p.oracle_id join public.cards c on c.id = p.card_id),
  'Dawn Bolt 140, Horizon Drake 12');
select pg_temp.eq('subjects: paper draft sets and cube versions only',
  t1_private.limited_subject_ok('NEW')::text || t1_private.limited_subject_ok('DIG')::text || t1_private.limited_subject_ok('CMD')::text
  || t1_private.limited_subject_ok('new')::text || t1_private.limited_subject_ok('NOPE')::text, 'truefalsefalsefalsefalse');

set role authenticated;
select pg_temp.as_user(:ANA);
select public.friend_request(:BEN);
select pg_temp.as_user(:BEN);
select public.friend_respond(:ANA, true);

-- Starting one ------------------------------------------------------------------------------------------------
select pg_temp.as_user(:ANA);
select pg_temp.eq('a set ranking starts with no cube, keyed by the set',
  (select coalesce(r->>'list_id', 'none') || ' ' || (r->>'set_key') || ' ' || (r->>'sharing')
     from public.cube_ranking_create(:R1, p_set => 'new', p_depth => 'third') r), 'none NEW cube');
select pg_temp.eq('its baseline is the set''s cards',
  public.cube_ranking_get(:R1)->>'baseline', jsonb_build_array(:DRAKE, :BOLT)::text);
select pg_temp.throws('a cube and a set at once is refused',
  $$select public.cube_ranking_create('f5700000-0000-0000-0000-0000000000ff', 'e7000000-0000-0000-0000-000000000001', p_set => 'NEW')$$, '22023');
select pg_temp.throws('neither is refused', $$select public.cube_ranking_create('f5700000-0000-0000-0000-0000000000ff')$$, '22023');
select pg_temp.throws('a set that isn''t one is refused', $$select public.cube_ranking_create('f5700000-0000-0000-0000-0000000000ff', p_set => 'DIG')$$, '22023');
select pg_temp.eq('a retry returns the same ranking', public.cube_ranking_create(:R1, p_set => 'NEW')->>'set_key', 'NEW');
select public.cube_ranking_create(:R2, p_set => 'NEW', p_sharing => 'private');

select pg_temp.eq('get: the set as the ranking''s cube, with its cards and printings',
  (select (c->>'set') || ' ' || (c->>'kind') || ' ' || (c->>'name') || ' ' || coalesce(c->>'id', 'null') || ' '
          || jsonb_array_length(c->'cards') || ' ' || (c->'printings'->>(:DRAKE)::text)
     from (select public.cube_ranking_get(:R1)->'cube' c) x),
  'NEW set New Horizons set:NEW 2 c1000000-0000-0000-0012-000000000001');
select pg_temp.eq('pushing screens works as for cubes',
  public.cube_ranking_push(:R1, 0, 0, jsonb_build_array(jsonb_build_object('s', 'F', 'o', jsonb_build_array(:BOLT, :DRAKE))),
                           p_count => 0, p_removed => 0)->>'screens', '1');

-- Who sees it -------------------------------------------------------------------------------------------------
select pg_temp.as_user(:BEN);
select pg_temp.eq('a friend sees the shared one, not the private one',
  (select string_agg(r->>'id', ',') from jsonb_array_elements(public.cube_rankings(p_set => 'NEW')->'rankings') r), 'f5700000-0000-0000-0000-000000000001');
select pg_temp.eq('and can open it', public.cube_ranking_get(:R1)->>'screens', '1');
select pg_temp.eq('anyone can rank the set', public.cube_rankings(p_set => 'NEW')->>'can_rank', 'true');
select pg_temp.as_user(:CAL);
select pg_temp.eq('a stranger sees none of Ana''s', jsonb_array_length(public.cube_rankings(p_set => 'NEW')->'rankings')::text, '0');
select pg_temp.throws('nor opens it', format('select public.cube_ranking_get(%L)', :R1), '42501');
select pg_temp.throws('nor pushes to it',
  format($$select public.cube_ranking_push(%L, 1, 1, '[]'::jsonb, p_count => 1, p_removed => 0)$$, :R1), '42501');

-- Listing -----------------------------------------------------------------------------------------------------
select pg_temp.as_user(:ANA);
select pg_temp.eq('your rankings leave sets out for builds that don''t know them',
  jsonb_array_length(public.cube_rankings()->'rankings')::text, '0');
select pg_temp.eq('and list them with p_sets, each with its set',
  (select string_agg(r->'cube'->>'set', ',') from jsonb_array_elements(public.cube_rankings(p_sets => true)->'rankings') r), 'NEW,NEW');
select pg_temp.eq('rankable: recent and upcoming paper sets with 60+ cards (none here) and cube versions',
  public.limited_rankable()::text, '[]');
reset role;
insert into public.card_oracles (oracle_id, name, name_norm, layout, type_line, source_card_id, source_rank, content_hash)
select ('c0000000-0000-0000-0001-' || lpad(n::text, 12, '0'))::uuid, 'Filler ' || n, 'filler ' || n, 'normal', 'Creature',
       ('c1000000-0000-0000-9999-' || lpad(n::text, 12, '0'))::uuid, 'a', 'h' from generate_series(1, 120) n;
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash)
select ('c1000000-0000-0000-9999-' || lpad(n::text, 12, '0'))::uuid, ('c0000000-0000-0000-0001-' || lpad(n::text, 12, '0'))::uuid,
       'new', (500 + n)::text, 'en', 'common', '{nonfoil}', 'normal', 'h' from generate_series(1, 120) n;
insert into public.card_names (name_norm, oracle_id, is_face) select public.card_name_norm(name), oracle_id, false from public.card_oracles
on conflict do nothing;
select public.limited_cube_version('PWR', '2025-10-30', array['Horizon Drake', 'Dawn Bolt', 'Nothing Like It']);
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('rankable lists the set (122 cards, yours 2) and the cube version, newest first',
  (select string_agg((x->>'key') || ' ' || (x->>'kind') || ' ' || (x->>'cards') || ' ' || (x->>'mine') || ' ' || (x->>'rankings') || ' ' || (x->>'pack'), ', ')
     from jsonb_array_elements(public.limited_rankable()) x), 'NEW set 122 2 2 false, PWR-2510 cube 2 0 0 false');
select public.cube_ranking_create(:R3, p_set => 'pwr-2510');
select pg_temp.eq('a cube version ranks 17Lands'' cards, drawn in their usual art',
  (select (c->>'kind') || ' ' || (c->>'name') || ' ' || jsonb_array_length(c->'cards') || ' ' || (c->'printings')::text
     from (select public.cube_ranking_get(:R3)->'cube' c) x),
  'cube Arena Powered Cube · Oct 2025 2 {}');
select pg_temp.eq('cards the set gains wait outside: catch-up takes them in',
  jsonb_array_length(public.cube_ranking_catch_up(:R1)->'baseline')::text, '122');

-- Moderation: a shared set ranking's name reaches friends -------------------------------------------------------
select public.cube_ranking_update(:R1, p_name => 'Bombs first');
reset role;
select pg_temp.eq('a shared set ranking''s name is checked when made and renamed',
  (select count(*)::text from public.moderation_checks where subject_kind = 'ranking_name' and subject_id = :R1), '2');
select pg_temp.eq('an Only me one isn''t', (select count(*)::text from public.moderation_checks where subject_id = :R2), '0');

-- New sets from Scryfall's search -------------------------------------------------------------------------------
select pg_temp.eq('gaps: recent paper sets with more cards at Scryfall than here, never fetched or changed since',
  (select string_agg(x->>'code', ',' order by x->>'code') from jsonb_array_elements(public.catalog_set_gaps()->'sets') x), 'cmd,new');
select public.catalog_sets_begin() as srun \gset
select pg_temp.eq('a set run never shows as an active bulk run',
  (select status from t1_private.catalog_runs where id = :srun), 'sets');
select pg_temp.eq('the bulk run still begins while a set run is open',
  (public.catalog_run_begin(now() - interval '1 day', 'https://x/bulk.json') is not null)::text, 'true');
update t1_private.catalog_runs set status = 'failed' where source_uri = 'https://x/bulk.json';
select pg_temp.eq('one set run at a time', coalesce(public.catalog_sets_begin()::text, 'null'), 'null');
select public.catalog_set_fetched(:srun, 'new', 300, 122), public.catalog_set_fetched(:srun, 'cmd', 100, 0);
select pg_temp.eq('fetched sets wait until Scryfall''s count changes',
  public.catalog_set_gaps()->>'sets', '[]');
select pg_temp.eq('finishing without a pack', public.catalog_sets_finish(:srun, false), 'done');
select pg_temp.eq('closes the run', (select status from t1_private.catalog_runs where id = :srun), 'done');
update public.mtg_sets set card_count = 310 where code = 'new';
select pg_temp.eq('a set that grows is read again',
  (select string_agg(x->>'code', ',') from jsonb_array_elements(public.catalog_set_gaps()->'sets') x), 'new');
update t1_private.catalog_runs set cards_changed = 3 where id = :srun;
select pg_temp.eq('a set run that changed cards owes a pack (no pack yet)', public.catalog_set_gaps()->>'pack_due', 'true');
insert into t1_private.catalog_packs (version, format, path, bytes, sha256, oracles, printings) values ('v1-x', 1, 'p', 1, 's', 1, 1);
select pg_temp.eq('not right after a pack', public.catalog_set_gaps()->>'pack_due', 'false');
select public.catalog_sets_begin() as srun2 \gset
select pg_temp.eq('packing', public.catalog_sets_finish(:srun2, true), 'packing');
select pg_temp.eq('posts cards-sync''s pack step for the run', (select body::text from net.requests order by id desc limit 1),
  '{"run": ' || :srun2 || ', "step": "pack"}');
set role authenticated;
select pg_temp.throws('the worker calls are the service role''s', $$select public.catalog_set_gaps()$$, '42501');
reset role;

-- New in Insights ---------------------------------------------------------------------------------------------
create or replace function pg_temp.news() returns text language sql security definer as $$
  select coalesce(string_agg((m.msg->'data'->>'what') || ':' || (m.msg->'data'->>'insights_key') || '>'
                    || jsonb_array_length(m.msg->'user_ids'), ' ' order by m.msg_id), '-')
    from pgmq.messages m where m.msg->>'kind' = 'insights.new'
$$;
insert into public.devices (user_id, platform, push_token) values (:ANA, 'ios', 'ios-a'), (:BEN, 'android', 'fcm-b'), (:CAL, 'ios', 'ios-c');
set role authenticated;
select pg_temp.as_user(:ANA);
select pg_temp.eq('opening Insights lists the packs (none yet)', public.insights_index()::text, '[]');
select pg_temp.as_user(:BEN);
select public.insights_index();
select pg_temp.eq('alerts are on by default', public.insights_alerts()->>'on', 'true');
select pg_temp.eq('Ben turns them off', public.insights_alerts_set(false)->>'on', 'false');
select pg_temp.eq('and reads them off', public.insights_alerts()->>'on', 'false');
reset role;
select pg_temp.eq('viewers are recorded once a day', (select count(*)::text from t1_private.insights_viewers), '2');
select pg_temp.eq('a set ready to rank is announced once, to viewers with alerts on and a device',
  t1_private.insights_rank_ready() || ' ' || t1_private.insights_rank_ready() || ' ' || pg_temp.news(), '1 0 rank:NEW>1');
select public.insight_pack_publish('limited', 'NEW', 'New Horizons', 0, 'l-1', 'insights/limited/NEW.json', 10, 's', null);
select pg_temp.eq('its first draft data is news too', pg_temp.news(), 'rank:NEW>1 data:NEW>1');
select public.insight_pack_publish('limited', 'NEW', 'New Horizons', 0, 'l-2', 'insights/limited/NEW.json', 11, 's', null);
select pg_temp.eq('a rebuilt pack isn''t', pg_temp.news(), 'rank:NEW>1 data:NEW>1');
select public.insight_pack_publish('constructed', 'vintage', 'Vintage', 5, 'c-1', 'insights/constructed/vintage.json', 10, 's', current_date);
select pg_temp.eq('a new Constructed format is', pg_temp.news(), 'rank:NEW>1 data:NEW>1 data:vintage>1');
select pg_temp.eq('the push carries where it opens',
  (select (msg->'data')::text from pgmq.messages where msg->'data'->>'insights_key' = 'vintage'),
  '{"name": "Vintage", "what": "data", "insights_key": "vintage", "insights_section": "constructed"}');
update t1_private.insights_viewers set seen_at = now() - interval '61 days' where user_id = :ANA;
select pg_temp.eq('nobody who hasn''t opened Insights in 60 days hears',
  t1_private.insights_announce('limited', 'PWR-2606', 'Arena Powered Cube · Jun 2026', 'data')::text, '0');
set role authenticated;
select pg_temp.as_user(:CAL);
select pg_temp.throws('announcing is the server''s', $$select t1_private.insights_announce('limited', 'X', 'X', 'data')$$, '42501');
