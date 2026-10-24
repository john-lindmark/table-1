-- Deck photos (20261016260000_redraft_deck_photos, moderation's hidden_at): a seated player who isn't the organizer
-- uploads and records their own deck, the organizer adds for a guest, and nobody else gets in. Players on web and
-- Android never added one before 2026-10-23 (no screen there), so this pins the server side they now use.
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'org@example.com'),
  ('00000000-0000-0000-0000-0000000000b1', 'bea@example.com'),
  ('00000000-0000-0000-0000-0000000000c1', 'cal@example.com'),
  ('00000000-0000-0000-0000-0000000000d1', 'dee@example.com');
\set A '''00000000-0000-0000-0000-0000000000a1'''
\set B '''00000000-0000-0000-0000-0000000000b1'''
\set C '''00000000-0000-0000-0000-0000000000c1'''
\set D '''00000000-0000-0000-0000-0000000000d1'''
\set EV '''e0000000-0000-0000-0000-000000000063'''
\set PB '''f2000000-0000-0000-0000-00000000000b'''
\set PC '''f2000000-0000-0000-0000-00000000000c'''
\set PG '''f2000000-0000-0000-0000-00000000000f'''
\set PH1 '''d0000000-0000-0000-0000-000000000001'''
\set PH2 '''d0000000-0000-0000-0000-000000000002'''
\set PH3 '''d0000000-0000-0000-0000-000000000003'''

-- Alice runs (doesn't play) an event: Bea and Cal have accounts, Gus is a walk-in guest. Dee isn't in it.
insert into public.events (id, short_code, name, created_by, status, current_round) values
  (:EV, 'PHOT63', 'Photo night', :A, 'in_progress', 1);
insert into public.event_members (event_id, user_id, role) values (:EV, :A, 'owner');
insert into public.participants (id, event_id, user_id, display_name, seat) values
  (:PB, :EV, :B, 'Bea', 1), (:PC, :EV, :C, 'Cal', 2), (:PG, :EV, null, 'Gus', 3);
grant usage on schema storage to authenticated;
grant select, insert, update, delete on storage.objects to authenticated;

set role authenticated;

-- Bea, a player, uploads under the event and records it for herself.
select pg_temp.as_user(:B);
insert into storage.objects (bucket_id, name, owner_id)
values ('deck-photos', 'e0000000-0000-0000-0000-000000000063/d0000000-0000-0000-0000-000000000001.jpg', :B);
select pg_temp.eq('a player records their own deck photo',
  (public.deck_photo_add(:PH1, :EV, :PB, 'Mono red')->'photos'->0->>'note'), 'Mono red');
select pg_temp.eq('retrying the same photo is idempotent',
  jsonb_array_length(public.deck_photo_add(:PH1, :EV, :PB, 'Mono red')->'photos')::text, '1');
select pg_temp.eq('her photo is hers and editable',
  (select (p->>'mine') || '/' || (p->>'editable') from jsonb_array_elements(public.deck_photos(:EV)->'photos') p), 'true/true');
select pg_temp.eq('a player edits their note',
  (public.deck_photo_note(:PH1, 'Mono red, 17 lands')->'photos'->0->>'note'), 'Mono red, 17 lands');
select pg_temp.throws('a player cannot record a photo for someone else',
  $$select public.deck_photo_add('d0000000-0000-0000-0000-000000000009', 'e0000000-0000-0000-0000-000000000063',
    'f2000000-0000-0000-0000-00000000000c', '')$$, '42501');

-- Cal, another player, doesn't see Bea's photo while the event runs.
select pg_temp.as_user(:C);
select pg_temp.eq('another player sees none of hers mid-event',
  jsonb_array_length(public.deck_photos(:EV)->'photos')::text, '0');
select pg_temp.throws('another player cannot edit her note',
  $$select public.deck_photo_note('d0000000-0000-0000-0000-000000000001', 'mine now')$$, '42501');

-- Dee isn't in the event: no upload, no list.
select pg_temp.as_user(:D);
select pg_temp.throws('someone outside the event cannot upload',
  $$insert into storage.objects (bucket_id, name, owner_id) values ('deck-photos',
    'e0000000-0000-0000-0000-000000000063/d0000000-0000-0000-0000-000000000003.jpg', '00000000-0000-0000-0000-0000000000d1')$$);
select pg_temp.throws('someone outside the event cannot list photos',
  $$select public.deck_photos('e0000000-0000-0000-0000-000000000063')$$, '42501');

-- Alice adds one for Gus, the guest, and sees both.
select pg_temp.as_user(:A);
insert into storage.objects (bucket_id, name, owner_id)
values ('deck-photos', 'e0000000-0000-0000-0000-000000000063/d0000000-0000-0000-0000-000000000002.jpg', :A);
select pg_temp.eq('the organizer adds a photo for a guest and sees every photo',
  jsonb_array_length(public.deck_photo_add(:PH2, :EV, :PG, '')->'photos')::text, '2');
select pg_temp.throws('recording before uploading is refused',
  $$select public.deck_photo_add('d0000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000063',
    'f2000000-0000-0000-0000-00000000000f', '')$$, '22023');

-- Once the event is over, Cal sees both.
reset role;
update public.events set status = 'completed' where id = :EV;
set role authenticated;
select pg_temp.as_user(:C);
select pg_temp.eq('after the event every player sees every photo',
  jsonb_array_length(public.deck_photos(:EV)->'photos')::text || '/' || (public.deck_photos(:EV)->>'shared'), '2/true');

-- Bea removes hers.
select pg_temp.as_user(:B);
select pg_temp.eq('a player removes their own photo',
  jsonb_array_length(public.deck_photo_delete(:PH1)->'photos')::text, '1');
reset role;
select pg_temp.eq('every change is audited',
  (select string_agg(action, ',' order by action) from public.audit_log where event_id = :EV and action like 'deck_photo.%'),
  'deck_photo.added,deck_photo.added,deck_photo.added,deck_photo.note,deck_photo.removed');
