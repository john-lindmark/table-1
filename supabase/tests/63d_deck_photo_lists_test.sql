-- Decklists read from deck photos (20261113150000_deck_photo_lists, contract/deck-photo-lists-2026-11-13.md):
-- a new photo queues a read, the function's claim carries the event's pool, the finish keeps the list and tells the
-- player once, editors correct it, everyone who sees the photo reads it, nobody else gets in.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000d3a1', 'org@example.com'),
  ('00000000-0000-0000-0000-00000000d3b1', 'bea@example.com'),
  ('00000000-0000-0000-0000-00000000d3c1', 'cal@example.com'),
  ('00000000-0000-0000-0000-00000000d3d1', 'dee@example.com');
\set A '''00000000-0000-0000-0000-00000000d3a1'''
\set B '''00000000-0000-0000-0000-00000000d3b1'''
\set C '''00000000-0000-0000-0000-00000000d3c1'''
\set D '''00000000-0000-0000-0000-00000000d3d1'''
\set EV '''e0000000-0000-0000-0000-0000000063d1'''
\set EC '''e0000000-0000-0000-0000-0000000063d2'''
\set EM '''e0000000-0000-0000-0000-0000000063d3'''
\set PB '''f2000000-0000-0000-0000-0000000063db'''
\set PC '''f2000000-0000-0000-0000-0000000063dc'''
\set PG '''f2000000-0000-0000-0000-0000000063df'''
\set PH1 '''d0000000-0000-0000-0000-0000000063d1'''
\set PH2 '''d0000000-0000-0000-0000-0000000063d2'''
\set PH3 '''d0000000-0000-0000-0000-0000000063d3'''
insert into t1_private.settings (name, value) values ('live_push_secret', 's3cret') on conflict (name) do nothing;

-- A small catalog: set "tst" with five cards (one of them in two printings), a card of another set, a basic.
insert into public.card_oracles (oracle_id, name, name_norm, layout, type_line, source_card_id, source_rank, content_hash) values
  ('c63d0000-0000-0000-0000-000000000001', 'Goblin Guide', 'goblin guide', 'normal', 'Creature — Goblin', 'a63d0000-0000-0000-0000-000000000001', 'a', 'h'),
  ('c63d0000-0000-0000-0000-000000000002', 'Lórien Revealed', 'lorien revealed', 'normal', 'Sorcery', 'a63d0000-0000-0000-0000-000000000002', 'a', 'h'),
  ('c63d0000-0000-0000-0000-000000000003', 'Fire // Ice', 'fire ice', 'split', 'Instant', 'a63d0000-0000-0000-0000-000000000003', 'a', 'h'),
  ('c63d0000-0000-0000-0000-000000000004', 'Mana Drain', 'mana drain', 'normal', 'Instant', 'a63d0000-0000-0000-0000-000000000004', 'a', 'h'),
  ('c63d0000-0000-0000-0000-000000000005', 'Arrogant Wurm', 'arrogant wurm', 'normal', 'Creature — Wurm', 'a63d0000-0000-0000-0000-000000000005', 'a', 'h'),
  ('c63d0000-0000-0000-0000-000000000006', 'Island', 'island', 'normal', 'Basic Land — Island', 'a63d0000-0000-0000-0000-000000000006', 'a', 'h');
insert into public.card_names (name_norm, oracle_id, is_face) values
  ('goblin guide', 'c63d0000-0000-0000-0000-000000000001', false), ('lorien revealed', 'c63d0000-0000-0000-0000-000000000002', false),
  ('fire ice', 'c63d0000-0000-0000-0000-000000000003', false), ('fire', 'c63d0000-0000-0000-0000-000000000003', true),
  ('ice', 'c63d0000-0000-0000-0000-000000000003', true), ('mana drain', 'c63d0000-0000-0000-0000-000000000004', false),
  ('arrogant wurm', 'c63d0000-0000-0000-0000-000000000005', false), ('island', 'c63d0000-0000-0000-0000-000000000006', false);
