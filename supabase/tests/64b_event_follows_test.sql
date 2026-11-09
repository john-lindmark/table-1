-- Following events you're not in (20261109220000_event_follows.sql; contract/event-follows-2026-11-09.md): who can
-- follow, the Following list, the round / finished / cancelled pushes to followers, and refusals.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000064a1', 'org@example.com', '{"full_name": "Ana Org"}'),
  ('00000000-0000-0000-0000-0000000064b1', 'bea@example.com', '{"full_name": "Bea Player"}'),
  ('00000000-0000-0000-0000-0000000064c1', 'cal@example.com', '{"full_name": "Cal Fan"}'),
  ('00000000-0000-0000-0000-0000000064d1', 'dee@example.com', '{"full_name": "Dee Fan"}'),
  ('00000000-0000-0000-0000-0000000064e1', 'eve@example.com', '{"full_name": "Eve Blocked"}');
\set A '''00000000-0000-0000-0000-0000000064a1'''
\set B '''00000000-0000-0000-0000-0000000064b1'''
\set C '''00000000-0000-0000-0000-0000000064c1'''
\set D '''00000000-0000-0000-0000-0000000064d1'''
\set E '''00000000-0000-0000-0000-0000000064e1'''
\set EV '''e0000000-0000-0000-0000-0000000064e1'''
\set EP '''e0000000-0000-0000-0000-0000000064e2'''
\set ED '''e0000000-0000-0000-0000-0000000064e3'''
\set EO '''e0000000-0000-0000-0000-0000000064e4'''

-- Ana runs a link event Bea plays in, a private one, a demo one, and an older finished one.
insert into public.events (id, short_code, name, created_by, status, current_round, number_of_rounds, visibility, is_demo, starts_at) values
  (:EV, 'FOLLOW', 'Friday Modern', :A, 'setup', 0, 3, 'link_only', false, now() + interval '1 day'),
  (:EP, 'FOLPRV', 'Private night', :A, 'setup', 0, 3, 'private', false, null),
  (:ED, 'FOLDEM', 'Demo night', :A, 'setup', 0, 3, 'link_only', true, null),
  (:EO, 'FOLOLD', 'Old draft', :A, 'completed', 3, 3, 'link_only', false, null);
insert into public.event_members (event_id, user_id, role) values (:EV, :A, 'owner'), (:EP, :A, 'owner'), (:ED, :A, 'owner'), (:EO, :A, 'owner');
insert into public.participants (event_id, user_id, display_name, seat) values (:EV, :B, 'Bea Player', 1);
insert into public.user_blocks (user_id, blocked_id) values (:A, :E);

create or replace function pg_temp.pushes(p_kind text) returns text language sql security definer as $$
  select coalesce(string_agg(x, ',' order by x), '-') from (
    select (select string_agg(right(u, 2), '+' order by u) from jsonb_array_elements_text(m.msg->'user_ids') u) x
      from pgmq.messages m where m.msg->>'kind' = p_kind) s $$;
grant execute on function pg_temp.pushes(text) to anon, authenticated;

-- ==================================================================== follow
select pg_temp.as_user(:C);
select pg_temp.eq('before: not following, can follow', public.event_follow_get(:EV)::text,
  '{"notify": false, "following": false, "can_follow": true}');
select pg_temp.eq('follow', public.event_follow_set(:EV, true)::text, '{"notify": true, "following": true}');
select pg_temp.eq('following again changes nothing', public.event_follow_set(:EV, true)::text, '{"notify": true, "following": true}');
select pg_temp.eq('audited once', (select count(*)::text from public.account_audit where actor = :C and action = 'event.followed'), '1');
select pg_temp.eq('notifications off', public.event_follow_set(:EV, true, false)::text, '{"notify": false, "following": true}');
select pg_temp.eq('get reads it', public.event_follow_get(:EV)->>'notify', 'false');
select public.event_follow_set(:EV, true, true);
select pg_temp.eq('listed under Following', (select string_agg(x->>'name', ',') from jsonb_array_elements(public.events_followed()) x), 'Friday Modern');
select pg_temp.throws('a private event can''t be followed', format('select public.event_follow_set(%L, true)', :EP), '42501');
select pg_temp.throws('a demo event can''t be followed', format('select public.event_follow_set(%L, true)', :ED), '42501');
select pg_temp.throws('a finished event can''t be newly followed', format('select public.event_follow_set(%L, true)', :EO), '22023');
select pg_temp.throws('an unknown event', 'select public.event_follow_set(''e0000000-0000-0000-0000-0000000064ff'', true)', '42501');

