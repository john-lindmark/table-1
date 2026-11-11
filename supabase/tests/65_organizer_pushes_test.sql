-- The organizer hears when someone signs up or drops (20261029200000_organizer_sign_up_pushes,
-- contract/scheduled-events-2026-10-27.md § Organizer pushes).
\ir _helpers.sql

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000006a1', 'ana@example.com'),
  ('00000000-0000-0000-0000-0000000006b1', 'bea@example.com'),
  ('00000000-0000-0000-0000-0000000006c1', 'cal@example.com'),
  ('00000000-0000-0000-0000-0000000006d1', 'dee@example.com'),
  ('00000000-0000-0000-0000-0000000006e1', 'eli@example.com');
update public.profiles set display_name = initcap(split_part(u.email, '@', 1))
  from auth.users u where u.id = profiles.id and u.email like '%@example.com';
\set A '''00000000-0000-0000-0000-0000000006a1'''
\set B '''00000000-0000-0000-0000-0000000006b1'''
\set C '''00000000-0000-0000-0000-0000000006c1'''
\set D '''00000000-0000-0000-0000-0000000006d1'''
\set E '''00000000-0000-0000-0000-0000000006e1'''

-- The pushes queued for an event, oldest first: "kind:name[:w]>recipients".
create or replace function pg_temp.pushes(p_event uuid) returns text language sql security definer as $$
  select coalesce(string_agg(replace(m.msg->>'kind', 'event.', '') || ':' || (m.msg->'data'->>'name')
                    || case when (m.msg->'data'->>'waitlist')::boolean then ':w' else '' end
                    || '>' || (select string_agg(left(u, 1) || substr(u, 35, 1), ',' order by u)
                                 from jsonb_array_elements_text(m.msg->'user_ids') u), ' ' order by m.msg_id), '-')
    from pgmq.messages m
   where m.msg->>'event_id' = p_event::text and m.msg->>'kind' in ('event.signed_up', 'event.dropped')
$$;
grant execute on function pg_temp.pushes(uuid) to anon, authenticated;

set role authenticated;
select pg_temp.as_user(:A);
select (public.create_event_v2(p_format_name => 'modern', p_rounds => 3, p_capacity => 3)->>'event_id') as ev \gset
select pg_temp.eq('creating the event (Ana plays) tells nobody', pg_temp.pushes(:'ev'), '-');
select public.add_guest(:'ev', 'Walk-in');
select pg_temp.eq('the organizer adding a guest tells nobody', pg_temp.pushes(:'ev'), '-');

select pg_temp.as_user(:B);
select pg_temp.eq('Bea signs up', public.event_sign_up(:'ev')->>'status', 'joined');
select pg_temp.eq('Ana hears it', pg_temp.pushes(:'ev'), 'signed_up:Bea>0a');
select pg_temp.eq('a second tap is no news', public.event_sign_up(:'ev')->>'status', 'already_joined');
select pg_temp.eq('still one push', pg_temp.pushes(:'ev'), 'signed_up:Bea>0a');

select pg_temp.as_user(:C);
select pg_temp.eq('Cal goes on the waitlist', public.event_sign_up(:'ev')->>'status', 'waitlisted');
reset role;
select short_code as ev_code from public.events where id = :'ev' \gset
set role authenticated;
select pg_temp.as_user(:D);
select pg_temp.eq('Dee too, by join code', (select x->>'waitlisted' from public.join_event(:'ev_code', 'Dee') x), 'true');
select pg_temp.as_user(:C);
select pg_temp.eq('Cal leaves the waitlist', public.event_leave(:'ev')->>'status', 'left_waitlist');
select pg_temp.as_user(:B);
select pg_temp.eq('Bea drops', public.event_leave(:'ev')->>'status', 'left');
select pg_temp.as_user(:D);
select pg_temp.eq('Dee moved up', (select count(*) from public.participants where event_id = :'ev' and user_id = :D)::text, '1');
select pg_temp.eq('waitlist and drops reach Ana; moving up behind Bea is not Dee''s own sign-up', pg_temp.pushes(:'ev'),
  'signed_up:Bea>0a signed_up:Cal:w>0a signed_up:Dee:w>0a dropped:Cal:w>0a dropped:Bea>0a');

-- A co-organizer hears it too; an organizer's own sign-up or the organizer removing someone is no news.
reset role;
insert into public.event_members (event_id, user_id, role) values (:'ev', :E, 'organizer');
set role authenticated;
select pg_temp.as_user(:A);
select public.waitlist_remove(:'ev', :D);
select (public.add_guest(:'ev', 'Second')->>'participant_id') as guest2 \gset
select pg_temp.as_user(:E);
select pg_temp.eq('Eli (an organizer) signs up: the event is full', public.event_sign_up(:'ev')->>'status', 'waitlisted');
select pg_temp.eq('Eli leaves the waitlist', public.event_leave(:'ev')->>'status', 'left_waitlist');
select pg_temp.eq('nobody is told about organizers', pg_temp.pushes(:'ev'),
  'signed_up:Bea>0a signed_up:Cal:w>0a signed_up:Dee:w>0a dropped:Cal:w>0a dropped:Bea>0a');

-- Signed out by join code, as a guest.
select pg_temp.as_user(:A);
select (public.create_event_v2(p_format_name => 'pioneer', p_rounds => 3)->>'event_id') as open_ev \gset
reset role;
insert into public.event_members (event_id, user_id, role) values (:'open_ev', :E, 'organizer');
select short_code as open_code from public.events where id = :'open_ev' \gset
set role anon;
select pg_temp.as_user(null);
select pg_temp.eq('a guest joins by code', (select (x->>'participant_id' is not null)::text
  from public.join_event(:'open_code', ' Sam ') x), 'true');
select pg_temp.eq('both organizers hear it', pg_temp.pushes(:'open_ev'), 'signed_up:Sam>0a,0e');

-- Demo events stay quiet.
reset role;
update public.events set is_demo = true where id = :'open_ev';
set role authenticated;
select pg_temp.as_user(:C);
select public.join_event(:'open_code', 'Cal');
select pg_temp.as_user(null);
reset role;
select pg_temp.eq('demo events tell nobody', pg_temp.pushes(:'open_ev'), 'signed_up:Sam>0a,0e');