insert into public.cards (id, oracle_id, set_code, collector_number, lang, rarity, finishes, layout, content_hash, released_at, image_faces) values
  ('d63d0000-0000-0000-0000-000000000001', 'c63d0000-0000-0000-0000-000000000001', 'tst', '10', 'en', 'rare', '{nonfoil}', 'normal', 'h', '2026-01-01', 1),
  ('d63d0000-0000-0000-0000-000000000011', 'c63d0000-0000-0000-0000-000000000001', 'tst', '310', 'en', 'rare', '{nonfoil}', 'normal', 'h', '2026-01-01', 1),
  ('d63d0000-0000-0000-0000-000000000002', 'c63d0000-0000-0000-0000-000000000002', 'tst', '11', 'en', 'common', '{nonfoil}', 'normal', 'h', '2026-01-01', 1),
  ('d63d0000-0000-0000-0000-000000000003', 'c63d0000-0000-0000-0000-000000000003', 'tst', '12', 'en', 'common', '{nonfoil}', 'split', 'h', '2026-01-01', 1),
  ('d63d0000-0000-0000-0000-000000000004', 'c63d0000-0000-0000-0000-000000000004', 'tst', '13', 'en', 'rare', '{nonfoil}', 'normal', 'h', '2026-01-01', 1),
  ('d63d0000-0000-0000-0000-000000000005', 'c63d0000-0000-0000-0000-000000000005', 'old', '1', 'en', 'common', '{nonfoil}', 'normal', 'h', '2001-01-01', 1),
  ('d63d0000-0000-0000-0000-000000000006', 'c63d0000-0000-0000-0000-000000000006', 'old', '2', 'en', 'common', '{nonfoil}', 'normal', 'h', '2001-01-01', 1),
  ('d63d0000-0000-0000-0000-000000000016', 'c63d0000-0000-0000-0000-000000000006', 'tst', '90', 'en', 'common', '{nonfoil}', 'normal', 'h', '2026-01-01', 1);

-- Alice runs a draft of "tst" (Bea and Cal play, Gus is a guest), a cube night with her cube, and a Modern event.
insert into public.events (id, short_code, name, created_by, status, current_round, format, set_code, set_name) values
  (:EV, 'PL63D1', 'Friday draft', :A, 'in_progress', 1, 'draft', 'tst', 'Test Set');
insert into public.events (id, short_code, name, created_by, status, current_round, format, cube_name) values
  (:EC, 'PL63D2', 'Cube night', :A, 'in_progress', 1, 'cube', 'Alice Cube');
insert into public.events (id, short_code, name, created_by, status, current_round, format, format_name) values
  (:EM, 'PL63D3', 'Modern night', :A, 'in_progress', 1, 'constructed', 'modern');
insert into public.event_members (event_id, user_id, role) values (:EV, :A, 'owner'), (:EC, :A, 'owner'), (:EM, :A, 'owner');
insert into public.participants (id, event_id, user_id, display_name, seat) values
  (:PB, :EV, :B, 'Bea', 1), (:PC, :EV, :C, 'Cal', 2), (:PG, :EV, null, 'Gus', 3);
insert into public.card_lists (id, user_id, kind, name, format, current_version, seq) values
  ('163d0000-0000-0000-0000-000000000001', :A, 'cube', 'alice cube', 'vintage', 1, nextval('public.card_list_seq')),
  ('163d0000-0000-0000-0000-000000000002', :D, 'cube', 'Alice Cube', 'vintage', 1, nextval('public.card_list_seq'));
insert into public.card_list_entries (list_id, card_id, board, qty) values
  ('163d0000-0000-0000-0000-000000000001', 'd63d0000-0000-0000-0000-000000000004', 'main', 1),
  ('163d0000-0000-0000-0000-000000000001', 'd63d0000-0000-0000-0000-000000000005', 'main', 1),
  ('163d0000-0000-0000-0000-000000000001', 'd63d0000-0000-0000-0000-000000000001', 'maybe', 1),
  ('163d0000-0000-0000-0000-000000000002', 'd63d0000-0000-0000-0000-000000000002', 'main', 1);