select pg_temp.as_user(:B);
select pg_temp.throws('a player follows nothing', format('select public.event_follow_set(%L, true)', :EV), '22023');
select pg_temp.eq('a player can''t follow', public.event_follow_get(:EV)->>'can_follow', 'false');
select pg_temp.as_user(:A);
select pg_temp.throws('the organizer follows nothing', format('select public.event_follow_set(%L, true)', :EV), '22023');
select pg_temp.as_user(:E);
select pg_temp.throws('someone the organizer blocked can''t', format('select public.event_follow_set(%L, true)', :EV), '42501');
select pg_temp.as_user(:D);
select public.event_follow_set(:EV, true);
select pg_temp.as_user(null);
select pg_temp.throws('signed out', format('select public.event_follow_set(%L, true)', :EV), '28000');
select pg_temp.eq('anon can''t call it', has_function_privilege('anon', 'public.event_follow_set(uuid, boolean, boolean)', 'execute')::text, 'false');
select pg_temp.eq('nobody reads the table', has_table_privilege('authenticated', 'public.event_follows', 'select')::text, 'false');

-- ==================================================================== pushes
-- Dee turns hers off; Cal hears each round and the finish.
select pg_temp.as_user(:D);
select public.event_follow_set(:EV, true, false);
select pg_temp.as_user(null);
update public.events set status = 'in_progress', current_round = 1 where id = :EV;
insert into public.rounds (event_id, number, status) values (:EV, 1, 'active');
select pg_temp.eq('round 1 reaches Cal only', pg_temp.pushes('event.follow_round'), 'c1');
select pg_temp.eq('with the round', (select m.msg->'data'->>'round' from pgmq.messages m where m.msg->>'kind' = 'event.follow_round'), '1');
-- Cal joins the event (a late guest seat on his account): he stops hearing as a follower.
insert into public.participants (event_id, user_id, display_name, seat) values (:EV, :C, 'Cal Fan', 2);
insert into public.rounds (event_id, number, status) values (:EV, 2, 'active');
select pg_temp.eq('a follower who joined hears nothing as a follower', pg_temp.pushes('event.follow_round'), 'c1');
delete from public.participants where event_id = :EV and user_id = :C;
update public.events set status = 'completed' where id = :EV;
select pg_temp.eq('finished reaches Cal', pg_temp.pushes('event.follow_done'), 'c1');
select pg_temp.as_user(:C);
select pg_temp.eq('a finished event stays on the list', (select count(*)::text from jsonb_array_elements(public.events_followed())), '1');
select pg_temp.eq('and can still be unfollowed', public.event_follow_set(:EV, false)::text, '{"notify": false, "following": false}');
select pg_temp.eq('gone from the list', public.events_followed()::text, '[]');
select pg_temp.eq('unfollow audited with the event', (select count(*)::text from public.account_audit
  where actor = :C and action = 'event.unfollowed' and target_id = :EV), '1');

-- Cancelled: the followers who kept notifications on hear it.
select pg_temp.as_user(:C);
select public.event_follow_set(:EP, false);
select pg_temp.as_user(null);
update public.events set visibility = 'link_only' where id = :EP;
select pg_temp.as_user(:C);
select public.event_follow_set(:EP, true);
select pg_temp.as_user(:A);
select public.cancel_event(:EP, 'Store closed');
select pg_temp.eq('cancelled reaches the follower', (select string_agg(right(u, 2), '+') from pgmq.messages m,
  jsonb_array_elements_text(m.msg->'user_ids') u where m.msg->>'kind' = 'event.cancelled' and m.msg->>'event_id' = :EP), 'c1');
select pg_temp.as_user(:C);
select pg_temp.eq('a cancelled event leaves the list', public.events_followed()::text, '[]');

-- A demo event's rounds tell nobody.
select pg_temp.as_user(null);
insert into public.event_follows (user_id, event_id) values (:C, :ED);
insert into public.rounds (event_id, number, status) values (:ED, 1, 'active');
select pg_temp.eq('demo rounds tell nobody', (select count(*)::text from pgmq.messages m
  where m.msg->>'kind' = 'event.follow_round' and m.msg->>'event_id' = :ED), '0');
