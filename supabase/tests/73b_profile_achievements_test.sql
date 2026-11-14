-- Achievements on profiles (20261113130000_profile_achievements.sql; contract/public-events-leagues-2026-11-13.md
-- § 7): what counts, who sees them, and that hiding from the boards hides board placements.
\ir _helpers.sql

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000b3a1', 'ana@example.com', '{"full_name": "Ana Org"}'),
  ('00000000-0000-0000-0000-00000000b3b1', 'bea@example.com', '{"full_name": "Bea"}'),
  ('00000000-0000-0000-0000-00000000b3c1', 'cal@example.com', '{"full_name": "Cal"}'),
  ('00000000-0000-0000-0000-00000000b3d1', 'dee@example.com', '{"full_name": "Dee Friend"}'),
  ('00000000-0000-0000-0000-00000000b3e1', 'eve@example.com', '{"full_name": "Eve Stranger"}'),
  ('00000000-0000-0000-0000-00000000b3f1', 'fay@example.com', '{"full_name": "Fay Blocked"}');
\set A '''00000000-0000-0000-0000-00000000b3a1'''
\set B '''00000000-0000-0000-0000-00000000b3b1'''
\set C '''00000000-0000-0000-0000-00000000b3c1'''
\set D '''00000000-0000-0000-0000-00000000b3d1'''
\set E '''00000000-0000-0000-0000-00000000b3e1'''
\set F '''00000000-0000-0000-0000-00000000b3f1'''
\set E1 '''e0000000-0000-0000-0000-00000000b301'''
\set E2 '''e0000000-0000-0000-0000-00000000b302'''
\set L '''10000000-0000-0000-0000-00000000b301'''
\set SE '''20000000-0000-0000-0000-00000000b301'''

insert into public.events (id, short_code, name, created_by, status, current_round, number_of_rounds, visibility, starts_at, format_name, format) values
  (:E1, 'ACHOPN', 'Modern Open', :A, 'completed', 5, 5, 'public', now() - interval '20 days', 'modern', 'constructed'),
  (:E2, 'ACHFIN', 'Championship', :A, 'completed', 5, 5, 'public', now() - interval '2 days', 'modern', 'constructed');
insert into public.participants (id, event_id, user_id, display_name, seat)
select md5('ap' || e.n || u.n)::uuid, e.id, u.id, u.name, u.n
  from (values (:E1::uuid, 1), (:E2::uuid, 2)) e(id, n),
       (values (1, :B::uuid, 'Bea'), (2, :C::uuid, 'Cal'), (3, :D::uuid, 'Dee Friend')) u(n, id, name);
insert into public.leagues (id, slug, name, created_by) values (:L, 'ach-series', 'Ach Series', :A);
insert into public.league_members (league_id, user_id, role) values (:L, :A, 'owner');
insert into public.league_seasons (id, league_id, name, starts_on, ends_on, points, qualify)
values (:SE, :L, '2026', current_date - 300, current_date + 30,
        '{"places": [{"through": 1, "points": 12}, {"through": 2, "points": 10}], "participation": 1, "match_win": 0}',
        '{"winners": true, "pass_down": true, "top": 0}');
insert into public.league_events (event_id, season_id, league_id, final) values (:E1, :SE, :L, false), (:E2, :SE, :L, true);
-- The Open: Cal, Bea, Dee. The final: Bea, Cal, Dee.
insert into public.event_placements (event_id, participant_id, user_id, name, place, match_wins)
select e.id, md5('ap' || e.n || u.n)::uuid, u.id, u.name, u.place, 3 - u.place
  from (values (:E1::uuid, 1, 1, :C::uuid, 2, 'Cal'), (:E1::uuid, 1, 2, :B::uuid, 1, 'Bea'), (:E1::uuid, 1, 3, :D::uuid, 3, 'Dee Friend'),
               (:E2::uuid, 2, 1, :B::uuid, 1, 'Bea'), (:E2::uuid, 2, 2, :C::uuid, 2, 'Cal'), (:E2::uuid, 2, 3, :D::uuid, 3, 'Dee Friend'))
       as x(id, n, place, uid, un, name)
  cross join lateral (select x.id, x.n) e(id, n)
  cross join lateral (select x.uid, x.un, x.name, x.place) u(id, n, name, place);
insert into t1_private.format_ratings (board, user_id, rating, matches, wins, losses, draws, events, last_played_at) values
  ('modern', :B, 1612.4, 14, 10, 4, 0, 3, now() - interval '2 days'),
  ('modern', :C, 1655.0, 12, 9, 3, 0, 3, now() - interval '2 days'),
  ('legacy', :B, 1540.0, 6, 4, 2, 0, 1, now() - interval '2 days');
