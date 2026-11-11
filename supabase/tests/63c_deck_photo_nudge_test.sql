-- "Add your deck photo" push (20261111190000_deck_photo_nudge, contract/event-night-2026-10-16.md § 7 "Once your
-- last match is in"): the apps' rule on the shared cases, then events played through the tables: queued when the
-- last match is in or the event is finished, sent when due unless a photo is up, asked again at send, once each.
\ir _helpers.sql

-- ---------------------------------------------------------------- the shared cases
\set cases `cat ../../testdata/deck-photos/prompt.json`
select pg_temp.eq('case: ' || (c->>'name'),
  coalesce(t1_private.deck_photo_why_of(c->'event', c->'me', c->'rounds'), '-'), coalesce(c->>'why', '-'))
  from jsonb_array_elements((:'cases'::jsonb)->'cases') c;
select pg_temp.eq('all the shared cases ran', jsonb_array_length((:'cases'::jsonb)->'cases')::text, '21');

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000063a1', 'org@example.com'),
  ('00000000-0000-0000-0000-0000000063b1', 'bea@example.com'),
  ('00000000-0000-0000-0000-0000000063c1', 'cal@example.com'),
  ('00000000-0000-0000-0000-0000000063d1', 'dee@example.com');
\set A '''00000000-0000-0000-0000-0000000063a1'''
\set B '''00000000-0000-0000-0000-0000000063b1'''
\set C '''00000000-0000-0000-0000-0000000063c1'''
\set D '''00000000-0000-0000-0000-0000000063d1'''

-- The deck photo pushes queued for an event: "why>players" in order, players by their email's first letter.
create or replace function pg_temp.pushes(p_event uuid) returns text language sql security definer as $$
  select coalesce(string_agg((m.msg->'data'->>'why') || '>' ||
           (select string_agg(left(u.email, 1), ',' order by u.email) from jsonb_array_elements_text(m.msg->'user_ids') x
              join auth.users u on u.id = x::uuid), ' ' order by m.msg_id), '-')
    from pgmq.messages m
   where m.msg->>'event_id' = p_event::text and m.msg->>'kind' = 'event.deck_photo'
$$;
-- Who is queued (not yet sent), by first letter.
create or replace function pg_temp.queued(p_event uuid) returns text language sql security definer as $$
  select coalesce(string_agg(left(u.email, 1) || ':' || n.why, ',' order by u.email), '-')
    from t1_private.deck_photo_nudges n join auth.users u on u.id = n.user_id
   where n.event_id = p_event and n.sent_at is null
$$;
create or replace function pg_temp.due(p_event uuid) returns void language sql security definer as $$
  update t1_private.deck_photo_nudges set due_at = now() - interval '1 second' where event_id = p_event and sent_at is null
$$;
-- A round with matches: each match "participant,participant|null,status,games,games".
create or replace function pg_temp.round(p_event uuid, p_number int, p_stage text, p_matches text[]) returns void
language plpgsql security definer as $$
declare r uuid := gen_random_uuid(); m uuid; x text[]; i int := 0;
begin
  insert into public.rounds (id, event_id, number, status, stage) values (r, p_event, p_number, 'active', p_stage);
  foreach x slice 1 in array p_matches loop
    i := i + 1; m := gen_random_uuid();
    insert into public.matches (id, event_id, round_id, table_number, is_bye, status)
    values (m, p_event, r, i, x[2] is null, x[3]);
    insert into public.match_sides (match_id, participant_id, side, game_wins)
    select m, x[1]::uuid, 0, x[4]::int
    union all select m, x[2]::uuid, 1, x[5]::int where x[2] is not null;
  end loop;
end $$;
create or replace function pg_temp.result(p_event uuid, p_number int, p_participant uuid, p_my int, p_their int, p_status text)
returns void language plpgsql security definer as $$
declare v_match uuid;
begin
  select m.id into v_match from public.matches m join public.rounds r on r.id = m.round_id
    join public.match_sides s on s.match_id = m.id
   where r.event_id = p_event and r.number = p_number and s.participant_id = p_participant;
  update public.match_sides set game_wins = case when participant_id = p_participant then p_my else p_their end where match_id = v_match;
  update public.matches set status = p_status where id = v_match;
end $$;

-- ---------------------------------------------------------------- two rounds, no top cut
\set EV '''e0000000-0000-0000-0000-0000000063c1'''
\set PB '''f3000000-0000-0000-0000-0000000000b1'''
\set PC '''f3000000-0000-0000-0000-0000000000c1'''
\set PD '''f3000000-0000-0000-0000-0000000000d1'''
\set PG '''f3000000-0000-0000-0000-0000000000f1'''
insert into public.events (id, short_code, name, created_by, status, number_of_rounds, current_round) values
  (:EV, 'NUDG63', 'Photo night', :A, 'in_progress', 2, 1);
insert into public.event_members (event_id, user_id, role) values (:EV, :A, 'owner');
insert into public.participants (id, event_id, user_id, display_name, seat) values
  (:PB, :EV, :B, 'Bea', 1), (:PC, :EV, :C, 'Cal', 2), (:PD, :EV, :D, 'Dee', 3), (:PG, :EV, null, 'Gus', 4);

select pg_temp.round(:EV, 1, 'swiss', array[[:PB, :PC, 'pending', '0', '0'], [:PD, :PG, 'pending', '0', '0']]);
select pg_temp.result(:EV, 1, :PB, 2, 0, 'confirmed');
select pg_temp.result(:EV, 1, :PD, 2, 1, 'reported');
select pg_temp.eq('round 1 of 2 in: nobody queued', pg_temp.queued(:EV), '-');

-- Cal already has his photo up; Gus is a guest.
insert into public.event_deck_photos (id, event_id, participant_id, uploaded_by, path)
values (gen_random_uuid(), :EV, :PC, :C, 'e0000000-0000-0000-0000-0000000063c1/cal.jpg');
select pg_temp.round(:EV, 2, 'swiss', array[[:PB, :PD, 'pending', '0', '0'], [:PC, :PG, 'pending', '0', '0']]);
select pg_temp.eq('round 2 paired: nobody queued', pg_temp.queued(:EV), '-');
begin;
select pg_temp.result(:EV, 2, :PB, 1, 2, 'reported');
commit;
select pg_temp.eq('the last result reported: both players queued', pg_temp.queued(:EV), 'b:last,d:last');
select pg_temp.eq('due in about ten minutes',
  (select bool_and(due_at between now() + interval '9 minutes' and now() + interval '11 minutes')
     from t1_private.deck_photo_nudges where event_id = :EV)::text, 'true');
select pg_temp.result(:EV, 2, :PC, 2, 0, 'confirmed');
select pg_temp.eq('Cal (photo up) and Gus (guest) are never queued', pg_temp.queued(:EV), 'b:last,d:last');
select pg_temp.eq('nothing sent before it is due', (t1_private.deck_photo_nudge_send())::text, '0');
select pg_temp.result(:EV, 2, :PB, 1, 2, 'confirmed');
select pg_temp.eq('confirming the same result queues nothing more', pg_temp.queued(:EV), 'b:last,d:last');

-- Dee adds her photo in the meantime.
insert into public.event_deck_photos (id, event_id, participant_id, uploaded_by, path)
values (gen_random_uuid(), :EV, :PD, :D, 'e0000000-0000-0000-0000-0000000063c1/dee.jpg');
select pg_temp.due(:EV);
select pg_temp.eq('one push sent when due', (t1_private.deck_photo_nudge_send())::text, '1');
select pg_temp.eq('Bea gets it; Dee added hers', pg_temp.pushes(:EV), 'last>b');
select pg_temp.eq('Dee''s row is kept as found', (select outcome from t1_private.deck_photo_nudges where participant_id = :PD), 'photo');
select pg_temp.eq('the push names the event', (select m.msg->'data'->>'event_name' from pgmq.messages m
  where m.msg->>'event_id' = :EV and m.msg->>'kind' = 'event.deck_photo'), 'Photo night');

update public.events set status = 'completed' where id = :EV;
select pg_temp.eq('finishing the event queues nobody new (all sent, photo up or guest)', pg_temp.queued(:EV), '-');
select pg_temp.due(:EV);
select pg_temp.eq('and sends nothing again', (t1_private.deck_photo_nudge_send())::text, '0');
select pg_temp.eq('still one push', pg_temp.pushes(:EV), 'last>b');

-- ---------------------------------------------------------------- top 8
\set EV2 '''e0000000-0000-0000-0000-0000000063c2'''
\set QB '''f3000000-0000-0000-0000-0000000000b2'''
\set QC '''f3000000-0000-0000-0000-0000000000c2'''
\set QD '''f3000000-0000-0000-0000-0000000000d2'''
\set QG '''f3000000-0000-0000-0000-0000000000f2'''
insert into public.events (id, short_code, name, created_by, status, number_of_rounds, current_round, top_cut) values
  (:EV2, 'NUDG64', 'Cut night', :A, 'in_progress', 1, 1, 8);
insert into public.participants (id, event_id, user_id, display_name, seat) values
  (:QB, :EV2, :B, 'Bea', 1), (:QC, :EV2, :C, 'Cal', 2), (:QD, :EV2, :D, 'Dee', 3), (:QG, :EV2, null, 'Gus', 4);
select pg_temp.round(:EV2, 1, 'swiss', array[[:QB, :QC, 'pending', '0', '0'], [:QD, :QG, 'pending', '0', '0']]);
select pg_temp.result(:EV2, 1, :QB, 2, 0, 'confirmed');
select pg_temp.result(:EV2, 1, :QD, 2, 0, 'confirmed');
select pg_temp.eq('last Swiss round in with a top cut: nobody queued yet', pg_temp.queued(:EV2), '-');
select pg_temp.round(:EV2, 2, 'semifinal', array[[:QB, :QD, 'pending', '0', '0']]);
select pg_temp.eq('the playoffs paired without Cal: Cal queued', pg_temp.queued(:EV2), 'c:last');
begin;
select pg_temp.result(:EV2, 2, :QB, 2, 1, 'reported');
commit;
select pg_temp.eq('Dee lost the semifinal: Dee queued, Bea plays on', pg_temp.queued(:EV2), 'c:last,d:last');

-- A result undone before the push is due sends nothing and leaves the player free to be queued again.
update public.matches set status = 'pending'
 where round_id = (select id from public.rounds where event_id = :EV2 and number = 2);
select pg_temp.due(:EV2);
select pg_temp.eq('only Cal is still done', (t1_private.deck_photo_nudge_send())::text, '1');
select pg_temp.eq('Cal''s push', pg_temp.pushes(:EV2), 'last>c');
select pg_temp.eq('Dee''s row went', (select count(*) from t1_private.deck_photo_nudges where participant_id = :QD)::text, '0');
select pg_temp.round(:EV2, 3, 'final', array[[:QB, :QD, 'pending', '0', '0']]);
begin;
select pg_temp.result(:EV2, 3, :QB, 2, 0, 'confirmed');
commit;
select pg_temp.eq('the final in: both finalists queued, winner too', pg_temp.queued(:EV2), 'b:last,d:last');

-- ---------------------------------------------------------------- finished, cancelled, demo, dropped
\set EV3 '''e0000000-0000-0000-0000-0000000063c3'''
\set RB '''f3000000-0000-0000-0000-0000000000b3'''
\set RC '''f3000000-0000-0000-0000-0000000000c3'''
\set RD '''f3000000-0000-0000-0000-0000000000d3'''
insert into public.events (id, short_code, name, created_by, status, number_of_rounds, current_round) values
  (:EV3, 'NUDG65', 'Early end', :A, 'in_progress', 3, 1);
insert into public.participants (id, event_id, user_id, display_name, seat, status, dropped_in_round) values
  (:RB, :EV3, :B, 'Bea', 1, 'active', null), (:RC, :EV3, :C, 'Cal', 2, 'active', null), (:RD, :EV3, :D, 'Dee', 3, 'dropped', 1);
select pg_temp.round(:EV3, 1, 'swiss', array[[:RB, :RC, 'confirmed', '2', '0'], [:RD, null, 'confirmed', '2', '0']]);
select pg_temp.eq('round 1 of 3 and a drop: nobody queued', pg_temp.queued(:EV3), '-');
update public.events set status = 'completed' where id = :EV3;
select pg_temp.eq('the organizer finishes early: everyone queued as over, the dropped player too',
  pg_temp.queued(:EV3), 'b:over,c:over,d:over');
set t1.cancel = 'on';
update public.events set status = 'cancelled' where id = :EV3;
reset t1.cancel;
select pg_temp.due(:EV3);
select pg_temp.eq('cancelled before it was due: nothing sent', (t1_private.deck_photo_nudge_send())::text, '0');
select pg_temp.eq('and the rows went', (select count(*) from t1_private.deck_photo_nudges where event_id = :EV3)::text, '0');

\set EV4 '''e0000000-0000-0000-0000-0000000063c4'''
\set SB '''f3000000-0000-0000-0000-0000000000b4'''
insert into public.events (id, short_code, name, created_by, status, number_of_rounds, current_round, is_demo) values
  (:EV4, 'NUDG66', 'Demo night', :A, 'in_progress', 1, 1, true);
insert into public.participants (id, event_id, user_id, display_name, seat) values (:SB, :EV4, :B, 'Bea', 1);
select pg_temp.round(:EV4, 1, 'swiss', array[[:SB, null, 'confirmed', '2', '0']]);
update public.events set status = 'completed' where id = :EV4;
select pg_temp.eq('demo events never queue', pg_temp.queued(:EV4), '-');

-- ---------------------------------------------------------------- closed to clients
set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.throws('clients can''t send', 'select t1_private.deck_photo_nudge_send()', '42501');
select pg_temp.throws('clients can''t read the queue', 'select * from t1_private.deck_photo_nudges', '42501');
reset role;