create or replace function pg_temp.kicks() returns text language sql security definer as $$
  select count(*)::text from net.requests where url like '%/functions/v1/deck-photo-read';
$$;
create or replace function pg_temp.row(p uuid) returns text language sql security definer as $$
  select status || ':' || attempts || ':' || reads from t1_private.deck_photo_lists where photo_id = p;
$$;
create or replace function pg_temp.pushes() returns text language sql security definer as $$
  select coalesce(string_agg((msg->'data'->>'cards') || '/' || (msg->'data'->>'check') || '>' || (msg->'user_ids'->>0), ' ' order by msg_id), '-')
    from pgmq.messages where msg->>'kind' = 'deck.read';
$$;
create or replace function pg_temp.pool(p uuid) returns jsonb language sql security definer as $$ select t1_private.deck_photo_pool(p) $$;
create or replace function pg_temp.svc(p text) returns jsonb language plpgsql security definer as $$
declare r jsonb; begin execute p into r; return r; end $$;
create or replace function pg_temp.age(p uuid, s interval) returns void language sql security definer as $$
  update t1_private.deck_photo_lists set queued_at = queued_at - s, started_at = started_at - s where photo_id = p;
$$;
create or replace function pg_temp.sweep() returns void language sql security definer as $$ select t1_private.deck_photo_read_sweep() $$;
create or replace function pg_temp.audit() returns text language sql security definer as $$
  select (before->>'cards') || '>' || (after->>'cards') from public.audit_log where action = 'deck_photo.list_saved' order by at desc limit 1;
$$;
grant execute on all functions in schema pg_temp to authenticated;
grant usage on schema storage to authenticated;
grant select, insert, update, delete on storage.objects to authenticated;

-- The pool -------------------------------------------------------------------------------------------------------
select pg_temp.eq('a set event''s pool is one printing per card of the set, by name',
  (select string_agg((c->>0) || '=' || right(c->>1, 2), ', ' order by c->>0) from jsonb_array_elements(pg_temp.pool(:EV)->'cards') c),
  'Fire // Ice=03, Goblin Guide=01, Island=16, Lórien Revealed=02, Mana Drain=04');
select pg_temp.eq('the set pool is labelled with the set', pg_temp.pool(:EV)->>'kind' || ':' || (pg_temp.pool(:EV)->>'label'), 'set:Test Set');
select pg_temp.eq('a cube event''s pool is the organizer''s cube of that name (main board), not a stranger''s',
  (select string_agg(c->>0, ', ' order by c->>0) from jsonb_array_elements(pg_temp.pool(:EC)->'cards') c), 'Arrogant Wurm, Mana Drain');
select pg_temp.eq('a constructed event has no pool', pg_temp.pool(:EM)->>'kind' || ':' || jsonb_array_length(pg_temp.pool(:EM)->'cards'), 'none:0');

-- A new photo is read ----------------------------------------------------------------------------------------------
set role authenticated;
select pg_temp.as_user(:B);
insert into storage.objects (bucket_id, name, owner_id)
values ('deck-photos', 'e0000000-0000-0000-0000-0000000063d1/d0000000-0000-0000-0000-0000000063d1.jpg', :B);
select pg_temp.eq('before any read the photo row has no list', (public.deck_photo_add(:PH1, :EV, :PB, '')->'photos'->0->'list'->>'status'), 'queued');
select pg_temp.eq('adding a photo queued one read and posted it to the function', pg_temp.row(:PH1) || ' ' || pg_temp.kicks(), 'queued:1:0 1');
select pg_temp.eq('adding the same photo again queues nothing more', (public.deck_photo_add(:PH1, :EV, :PB, '')->'photos'->0->'list'->>'status') || pg_temp.kicks(), 'queued1');
select pg_temp.eq('the player sees it reading, with nothing yet',
  (select (l->>'status') || ':' || jsonb_array_length(l->'entries') || ':' || (l->>'editable') from public.deck_photo_list(:PH1) l), 'queued:0:true');