insert into public.friendships (user_lo, user_hi, requested_by, status) values (:B, :D, :B, 'accepted');
insert into public.user_blocks (user_id, blocked_id) values (:B, :F);

create or replace function pg_temp.codes(p_user uuid) returns text language sql as $$
  select coalesce(string_agg(case i->>'kind'
           when 'league' then 'L:' || (i->>'league_slug') || ':' || coalesce(i->>'rank', '-') || ':' || (i->>'wins') || ':' || coalesce(i->>'qualified', '-') || ':' || (i->>'champion')
           else 'B:' || (i->>'board') || ':' || coalesce(i->>'rank', '-') || ':' || (i->>'rating') end, ' | ' order by n), '-')
    from jsonb_array_elements(public.profile_achievements(p_user)->'items') with ordinality x(i, n) $$;
grant execute on function pg_temp.codes(uuid) to anon, authenticated;

set role authenticated;
select pg_temp.as_user(:B);
select pg_temp.eq('your own: the season (champion; 2nd on the table), every board you have a rating on',
  pg_temp.codes(:B), 'L:ach-series:2:0:-:true | B:modern:2:1612 | B:legacy:-:1540');
select pg_temp.eq('your own says who sees them and whether the boards list you',
  (select (v->>'visibility') || ' ' || (v->>'listed') from public.profile_achievements(:B) v), 'public true');
select pg_temp.as_user(:C);
select pg_temp.eq('Cal: the Open''s winner qualified and leads the table', pg_temp.codes(:C), 'L:ach-series:1:1:winner:false | B:modern:1:1655');

-- Bea's profile is for friends (the default): Dee sees, Eve doesn't.
select pg_temp.as_user(:D);
select pg_temp.eq('a friend sees them, with only the boards that list you', pg_temp.codes(:B), 'L:ach-series:2:0:-:true | B:modern:2:1612');
select pg_temp.eq('others get no settings', (public.profile_achievements(:B) ? 'visibility')::text, 'false');
select pg_temp.as_user(:E);
select pg_temp.eq('a stranger doesn''t while the profile is for friends', pg_temp.codes(:B), '-');
reset role;
insert into public.share_settings (user_id, profile) values (:B, 'public');
set role authenticated;
select pg_temp.as_user(:E);
select pg_temp.eq('with a profile for anyone, anyone signed in sees them', pg_temp.codes(:B), 'L:ach-series:2:0:-:true | B:modern:2:1612');
select pg_temp.as_user(:F);
select pg_temp.eq('never across a block', pg_temp.codes(:B), '-');

select pg_temp.as_user(:B);
select pg_temp.eq('friends only', public.achievements_visibility_set('friends')::text, '{"visibility": "friends"}');
select pg_temp.as_user(:E);
select pg_temp.eq('now a stranger doesn''t', pg_temp.codes(:B), '-');
select pg_temp.as_user(:D);
select pg_temp.eq('a friend still does', pg_temp.codes(:B), 'L:ach-series:2:0:-:true | B:modern:2:1612');
select pg_temp.as_user(:B);
select pg_temp.eq('private', public.achievements_visibility_set('private')->>'visibility', 'private');
select pg_temp.as_user(:D);
select pg_temp.eq('private: not even friends', pg_temp.codes(:B), '-');
select pg_temp.as_user(:B);
select pg_temp.eq('you still see your own', pg_temp.codes(:B), 'L:ach-series:2:0:-:true | B:modern:2:1612 | B:legacy:-:1540');
select pg_temp.eq('public again', public.achievements_visibility_set('public')->>'visibility', 'public');
select pg_temp.throws('one of three', $$select public.achievements_visibility_set('everyone')$$, '22023');

-- Hiding from the boards takes the board placement off the profile for others.
select pg_temp.eq('hide from the boards', public.leaderboards_listed_set(false)->>'listed', 'false');
select pg_temp.as_user(:D);
select pg_temp.eq('hidden from the boards: only the league shows', pg_temp.codes(:B), 'L:ach-series:2:0:-:true');
select pg_temp.as_user(:B);
select pg_temp.eq('your own shows the rating without a rank', pg_temp.codes(:B), 'L:ach-series:2:0:-:true | B:legacy:-:1540 | B:modern:-:1612');

select pg_temp.throws('an unknown account', $$select public.profile_achievements('00000000-0000-0000-0000-00000000ffff')$$, 'P0002');
set role anon;
select pg_temp.as_user(null);
select pg_temp.throws('signed out sees no profiles', format('select public.profile_achievements(%L)', :B), '42501');
reset role;
select pg_temp.eq('changes are audited', (select count(*)::text from public.account_audit where actor = :B and action = 'sharing.achievements'), '3');
select pg_temp.eq('nothing is stored but the setting', (select count(*)::text from t1_private.achievement_settings), '1');
