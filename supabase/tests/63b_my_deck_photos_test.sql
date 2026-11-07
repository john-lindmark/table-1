-- Your deck photos on your account (20261106170000_my_deck_photos): every photo of a deck you played, across events,
-- newest event first, whoever took it; never someone else's deck, a guest's, a photo moderation hid from you, or a
-- demo event for a non-tester.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'org@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'bea@example.com'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com'),
  ('00000000-0000-0000-0000-0000000000d1', 'tess@example.com');
\set A '''00000000-0000-0000-0000-0000000000a1'''
\set B '''00000000-0000-0000-0000-0000000000b1'''
\set C '''00000000-0000-0000-0000-0000000000c1'''
\set T '''00000000-0000-0000-0000-0000000000d1'''
\set E1 '''e0000000-0000-0000-0000-0000000063b1'''
\set E2 '''e0000000-0000-0000-0000-0000000063b2'''
\set ED '''e0000000-0000-0000-0000-0000000063bd'''

-- Two of Alice's events Bea played (an older one, done, and a newer one, running), plus a demo event.
insert into public.events (id, short_code, name, created_by, status, current_round, created_at, starts_at, is_demo) values
  (:E1, 'MDP631', 'Old draft', :A, 'completed', 3, now() - interval '20 days', null, false),
  (:E2, 'MDP632', 'New sealed', :A, 'in_progress', 1, now() - interval '30 days', now() - interval '1 day', false),
  (:ED, 'MDP63D', 'Demo night', :A, 'completed', 3, now(), null, true);
insert into public.event_members (event_id, user_id, role) values (:E1, :A, 'owner'), (:E2, :A, 'owner'), (:ED, :A, 'owner');
insert into public.participants (id, event_id, user_id, display_name, seat) values
  ('f6300000-0000-0000-0000-0000000000b1', :E1, :B, 'Bea', 1),
  ('f6300000-0000-0000-0000-0000000000c1', :E1, :C, 'Cal', 2),
  ('f6300000-0000-0000-0000-0000000000f1', :E1, null, 'Gus', 3),
  ('f6300000-0000-0000-0000-0000000000b2', :E2, :B, 'Bea', 1),
  ('f6300000-0000-0000-0000-0000000000bd', :ED, :B, 'Bea', 1),
  ('f6300000-0000-0000-0000-0000000000dd', :ED, :T, 'Tess', 2);

-- Photos are written straight in (deck_photo_add is pinned in 63_deck_photos_test.sql).
insert into public.event_deck_photos (id, event_id, participant_id, uploaded_by, path, note, created_at, turns, hidden_at) values
  -- Old draft: Bea's own, one Alice took of Bea's deck, one of Cal's, one of Gus's, and one hidden that Alice took.
  ('d6300000-0000-0000-0000-000000000001', :E1, 'f6300000-0000-0000-0000-0000000000b1', :B, 'e1/1.jpg', 'Mono red', now() - interval '20 days', 1, null),
  ('d6300000-0000-0000-0000-000000000002', :E1, 'f6300000-0000-0000-0000-0000000000b1', :A, 'e1/2.jpg', '', now() - interval '19 days', 0, null),
  ('d6300000-0000-0000-0000-000000000003', :E1, 'f6300000-0000-0000-0000-0000000000c1', :C, 'e1/3.jpg', '', now() - interval '20 days', 0, null),
  ('d6300000-0000-0000-0000-000000000004', :E1, 'f6300000-0000-0000-0000-0000000000f1', :A, 'e1/4.jpg', '', now() - interval '20 days', 0, null),
  ('d6300000-0000-0000-0000-000000000005', :E1, 'f6300000-0000-0000-0000-0000000000b1', :A, 'e1/5.jpg', '', now() - interval '18 days', 0, now()),
  -- New sealed: Bea's, and one of hers moderation hid that she took herself (she still sees it).
  ('d6300000-0000-0000-0000-000000000006', :E2, 'f6300000-0000-0000-0000-0000000000b2', :B, 'e2/6.jpg', 'Pool', now() - interval '1 day', 0, null),
  ('d6300000-0000-0000-0000-000000000007', :E2, 'f6300000-0000-0000-0000-0000000000b2', :B, 'e2/7.jpg', '', now() - interval '2 days', 0, now()),
  -- Demo night: Bea's and Tess's.
  ('d6300000-0000-0000-0000-000000000008', :ED, 'f6300000-0000-0000-0000-0000000000bd', :B, 'ed/8.jpg', '', now(), 0, null),
  ('d6300000-0000-0000-0000-000000000009', :ED, 'f6300000-0000-0000-0000-0000000000dd', :T, 'ed/9.jpg', '', now(), 0, null);
insert into t1_private.demo_testers (user_id, note) values (:T, 'test');

set role authenticated;

select pg_temp.as_user(:B);
select pg_temp.eq('her photos, newest event first, newest photo first, whoever took them',
  (select string_agg(right(p->>'id', 1), ',' order by n) from jsonb_array_elements(public.my_deck_photos()->'photos') with ordinality t(p, n)),
  '6,7,2,1');
select pg_temp.eq('each carries its event and the photo fields',
  (select (p->>'event_name') || '/' || (p->>'event_status') || '/' || (p->>'note') || '/' || (p->>'turns') || '/' || (p->>'editable')
     from jsonb_array_elements(public.my_deck_photos()->'photos') p where p->>'id' like '%1'),
  'Old draft/completed/Mono red/1/true');
select pg_temp.eq('totals count every photo and event, whatever the limit',
  (select (r->>'total') || '/' || (r->>'events') || '/' || jsonb_array_length(r->'photos') from public.my_deck_photos(1) r), '4/2/1');
select pg_temp.eq('the limit keeps the newest',
  (select string_agg(right(p->>'id', 1), ',') from jsonb_array_elements(public.my_deck_photos(1)->'photos') p), '6');
select pg_temp.eq('the newest event comes first by its start, not when it was made',
  (public.my_deck_photos()->'photos'->0->>'event_name'), 'New sealed');

select pg_temp.as_user(:C);
select pg_temp.eq('another player sees only their own deck',
  (select string_agg(right(p->>'id', 1), ',') from jsonb_array_elements(public.my_deck_photos()->'photos') p), '3');

select pg_temp.as_user(:A);
select pg_temp.eq('the organizer, who played nothing, has none (guests and players decks are theirs)',
  jsonb_array_length(public.my_deck_photos()->'photos')::text, '0');

select pg_temp.as_user(:T);
select pg_temp.eq('a demo tester sees their demo event',
  (select string_agg(right(p->>'id', 1), ',') from jsonb_array_elements(public.my_deck_photos()->'photos') p), '9');

-- The actions on the screen work on these rows (the player may act on their own deck's photo, whoever took it).
select pg_temp.as_user(:B);
select pg_temp.eq('she turns a photo someone else took of her deck',
  (select p->>'turns' from jsonb_array_elements(public.deck_photo_turn('d6300000-0000-0000-0000-000000000002', 2)->'photos') p
    where p->>'id' = 'd6300000-0000-0000-0000-000000000002'), '2');
select pg_temp.eq('and the account list shows it turned',
  (select p->>'turns' from jsonb_array_elements(public.my_deck_photos()->'photos') p
    where p->>'id' = 'd6300000-0000-0000-0000-000000000002'), '2');

select pg_temp.as_user(null);
select pg_temp.throws('signed out is refused', $$select public.my_deck_photos()$$, '28000');
reset role;
set role anon;
select pg_temp.throws('anon cannot call it', $$select public.my_deck_photos()$$, '42501');
reset role;