select pg_temp.eq('asking while it reads starts nothing new', (public.deck_photo_read_start(:PH1)->>'status') || pg_temp.kicks(), 'queued1');
select pg_temp.throws('clients cannot claim a read', $$select public.deck_photo_read_claim('d0000000-0000-0000-0000-0000000063d1')$$, '42501');
select pg_temp.throws('clients cannot finish a read', $$select public.deck_photo_read_finish('d0000000-0000-0000-0000-0000000063d1', '{}')$$, '42501');
select pg_temp.throws('clients cannot ask the catalog helper', $$select public.deck_photo_read_names(array['Island'])$$, '42501');

-- The function's side ---------------------------------------------------------------------------------------------
select pg_temp.eq('the claim hands over the photo, the event and its pool',
  (select (j->>'path' like '%63d1.jpg')::text || ':' || (j->'event'->>'event_type') || ':' || (j->'pool'->>'kind') || ':' || jsonb_array_length(j->'pool'->'cards')
     from pg_temp.svc($$select public.deck_photo_read_claim('d0000000-0000-0000-0000-0000000063d1')$$) j), 'true:limited:set:5');
select pg_temp.eq('a second claim gets nothing', pg_temp.svc($$select public.deck_photo_read_claim('d0000000-0000-0000-0000-0000000063d1')$$)::text, null);
select pg_temp.eq('the claim counted the read', pg_temp.row(:PH1), 'reading:1:1');
select pg_temp.svc($$select to_jsonb(public.deck_photo_read_progress('d0000000-0000-0000-0000-0000000063d1', '["Looking at the photo", "", "Reading against Test Set: 5 cards"]'))$$);
select pg_temp.eq('the steps show while it reads', (public.deck_photo_list(:PH1)->'steps')::text, '["Looking at the photo", "Reading against Test Set: 5 cards"]');
select pg_temp.eq('names: exact, without accents, a split card''s half, a near miss, nothing',
  (select string_agg(coalesce(n->>'name', '-') || '/' || coalesce(n->>'exact', '-') || '/' || coalesce(right(n->>'card_id', 2), '-'), ' | ' order by ord)
     from jsonb_array_elements(pg_temp.svc($$select public.deck_photo_read_names(array['Goblin Guide', 'lorien revealed', 'Fire', 'Arogant Wurm', 'Zzzz Qqqq', 'Island'])$$)) with ordinality t(n, ord)),
  'Goblin Guide/true/01 | Lórien Revealed/true/02 | Fire // Ice/true/03 | Arrogant Wurm/false/05 | -/-/- | Island/true/06');
select pg_temp.svc($$select to_jsonb(public.deck_photo_read_finish('d0000000-0000-0000-0000-0000000063d1', '{"status": "done", "model": "m", "notes": "glare",
  "pool": {"kind": "set", "label": "Test Set", "size": 5},
  "cards": [{"card_id": "d63d0000-0000-0000-0000-000000000001", "name": "ignored", "qty": 2, "board": "main", "sure": true},
            {"card_id": "d63d0000-0000-0000-0000-000000000016", "name": "Island", "qty": 17, "board": "main", "sure": false, "read": "pile of about 17"},
            {"card_id": null, "name": "Room of", "qty": 1, "board": "main", "sure": false},
            {"card_id": "d63d0000-0000-0000-0000-000000000004", "name": "Mana Drain", "qty": 400, "board": "nonsense", "sure": true},
            {"card_id": "d63d0000-0000-0000-0000-000000000003", "name": "Fire // Ice", "qty": 1, "board": "out", "sure": true},
            {"card_id": "00000000-0000-0000-0000-00000000dead", "name": "", "qty": 1, "board": "main"}]}'))$$);
select pg_temp.eq('the list is kept clean: catalog names, counts capped, unknown boards main, cardless nameless lines dropped',
  (select string_agg((e->>'name') || ' x' || (e->>'qty') || ' ' || (e->>'board') || ' ' || (e->>'sure') || coalesce(' [' || (e->>'read') || ']', ''), ' | ' order by ord)
     from jsonb_array_elements(public.deck_photo_list(:PH1)->'entries') with ordinality t(e, ord)),
  'Goblin Guide x2 main true | Island x17 main false [pile of about 17] | Room of x1 main false | Mana Drain x99 main true | Fire // Ice x1 out true');
select pg_temp.eq('done, with the pool it was read against and the reader''s note',
  (select (l->>'status') || ':' || (l->'pool'->>'label') || ':' || (l->>'notes') || ':' || (l->>'checked') || ':' || (l->>'reads_left') from public.deck_photo_list(:PH1) l),
  'done:Test Set:glare:false:4');
select pg_temp.eq('the player is told once: cards in the deck (not the left-out one) and lines to check',
  pg_temp.pushes(), '119/2>00000000-0000-0000-0000-00000000d3b1');
select pg_temp.eq('the photo row carries the list''s state',
  (public.deck_photos(:EV)->'photos'->0->'list')::text, '{"cards": 119, "check": 2, "status": "done", "checked": false}');
select pg_temp.eq('and so does Account → Deck photos', (public.my_deck_photos()->'photos'->0->'list'->>'cards'), '119');

-- Correcting -------------------------------------------------------------------------------------------------------
select pg_temp.eq('the player corrects the list',
  (select (l->>'checked') || ':' || (select string_agg((e->>'name') || ' x' || (e->>'qty'), ', ' order by ord) from jsonb_array_elements(l->'entries') with ordinality t(e, ord))
     from public.deck_photo_list_save(:PH1, '[{"card_id": "d63d0000-0000-0000-0000-000000000001", "qty": 2, "board": "main", "sure": true},
       {"card_id": "d63d0000-0000-0000-0000-000000000016", "qty": 17, "board": "main", "sure": true},
       {"card_id": "d63d0000-0000-0000-0000-000000000002", "qty": 21, "board": "main", "sure": true}]') l),
  'true:Goblin Guide x2, Island x17, Lórien Revealed x21');
select pg_temp.eq('the row shows it checked', (public.deck_photos(:EV)->'photos'->0->'list')::text, '{"cards": 40, "check": 0, "status": "done", "checked": true}');
select pg_temp.throws('not a list is refused', $$select public.deck_photo_list_save('d0000000-0000-0000-0000-0000000063d1', '{}')$$, '22023');
select pg_temp.eq('the save is audited with counts', pg_temp.audit(), '119>40');

-- Who gets in ------------------------------------------------------------------------------------------------------
select pg_temp.as_user(:C);
select pg_temp.throws('another player can''t see her list mid-event', $$select public.deck_photo_list('d0000000-0000-0000-0000-0000000063d1')$$, 'P0002');
select pg_temp.throws('or correct it', $$select public.deck_photo_list_save('d0000000-0000-0000-0000-0000000063d1', '[]')$$, 'P0002');
select pg_temp.throws('or have it read', $$select public.deck_photo_read_start('d0000000-0000-0000-0000-0000000063d1')$$, 'P0002');
select pg_temp.as_user(:D);
select pg_temp.throws('someone outside the event sees nothing', $$select public.deck_photo_list('d0000000-0000-0000-0000-0000000063d1')$$, 'P0002');
select pg_temp.as_user(null);
select pg_temp.throws('signed out is refused', $$select public.deck_photo_list('d0000000-0000-0000-0000-0000000063d1')$$);

-- The organizer corrects too, and reads again; the event ends and everyone reads, only editors write.
select pg_temp.as_user(:A);
select pg_temp.eq('the organizer may correct any list', (public.deck_photo_list(:PH1)->>'editable'), 'true');
select pg_temp.eq('the organizer reads it again', (public.deck_photo_read_start(:PH1)->>'status') || ' ' || pg_temp.row(:PH1) || ' ' || pg_temp.kicks(), 'queued queued:1:1 2');
select pg_temp.eq('the corrected list stays up while it reads', jsonb_array_length(public.deck_photo_list(:PH1)->'entries')::text, '3');
select pg_temp.svc($$select public.deck_photo_read_claim('d0000000-0000-0000-0000-0000000063d1')$$);
select pg_temp.svc($$select to_jsonb(public.deck_photo_read_finish('d0000000-0000-0000-0000-0000000063d1', '{"status": "failed", "message": "Too dark"}'))$$);
select pg_temp.eq('a failed second read keeps the list and says why',
  (select (l->>'status') || ':' || jsonb_array_length(l->'entries') || ':' || (l->>'message') || ':' || (l->>'checked') from public.deck_photo_list(:PH1) l), 'done:3:Too dark:true');
select pg_temp.eq('no second push', pg_temp.pushes(), '119/2>00000000-0000-0000-0000-00000000d3b1');
reset role;
update public.events set status = 'completed' where id = :EV;
set role authenticated;
select pg_temp.as_user(:C);
select pg_temp.eq('after the event another player reads the list, read-only',
  (select jsonb_array_length(l->'entries') || ':' || (l->>'editable') || ':' || (l->>'player') from public.deck_photo_list(:PH1) l), '3:false:Bea');
select pg_temp.throws('but can''t correct it', $$select public.deck_photo_list_save('d0000000-0000-0000-0000-0000000063d1', '[]')$$, '42501');
select pg_temp.throws('or ask for another read', $$select public.deck_photo_read_start('d0000000-0000-0000-0000-0000000063d1')$$, '42501');

-- A guest's photo: read, nobody to tell. A photo from before this existed: anyone who sees it may ask once.
select pg_temp.as_user(:A);
insert into storage.objects (bucket_id, name, owner_id)
values ('deck-photos', 'e0000000-0000-0000-0000-0000000063d1/d0000000-0000-0000-0000-0000000063d2.jpg', :A);
select public.deck_photo_add(:PH2, :EV, :PG, '') is not null;
select pg_temp.svc($$select public.deck_photo_read_claim('d0000000-0000-0000-0000-0000000063d2')$$) is not null;
select pg_temp.svc($$select to_jsonb(public.deck_photo_read_finish('d0000000-0000-0000-0000-0000000063d2', '{"status": "done", "cards": [{"card_id": "d63d0000-0000-0000-0000-000000000001", "qty": 1, "board": "main", "sure": true}]}'))$$);
select pg_temp.eq('a guest gets no push', pg_temp.pushes(), '119/2>00000000-0000-0000-0000-00000000d3b1');
reset role;
alter table public.event_deck_photos disable trigger deck_photo_read_on_add;
insert into public.event_deck_photos (id, event_id, participant_id, uploaded_by, path)
values (:PH3, :EV, :PC, :C, 'e0000000-0000-0000-0000-0000000063d1/d0000000-0000-0000-0000-0000000063d3.jpg');
alter table public.event_deck_photos enable trigger deck_photo_read_on_add;
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.eq('an old photo has no list', (public.deck_photo_list(:PH3)->>'status'), 'none');
select pg_temp.eq('anyone who sees it can have it read', (public.deck_photo_read_start(:PH3)->>'status'), 'queued');

-- The sweep --------------------------------------------------------------------------------------------------------
select pg_temp.age(:PH3, interval '1 minute');
select pg_temp.sweep();
select pg_temp.eq('an unclaimed read is sent again', pg_temp.row(:PH3), 'queued:2:0');
select pg_temp.sweep(); select pg_temp.sweep();
select pg_temp.eq('after three tries it fails', pg_temp.row(:PH3), 'failed:3:0');
select pg_temp.eq('and says so', (public.deck_photo_list(:PH3)->>'message'), 'The photo couldn''t be read just now. Try again.');
select pg_temp.eq('a failed first read can be asked again by anyone who sees the photo', (public.deck_photo_read_start(:PH3)->>'status'), 'queued');
select pg_temp.svc($$select public.deck_photo_read_claim('d0000000-0000-0000-0000-0000000063d3')$$) is not null;
select pg_temp.age(:PH3, interval '5 minutes');
select pg_temp.sweep();
select pg_temp.eq('a read that ran too long is failed', pg_temp.row(:PH3), 'failed:1:1');

-- Removing the photo removes its list.
select pg_temp.as_user(:A);
select public.deck_photo_delete(:PH2) is not null;
select pg_temp.eq('the list goes with the photo', coalesce(pg_temp.row(:PH2), 'gone'), 'gone');
